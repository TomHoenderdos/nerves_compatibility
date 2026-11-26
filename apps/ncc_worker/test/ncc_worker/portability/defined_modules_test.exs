defmodule NccWorker.Portability.DefinedModulesTest do
  # S10 fix round 1: a package's in-memory modules, from the tracer's end
  # line, attributed by the dir that holds each one's source.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{Context, DefinedModules}

  @moduletag :tmp_dir

  defp ctx(dir) do
    proj = Path.join(dir, "proj")

    deps =
      Map.new(["pkg", "dep"], fn app ->
        dest = Path.join([proj, "deps", app])
        build = Path.join([proj, "_build", "host", "lib", app])
        File.mkdir_p!(dest)
        File.mkdir_p!(build)

        {app,
         %{
           build: Context.realpath(build),
           dest: Context.realpath(dest),
           manager: "mix",
           children: [],
           native?: false,
           hex_files: nil
         }}
      end)

    deps = put_in(deps["pkg"].children, ["dep"])
    File.write!(Path.join(proj, "mix.exs"), "")

    %Context{
      package: "pkg",
      deps: deps,
      project_dir: Context.realpath(proj),
      deps_path: Context.realpath(Path.join(proj, "deps"))
    }
  end

  defp file(c, rel) do
    path = Path.join(c.project_dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
    path
  end

  defp ending(items, over \\ false), do: %{"in_memory" => items, "in_memory_over" => over}
  defp item(module, source), do: %{"module" => module, "source" => source}

  test "the package's own, sorted; another app's and the project's are left out", %{tmp_dir: dir} do
    c = ctx(dir)

    items = [
      item("Elixir.Pkg.MixProject", file(c, "deps/pkg/mix.exs")),
      item("Elixir.Pkg.Helper", file(c, "deps/pkg/mix/helpers.exs")),
      item("pkg_loaded", file(c, "_build/host/lib/pkg/priv/pkg_loaded.beam")),
      item("Elixir.Dep.MixProject", file(c, "deps/dep/mix.exs")),
      item("Elixir.Wrapper.MixProject", Path.join(c.project_dir, "mix.exs")),
      item("elixir_compiler_0", "/usr/local/lib/elixir/bin/mix"),
      item("elixir_compiler_12", file(c, "deps/pkg/mix.exs")),
      # Not Elixir's transient form: the package's like any other.
      item("elixir_compiler_x", file(c, "deps/pkg/a.exs"))
    ]

    assert DefinedModules.of(c, ending(items)) ==
             ~w(Elixir.Pkg.Helper Elixir.Pkg.MixProject elixir_compiler_x pkg_loaded)

    assert DefinedModules.of(c, ending([])) == []
  end

  test "a source no closure app or the project holds leaves no list", %{tmp_dir: dir} do
    c = ctx(dir)
    own = item("Elixir.Pkg.MixProject", file(c, "deps/pkg/mix.exs"))

    for bad <- [
          item("Elixir.Made", "/elsewhere/x.ex"),
          item("Elixir.Made", Path.join(c.project_dir, "nofile_missing")),
          item("Elixir.Made", nil),
          item("Elixir.Bad Name", file(c, "deps/pkg/b.exs")),
          %{"module" => "Elixir.Made"}
        ] do
      assert DefinedModules.of(c, ending([own, bad])) == nil, inspect(bad)
    end
  end

  test "a list over the tracer's cap, or none, is no list", %{tmp_dir: dir} do
    c = ctx(dir)
    assert DefinedModules.of(c, ending([], true)) == nil
    assert DefinedModules.of(c, %{}) == nil
    assert DefinedModules.of(c, nil) == nil
    assert DefinedModules.of(%{c | package: "absent"}, ending([])) == nil
  end
end
