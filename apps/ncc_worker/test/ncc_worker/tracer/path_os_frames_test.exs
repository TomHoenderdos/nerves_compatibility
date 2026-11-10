defmodule NccWorker.Tracer.PathOsFramesTest do
  @moduledoc """
  Pins `:ncc_tracer_channels.path_os_frames/0`, the first frames under which
  the judge ignores an OS-family read (and the tracer only counts it), on
  the toolchain this VM runs: each one is a function that calls `os:type/0`
  or `erlang:system_info/1` itself and, through every local function it can reach, calls no fun
  value, no `apply` and no module it was given, so no package code can run
  with it as the first frame. Read from the beam's debug info, else from the module's
  source. A toolchain that changes any of these call sites fails here.
  """
  use ExUnit.Case, async: true

  @os_reads [{:os, :type}, {:os, :version}, {:erlang, :system_info}]

  defp frames do
    for {m, f, a} <- :ncc_tracer_channels.path_os_frames(),
        do: {String.to_atom(m), String.to_atom(f), a}
  end

  # The abstract forms of `module`: from its debug info, else from its
  # Erlang source under the app's `src`.
  defp forms(module) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(beam(module), [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      forms
    else
      _ -> source_forms(module)
    end
  end

  defp source_forms(module) do
    src = src(module)

    assert File.regular?(src), "#{module}: neither debug info nor source (#{src})"
    # erl_prim_loader's source includes inet_boot.hrl, which erts/src does
    # not ship: epp turns what needs it into error forms. Only the inet boot
    # functions use it, and none of the path helpers reaches them; if a
    # function the pin needs is lost that way, reach/3 fails on "local not
    # found" (fail closed).
    {:ok, forms} = :epp.parse_file(String.to_charlist(src), [])
    forms
  end

  # erl_prim_loader is preloaded: `code:which/1` says `:preloaded`, and its
  # beam and source live in the erts app.
  defp beam(module) do
    case :code.which(module) do
      :preloaded ->
        String.to_charlist(Path.join([:code.lib_dir(:erts), "ebin", "#{module}.beam"]))

      path ->
        path
    end
  end

  defp src(module) do
    case :code.which(module) do
      :preloaded ->
        Path.join([:code.lib_dir(:erts), "src", "#{module}.erl"])

      path ->
        path
        |> List.to_string()
        |> Path.dirname()
        |> Path.join("../src/#{module}.erl")
        |> Path.expand()
    end
  end

  defp functions(module) do
    for {:function, _, name, arity, clauses} <- forms(module),
        into: %{},
        do: {{name, arity}, clauses}
  end

  defp calls(term, acc \\ [])

  # A remote call with a literal module and function; anything else in
  # that position (a variable module, a computed function) is `:dynamic`.
  defp calls({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: calls(args, [{m, f} | acc])

  defp calls({:call, _, {:remote, _, _m, _f} = target, args}, acc),
    do: calls(args, [{:dynamic, target} | acc])

  defp calls({:call, _, {:atom, _, f}, args}, acc),
    do: calls(args, [{:local, f, length(args)} | acc])

  defp calls({:call, _, other, args}, acc), do: calls(args, [{:dynamic, other} | acc])

  # A local fun reference (`fun f/1`) can be called later: followed too.
  defp calls({:fun, _, {:function, f, a}}, acc) when is_atom(f) and is_integer(a),
    do: [{:local, f, a} | acc]

  defp calls({:fun, _, {:function, _m, _f, _a}} = t, acc), do: [{:dynamic, t} | acc]
  defp calls(tuple, acc) when is_tuple(tuple), do: calls(Tuple.to_list(tuple), acc)
  defp calls(list, acc) when is_list(list), do: Enum.reduce(list, acc, &calls/2)
  defp calls(_other, acc), do: acc

  # Every local function reachable from `start` through local calls, each
  # with the calls its own body makes.
  defp reachable(funs, start), do: reach(funs, [start], %{})

  defp reach(_funs, [], seen), do: seen

  defp reach(funs, [fa | rest], seen) when is_map_key(seen, fa), do: reach(funs, rest, seen)

  defp reach(funs, [fa | rest], seen) do
    assert {:ok, clauses} = Map.fetch(funs, fa), "local #{inspect(fa)} not found"
    own = clauses |> calls() |> Enum.uniq() |> Enum.map(&bif(funs, &1))
    next = for {:local, f, a} <- own, do: {f, a}
    reach(funs, next ++ rest, Map.put(seen, fa, own))
  end

  # An unqualified call of a function the module does not define is an
  # auto-imported BIF (`length/1`, `element/2`): erlang's, or not found.
  defp bif(funs, {:local, f, a} = call) do
    cond do
      Map.has_key?(funs, {f, a}) -> call
      :erlang.is_builtin(:erlang, f, a) or function_exported?(:erlang, f, a) -> {:erlang, f}
      true -> call
    end
  end

  defp bif(_funs, call), do: call

  @dynamic_apply [{:erlang, :apply}, {:erlang, :spawn}, {:erlang, :spawn_link}]

  test "every listed frame reads the OS family itself and reaches no fun or caller module" do
    assert frames() != []

    for {module, name, arity} <- frames() do
      funs = functions(module)
      assert Map.has_key?(funs, {name, arity}), "#{module}.#{name}/#{arity} is not defined"
      reached = reachable(funs, {name, arity})
      own = reached[{name, arity}]
      where = "#{module}.#{name}/#{arity}"

      assert Enum.any?(own, &(&1 in @os_reads)),
             "no os:type/0 or erlang:system_info/1 call in " <> where

      for {fa, found} <- reached, call <- found do
        refute match?({:dynamic, _}, call),
               "#{where} reaches #{inspect(fa)}, which calls a fun or variable module: " <>
                 inspect(call)

        refute call in @dynamic_apply, "#{where} reaches #{inspect(fa)}, which calls apply"
      end
    end
  end

  test "filelib:exists/2 would fail the pin: it calls the caller's module" do
    funs = functions(:filelib)
    reached = reachable(funs, {:exists, 2})
    assert Enum.any?(Map.values(reached), &Enum.any?(&1, fn c -> match?({:dynamic, _}, c) end))
    refute :ncc_tracer_channels.path_os_frame("filelib", "exists", 2)
  end

  test "neither Code, code nor file is listed, and no fun of a path module is" do
    for {m, f, _a} <- :ncc_tracer_channels.path_os_frames() do
      refute m in ["Elixir.Code", "code", "file"], m
      refute String.starts_with?(f, "-"), "#{m}.#{f}"
    end

    refute :ncc_tracer_channels.path_os_frame("Elixir.Code", "with_diagnostics", 2)
    refute :ncc_tracer_channels.path_os_frame("filelib", "fold_files", 5)
  end
end
