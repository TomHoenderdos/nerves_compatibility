defmodule NccWorker.Tracer.OsFamilyCallersTest do
  @moduledoc """
  Pins `NccWorker.Portability.Events.os_family_callers/0`, the callers whose
  own `:os.type/0` read the judge records as the family alone (judge
  revision 17), on the toolchain this VM runs: each one binds the read as
  `{family, _} = :os.type()`, dropping the name on the spot, and through
  every local function it can reach calls no fun value, no `apply` and no
  module it was given, so no package code can run with it as the frame
  below a read. Read from the beam's debug info. A toolchain that changes
  any of these call sites fails here instead of publishing a name-dependent
  build for the family alone.
  """
  use ExUnit.Case, async: true

  alias NccWorker.Portability.Events

  @dynamic_apply [{:erlang, :apply}, {:erlang, :spawn}, {:erlang, :spawn_link}]

  defp callers do
    for {m, f, a} <- Events.os_family_callers(),
        do: {String.to_atom(m), String.to_atom(f), a}
  end

  defp functions(module) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(module), [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])
    for {:function, _, name, arity, clauses} <- forms, into: %{}, do: {{name, arity}, clauses}
  end

  defp parse(source) do
    {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
    {:ok, {:function, _, _name, _arity, clauses}} = :erl_parse.parse_form(tokens)
    clauses
  end

  # Every OS-type read in `term`: `:family` when it is the right side of a
  # match whose pattern is a two-tuple with `_` second, else `:whole`.
  defp os_reads(term, acc \\ [])

  defp os_reads({:match, _, pattern, rhs}, acc) do
    if os_read?(rhs),
      do: os_reads(pattern, [family_pattern(pattern) | acc]),
      else: os_reads([pattern, rhs], acc)
  end

  defp os_reads({:call, _, _, args} = call, acc) do
    acc = if os_read?(call), do: [:whole | acc], else: acc
    os_reads(args, acc)
  end

  defp os_reads(tuple, acc) when is_tuple(tuple), do: os_reads(Tuple.to_list(tuple), acc)
  defp os_reads(list, acc) when is_list(list), do: Enum.reduce(list, acc, &os_reads/2)
  defp os_reads(_other, acc), do: acc

  defp os_read?({:call, _, {:remote, _, {:atom, _, :os}, {:atom, _, :type}}, []}), do: true

  defp os_read?(
         {:call, _, {:remote, _, {:atom, _, :erlang}, {:atom, _, :system_info}},
          [{:atom, _, :os_type}]}
       ),
       do: true

  defp os_read?(_term), do: false

  defp family_pattern({:tuple, _, [_family, {:var, _, :_}]}), do: :family
  defp family_pattern(_pattern), do: :whole

  defp calls(term, acc \\ [])

  defp calls({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: calls(args, [{m, f} | acc])

  defp calls({:call, _, {:atom, _, f}, args}, acc),
    do: calls(args, [{:local, f, length(args)} | acc])

  defp calls({:call, _, other, args}, acc), do: calls(args, [{:dynamic, other} | acc])

  defp calls({:fun, _, {:function, f, a}}, acc) when is_atom(f) and is_integer(a),
    do: [{:local, f, a} | acc]

  defp calls({:fun, _, {:function, _m, _f, _a}} = t, acc), do: [{:dynamic, t} | acc]
  defp calls(tuple, acc) when is_tuple(tuple), do: calls(Tuple.to_list(tuple), acc)
  defp calls(list, acc) when is_list(list), do: Enum.reduce(list, acc, &calls/2)
  defp calls(_other, acc), do: acc

  # Every local function reachable from `start`, each with its own calls.
  defp reach(_funs, [], seen), do: seen
  defp reach(funs, [fa | rest], seen) when is_map_key(seen, fa), do: reach(funs, rest, seen)

  defp reach(funs, [fa | rest], seen) do
    own =
      case Map.fetch(funs, fa) do
        {:ok, clauses} -> clauses |> calls() |> Enum.uniq()
        # Not defined here: an auto-imported BIF (`length/1`, `element/2`).
        :error -> []
      end

    reach(funs, for({:local, f, a} <- own, do: {f, a}) ++ rest, Map.put(seen, fa, own))
  end

  test "every listed caller keeps only the family and reaches no fun or caller module" do
    assert callers() != []

    for {module, name, arity} <- callers() do
      funs = functions(module)
      where = "#{inspect(module)}.#{name}/#{arity}"
      assert {:ok, clauses} = Map.fetch(funs, {name, arity}), "#{where} is not defined"

      reads = os_reads(clauses)
      assert reads != [], "no :os.type/0 read in " <> where
      assert Enum.all?(reads, &(&1 == :family)), "#{where} keeps the OS name: #{inspect(reads)}"

      for {fa, found} <- reach(funs, [{name, arity}], %{}), call <- found do
        refute match?({:dynamic, _}, call),
               "#{where} reaches #{inspect(fa)}, which calls a fun or variable module: " <>
                 inspect(call)

        refute call in @dynamic_apply, "#{where} reaches #{inspect(fa)}, which calls apply"
      end
    end
  end

  test "a read that keeps the name, or matches the tuple elsewhere, would fail the pin" do
    assert os_reads(parse("f() -> {Major, _} = os:type(), Major.")) == [:family]

    for source <- [
          # filename:basedir_os_type/0
          "f() -> case os:type() of {unix, darwin} -> darwin; _ -> linux end.",
          "f() -> {Major, Name} = os:type(), {Major, Name}.",
          "f() -> T = os:type(), element(1, T).",
          "f() -> {Major, _} = T = os:type(), {Major, T}.",
          "f() -> {Major, _} = erlang:system_info(os_type), g(os:type()), Major."
        ] do
      assert :whole in os_reads(parse(source)), source
    end
  end
end
