defmodule NccWorker.Tracer.PathOsFramesTest do
  @moduledoc """
  Pins `:ncc_tracer_channels.path_os_frames/0`, the first frames under which
  the judge ignores an OS-family read (and the tracer only counts it), on
  the toolchain this VM runs: each one is a function that calls `os:type/0`
  itself and runs no fun it was given, so no package code can be the caller
  the read answers. Read from the beam's debug info, else from the module's
  source. A toolchain that changes any of these call sites fails here.
  """
  use ExUnit.Case, async: true

  @os_reads [{:os, :type}, {:os, :version}]

  defp frames do
    for {m, f, a} <- :ncc_tracer_channels.path_os_frames(),
        do: {String.to_atom(m), String.to_atom(f), a}
  end

  # The abstract forms of `module`: from its debug info, else from its
  # Erlang source under the app's `src`.
  defp forms(module) do
    with {:ok, {^module, [debug_info: {:debug_info_v1, backend, data}]}} <-
           :beam_lib.chunks(:code.which(module), [:debug_info]),
         {:ok, forms} <- backend.debug_info(:erlang_v1, module, data, []) do
      forms
    else
      _ -> source_forms(module)
    end
  end

  defp source_forms(module) do
    src =
      module
      |> :code.which()
      |> List.to_string()
      |> Path.dirname()
      |> Path.join("../src/#{module}.erl")
      |> Path.expand()

    assert File.regular?(src), "#{module}: neither debug info nor source (#{src})"
    {:ok, forms} = :epp.parse_file(String.to_charlist(src), [])
    forms
  end

  defp clauses(module, name, arity) do
    found = for {:function, _, ^name, ^arity, clauses} <- forms(module), do: clauses

    assert [clauses] = found, "#{module}.#{name}/#{arity} is not defined"
    clauses
  end

  defp calls(term, acc \\ [])

  defp calls({:call, _, {:remote, _, {:atom, _, m}, {:atom, _, f}}, args}, acc),
    do: calls(args, [{m, f} | acc])

  defp calls({:call, _, {:atom, _, f}, args}, acc), do: calls(args, [{:local, f} | acc])
  defp calls({:call, _, other, args}, acc), do: calls(args, [{:dynamic, other} | acc])
  defp calls(tuple, acc) when is_tuple(tuple), do: calls(Tuple.to_list(tuple), acc)
  defp calls(list, acc) when is_list(list), do: Enum.reduce(list, acc, &calls/2)
  defp calls(_other, acc), do: acc

  test "every listed frame reads the OS family itself and runs no fun it was given" do
    assert frames() != []

    for {module, name, arity} <- frames() do
      found = clauses(module, name, arity) |> calls() |> Enum.uniq()
      where = "#{module}.#{name}/#{arity}: #{inspect(found)}"

      assert Enum.any?(found, &(&1 in @os_reads)), "no os:type/0 call in " <> where
      refute Enum.any?(found, &match?({:dynamic, _}, &1)), "calls a fun value in " <> where
      refute Enum.any?(found, &(&1 in [{:erlang, :apply}, {:local, :apply}])), where
    end
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
