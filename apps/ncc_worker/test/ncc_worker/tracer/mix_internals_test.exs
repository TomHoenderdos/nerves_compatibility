defmodule NccWorker.Tracer.MixInternalsTest do
  # The judge compile's driver (`mix ncc.trace_compile`, an Erlang module)
  # calls Mix functions that are not public API. One that an Elixir bump
  # renames or removes would make every trace "portability could not be
  # judged", quietly; this makes it a failing test on that Elixir instead.
  use ExUnit.Case, async: true

  @driver :"Elixir.Mix.Tasks.Ncc.TraceCompile"

  # Called only when exported; the driver falls back without it.
  @optional [{Mix.Project, :with_build_lock, 2}]

  defp mix_imports do
    {:ok, {_, [imports: imports]}} = :beam_lib.chunks(:code.which(@driver), [:imports])

    for {m, f, a} <- imports, String.starts_with?(Atom.to_string(m), "Elixir.Mix."), do: {m, f, a}
  end

  test "every Mix function the driver calls exists on this Elixir" do
    imports = mix_imports()

    # The ones the trace cannot do without, so the scan itself is checked.
    for mfa <- [
          {Mix.Tasks.Deps.Compile, :compile_single, 3},
          {Mix.Dep, :load_and_cache, 0},
          {Mix.Project, :config, 0},
          {Mix.Project, :deps_config, 0}
        ],
        do: assert(mfa in imports, inspect(mfa))

    missing =
      for {m, f, a} = mfa <- imports,
          mfa not in @optional,
          not (Code.ensure_loaded?(m) and function_exported?(m, f, a)),
          do: mfa

    assert missing == [], "missing on Elixir #{System.version()}: #{inspect(missing)}"
  end

  test "the Mix.Dep fields the driver reads exist on this Elixir" do
    fields = Mix.Dep.__struct__() |> Map.keys()
    for field <- [:app, :opts, :deps, :manager], do: assert(field in fields, inspect(field))
  end
end
