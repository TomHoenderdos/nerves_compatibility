defmodule NccWorker.Portability.CheckerLookupsTest do
  @moduledoc """
  Pins how Elixir's type checker (`Module.ParallelChecker`, `Module.Types.*`)
  looks a remote module up, on the toolchain this VM runs.
  `NccWorker.Portability.Probes` drops a checker's `function_exported/3`
  probe of a module on the window owner's path in a window with a nested
  compile: that holds only while every such call runs after the module was
  loaded. Its `module_loaded/1` probe it asks before loading anything, in
  `cache_module/2` only; that one is dropped there only for an Erlang module
  on the path, because both branches it chooses between cache the same
  entries for such a module. A toolchain that changes any of this fails here.
  """
  # The cache-branch pin starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  @checker [Module.ParallelChecker]
  @loads [{Code, :ensure_loaded?}, {Code, :ensure_loaded}, {:code, :ensure_loaded}]
  @exported {:erlang, :function_exported}
  @loaded {:erlang, :module_loaded}

  # Every checker module: Module.ParallelChecker and each Module.Types module
  # the install has.
  defp modules do
    types =
      for {name, _path, _loaded} <- :code.all_available(),
          name = List.to_string(name),
          String.starts_with?(name, "Elixir.Module.Types."),
          do: String.to_atom(name)

    @checker ++ Enum.sort(types)
  end

  # `%{function => [lookup]}` in call order, for one module: from its source
  # when the install ships `lib`, otherwise from the beam's debug info.
  defp lookups(module) do
    case source(module) do
      {:ok, path} -> source_lookups(path)
      :none -> beam_lookups(module)
    end
  end

  defp source(module) do
    rel =
      module
      |> Module.split()
      |> Enum.map(&Macro.underscore/1)
      |> Path.join()

    path = Path.join(:code.lib_dir(:elixir), "lib/#{rel}.ex")
    if File.regular?(path), do: {:ok, path}, else: :none
  end

  defp source_lookups(path) do
    ast = path |> File.read!() |> Code.string_to_quoted!()

    {_ast, {_fun, acc}} =
      Macro.traverse(ast, {nil, %{}}, &source_pre/2, &source_post/2)

    # Module-level code (`nil`) ran when Elixir itself was compiled.
    acc |> Map.delete(nil) |> Map.new(fn {fun, calls} -> {fun, Enum.reverse(calls)} end)
  end

  defp source_post({d, _, [:head | _]} = node, {_fun, acc}) when d in [:def, :defp],
    do: {node, {nil, acc}}

  defp source_post(node, state), do: {node, state}

  # A def's head is no call: only its body is walked.
  defp source_pre({d, meta, [{:when, _, [{name, _, _} | _]} | body]}, {_fun, acc})
       when d in [:def, :defp],
       do: {{d, meta, [:head | body]}, {name, acc}}

  defp source_pre({d, meta, [{name, _, _} | body]}, {_fun, acc})
       when d in [:def, :defp] and is_atom(name),
       do: {{d, meta, [:head | body]}, {name, acc}}

  defp source_pre({{:., _, [mod, fun]}, _, args} = node, {cur, acc}) when is_list(args) do
    mod =
      case mod do
        {:__aliases__, _, parts} -> Module.concat(parts)
        other -> other
      end

    {node, {cur, add(acc, cur, {mod, fun})}}
  end

  defp source_pre({:function_exported?, _, [_, _, _]} = node, {cur, acc}),
    do: {node, {cur, add(acc, cur, @exported)}}

  defp source_pre({name, _, args} = node, {cur, acc}) when is_atom(name) and is_list(args),
    do: {node, {cur, add(acc, cur, {:local, name})}}

  defp source_pre(node, state), do: {node, state}

  defp beam_lookups(module) do
    {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} =
      :beam_lib.chunks(:code.which(module), [:debug_info])

    {:ok, forms} = backend.debug_info(:erlang_v1, module, data, [])

    for {:function, _, name, _, clauses} <- forms, reduce: %{} do
      acc -> Map.update(acc, name, forms_calls(clauses), &(&1 ++ forms_calls(clauses)))
    end
  end

  defp forms_calls(term) do
    term |> walk([]) |> Enum.reverse()
  end

  defp walk({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: walk(args, [{m, f} | acc])

  defp walk({:call, _, {:atom, _, f}, args}, acc), do: walk(args, [{:local, f} | acc])

  defp walk(tuple, acc) when is_tuple(tuple), do: walk(Tuple.to_list(tuple), acc)
  defp walk(list, acc) when is_list(list), do: Enum.reduce(list, acc, &walk/2)
  defp walk(_other, acc), do: acc

  defp add(acc, cur, call), do: Map.update(acc, cur, [call], &[call | &1])

  defp sites(lookups, call),
    do: for({fun, calls} <- lookups, call in calls, do: fun)

  test "every function_exported/3 runs on a module the checker loaded first" do
    found = for module <- modules(), fun <- sites(lookups(module), @exported), do: {module, fun}
    assert {Module.ParallelChecker, :behaviour_exports} in found
    assert length(found) > 1, inspect(found)

    for module <- modules(), lookups = lookups(module), fun <- sites(lookups, @exported) do
      calls = lookups[fun]

      if module == Module.ParallelChecker and fun == :behaviour_exports do
        # Reached only from info_exports/1, which cache_module/2 calls
        # only once module_loaded/1 said the module is loaded.
        assert sites(lookups, {:local, :behaviour_exports}) |> Enum.sort() ==
                 [:cache_from_module_map, :info_exports]

        assert sites(lookups, {:local, :info_exports}) == [:cache_module]
      else
        first_load = Enum.find_index(calls, &(&1 in @loads))
        first_exported = Enum.find_index(calls, &(&1 == @exported))

        assert first_load != nil and first_load < first_exported,
               "#{inspect(module)}.#{fun} calls function_exported/3 before loading: " <>
                 inspect(calls)
      end
    end
  end

  test "module_loaded/1 is asked before any load, in cache_module/2 only" do
    sites = for module <- modules(), fun <- sites(lookups(module), @loaded), do: {module, fun}
    assert sites == [{Module.ParallelChecker, :cache_module}]

    calls = lookups(Module.ParallelChecker)[:cache_module]
    refute Enum.any?(Enum.take_while(calls, &(&1 != @loaded)), &(&1 in @loads)), inspect(calls)
  end

  test "the beam's debug info gives the same lookups as the source" do
    for module <- modules(), match?({:ok, _}, source(module)) do
      {:ok, path} = source(module)
      from_source = source_lookups(path)
      from_beam = beam_lookups(module)

      for call <- [@exported, @loaded] do
        assert Enum.sort(sites(from_beam, call)) == Enum.sort(sites(from_source, call)),
               "#{inspect(module)} #{inspect(call)}"
      end
    end
  end

  # In order, not necessarily next to each other.
  defp subsequence?(_calls, []), do: true
  defp subsequence?([], _wanted), do: false
  defp subsequence?([c | calls], [c | wanted]), do: subsequence?(calls, wanted)
  defp subsequence?([_ | calls], wanted), do: subsequence?(calls, wanted)

  test "cache_module/2 reads the object code, then its checker chunk, then asks module_loaded/1" do
    calls = lookups(Module.ParallelChecker)[:cache_module]

    # get_object_code, the ExCk chunk, module_loaded: loaded -> the module's
    # own info, not loaded -> the object code's exports chunk.
    assert subsequence?(calls, [
             {:code, :get_object_code},
             {:beam_lib, :chunks},
             @loaded,
             {:local, :info_exports},
             {:local, :info_deprecated},
             {:beam_lib, :chunks}
           ]),
           inspect(calls)
  end

  # What cache_module/2 caches for `module` in a fresh VM, the module loaded
  # first or not: every entry of the checker's table.
  defp cached(module, preload?) do
    script = """
    m = #{inspect(module)}
    if #{preload?}, do: {:module, ^m} = :code.ensure_loaded(m)
    before = :erlang.module_loaded(m)
    {:ok, {_checker, table} = cache} = Module.ParallelChecker.start_link()
    _ = Module.ParallelChecker.fetch_export(cache, m, :module_info, 0, true)
    entries = :ets.tab2list(table) |> Enum.sort()
    IO.write(Base.encode64(:erlang.term_to_binary({before, entries})))
    """

    {out, 0} = System.cmd("elixir", ["-e", script], stderr_to_stdout: true)

    out
    |> String.trim()
    |> String.split("\n")
    |> List.last()
    |> Base.decode64!()
    |> :erlang.binary_to_term()
  end

  test "for an Erlang module on the path both cache_module/2 branches cache the same entries" do
    for module <- [:ssl, :httpc] do
      {^module, binary, _} = :code.get_object_code(module)
      {:ok, :code.get_object_code(module)} |> then(fn {:ok, t} -> {:ok, t} end)

      assert {:error, :beam_lib, {:missing_chunk, _, _}} = :beam_lib.chunks(binary, [~c"ExCk"])

      {false, unloaded} = cached(module, false)
      {true, loaded} = cached(module, true)
      assert {module, :erlang} in unloaded
      assert Enum.count(unloaded) > 2
      assert loaded == unloaded
    end
  end
end
