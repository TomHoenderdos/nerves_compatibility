defmodule NccWorker.Tracer.CheckerPoolTest do
  @moduledoc """
  Pins `:ncc_tracer_channels.checker_pool_frames/0`, the frame of Elixir's
  type checker whose `schedulers_online` read the judge ignores
  (`NccWorker.Portability.Events`), on the toolchain this VM runs. In
  `Module.ParallelChecker`, read from its beam:

    * the module's one `erlang:system_info(schedulers_online)` call is made
      by the pinned function, and that function is init/1's default fun for
      `Keyword.get_lazy(options, :max_concurrency, fun)`, whose whole body is
      `max(erlang:system_info(schedulers_online), 2)`;
    * init/1 binds its result once and puts it in the server state under
      `schedulers`, and uses it nowhere else;
    * every other mention of `schedulers` in the module is a function head
      that binds the key and only compares it in a `map_size(spawned) >=
      schedulers` guard: the cap on how many cache and check processes run
      at once.

  A toolchain that changes any of this fails here instead of letting the
  read through for a value that might reach a beam.
  """
  use ExUnit.Case, async: true

  @module Module.ParallelChecker

  defp frames do
    for {m, f, a} <- :ncc_tracer_channels.checker_pool_frames(),
        do: {String.to_atom(m), String.to_atom(f), a}
  end

  defp forms do
    {:ok, {@module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(@module), [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, @module, data, [])
    forms
  end

  # The functions of the compiled module whose code names
  # `schedulers_online`, by their compiled names (generated fun names
  # included), from the module's own object code.
  defp compiled_readers do
    {:beam_file, @module, _exports, _attrs, _info, code} =
      :beam_disasm.file(:code.which(@module))

    for {:function, name, arity, _entry, instructions} <- code,
        mentions?(instructions, :schedulers_online),
        do: {@module, name, arity}
  end

  defp mentions?(term, atom) when is_tuple(term), do: mentions?(Tuple.to_list(term), atom)
  defp mentions?(list, atom) when is_list(list), do: Enum.any?(list, &mentions?(&1, atom))
  defp mentions?(atom, atom), do: true
  defp mentions?(_other, _atom), do: false

  defp count(term, pred) when is_tuple(term),
    do: if(pred.(term), do: 1, else: 0) + count(Tuple.to_list(term), pred)

  defp count(list, pred) when is_list(list), do: Enum.reduce(list, 0, &(count(&1, pred) + &2))
  defp count(_other, _pred), do: 0

  defp atom?(name), do: &match?({:atom, _, ^name}, &1)
  defp var?(name), do: &match?({:var, _, ^name}, &1)

  defp remote?({:remote, _, {:atom, _, m}, {:atom, _, f}}, m, f), do: true
  defp remote?(_call, _m, _f), do: false

  # `max(erlang:system_info(schedulers_online), 2)`, `max/2` local or remote.
  defp pool_default?([{:clause, _, [], [], [{:call, _, max, [read, {:integer, _, 2}]}]}]) do
    (match?({:atom, _, :max}, max) or remote?(max, :erlang, :max)) and
      match?({:call, _, _, [{:atom, _, :schedulers_online}]}, read) and
      remote?(elem(read, 2), :erlang, :system_info)
  end

  defp pool_default?(_clauses), do: false

  # `Var = 'Elixir.Keyword':get_lazy(_, max_concurrency, fun() -> ... end)`.
  defp lazy_bindings(term, acc \\ [])

  defp lazy_bindings(
         {:match, _, {:var, _, var}, {:call, _, call, [_, {:atom, _, :max_concurrency}, fun]}},
         acc
       ) do
    if remote?(call, Keyword, :get_lazy), do: [{var, fun} | acc], else: acc
  end

  defp lazy_bindings(tuple, acc) when is_tuple(tuple),
    do: lazy_bindings(Tuple.to_list(tuple), acc)

  defp lazy_bindings(list, acc) when is_list(list), do: Enum.reduce(list, acc, &lazy_bindings/2)
  defp lazy_bindings(_other, acc), do: acc

  # A head `#{..., schedulers := S, spawned := P, ...}` guarded by exactly
  # `map_size(P) >= S`, with S nowhere in the body.
  defp cap_clause?({:clause, _, head, [[guard]], body}) do
    with [s] <-
           for({:map_field_exact, _, {:atom, _, :schedulers}, {:var, _, v}} <- flat(head), do: v),
         {:op, _, :>=, {:call, _, size, [{:var, _, _p}]}, {:var, _, ^s}} <- guard,
         true <- match?({:atom, _, :map_size}, size) or remote?(size, :erlang, :map_size) do
      count(body, var?(s)) == 0
    else
      _ -> false
    end
  end

  defp cap_clause?(_clause), do: false

  defp flat(term) when is_tuple(term), do: [term | flat(Tuple.to_list(term))]
  defp flat(list) when is_list(list), do: Enum.flat_map(list, &flat/1)
  defp flat(other), do: [other]

  test "the pinned frame is the module's only schedulers_online read" do
    assert frames() != []
    assert Enum.sort(compiled_readers()) == Enum.sort(frames())
    assert count(forms(), atom?(:schedulers_online)) == 1
  end

  test "the read is init/1's :max_concurrency default, and only sizes the pool" do
    forms = forms()
    functions = for {:function, _, name, arity, clauses} <- forms, do: {{name, arity}, clauses}
    {_, init} = List.keyfind(functions, {:init, 1}, 0)

    assert [{var, {:fun, _, {:clauses, clauses}}}] = lazy_bindings(init)
    assert pool_default?(clauses)

    # Bound once, then only the state's `schedulers` field.
    assert count(init, var?(var)) == 2

    assert count(
             init,
             &match?({:map_field_assoc, _, {:atom, _, :schedulers}, {:var, _, ^var}}, &1)
           ) == 1

    # Every other `schedulers` in the module caps the pool in a guard.
    others =
      for {{name, arity}, clauses} <- functions,
          {name, arity} != {:init, 1},
          clause <- clauses,
          count(clause, atom?(:schedulers)) > 0,
          do: clause

    assert others != []

    for clause <- others do
      assert cap_clause?(clause), :erl_pp.function({:function, 0, :f, 1, [clause]}) |> to_string()
      assert count(clause, atom?(:schedulers)) == 1
    end

    assert count(init, atom?(:schedulers)) == 1
  end

  test "a default that is not exactly the pool size fails the pin" do
    bad = fn source ->
      {:ok, tokens, _} = :erl_scan.string(String.to_charlist(source))
      {:ok, {:function, _, _, _, [{:clause, _, _, _, [expr]}]}} = :erl_parse.parse_form(tokens)
      {:fun, _, {:clauses, clauses}} = expr
      pool_default?(clauses)
    end

    assert bad.("f() -> fun() -> max(erlang:system_info(schedulers_online), 2) end.")
    refute bad.("f() -> fun() -> erlang:system_info(schedulers_online) end.")
    refute bad.("f() -> fun() -> max(erlang:system_info(schedulers), 2) end.")
    refute bad.("f() -> fun() -> max(erlang:system_info(schedulers_online), 3) end.")
    refute bad.("f() -> fun() -> g(erlang:system_info(schedulers_online)) end.")
  end
end
