defmodule NccWorker.OptionalDepsRecompileIntegrationTest do
  @moduledoc """
  Real Mix, offline: after `NccWorker.Project.fetch_optional_deps/4` or
  `drop_optional_deps/3`, does the next `mix compile` rebuild a dependency
  whose optional dependency came or went?

  Fixtures are local path dependencies: `d` declares `o` optional and records
  `Code.ensure_loaded?(O)` at compile time, and its macro `D.branch/0`
  expands to that value; `p` depends on `d` (and `o` optionally) and calls the
  macro. Path dependencies are not in `mix.lock`, so the `deps_get` handed to
  `Project` runs the real `mix deps.get` and then writes the Hex-shaped lock a
  Hex resolution of the same graph would (the edges are all
  `DepsLock.changed_closures/2` reads). Mix keeps lock entries for path
  dependencies, so the compile sees the same lock.

  Measured on Elixir 1.19 and 1.20 with path, git and Hex dependencies: Mix
  never rebuilds `d` when `o` is taken out again, so without the removal the
  drop leaves `d`, and `p`'s expansion of its macro, built with `o`.

      mix test --include integration apps/ncc_worker/test/ncc_worker/optional_deps_recompile_integration_test.exs
  """
  use ExUnit.Case, async: false

  alias NccWorker.Project

  @moduletag :integration
  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @without_o """
  %{
    "d": {:hex, :d, "0.1.0", "i-d", [:mix], [{:o, "~> 0.1", [hex: :o, repo: "hexpm", optional: true]}], "hexpm", "o-d"},
    "p": {:hex, :p, "0.1.0", "i-p", [:mix], [{:d, "~> 0.1", [hex: :d, repo: "hexpm", optional: false]}, {:o, "~> 0.1", [hex: :o, repo: "hexpm", optional: true]}], "hexpm", "o-p"},
  }
  """

  @with_o String.replace(
            @without_o,
            "%{\n",
            ~s(%{\n  "o": {:hex, :o, "0.1.0", "i-o", [:mix], [], "hexpm", "o-o"},\n)
          )

  setup %{tmp_dir: tmp} do
    on_exit(fn -> File.rm_rf(tmp) end)
    src = Path.join(tmp, "src")

    fixture(src, "o", "", "defmodule O do\n  def hi, do: :o\nend\n")

    fixture(src, "d", ~s({:o, path: "#{src}/o", optional: true}), """
    defmodule D do
      @has_o Code.ensure_loaded?(O)
      def has_o, do: @has_o
      defmacro branch, do: @has_o
    end
    """)

    fixture(src, "p", ~s({:d, path: "#{src}/d"}, {:o, path: "#{src}/o", optional: true}), """
    defmodule P do
      require D
      def via_macro, do: D.branch()
    end
    """)

    app = Path.join(tmp, "app")
    File.mkdir_p!(Path.join(app, "lib"))
    File.write!(Path.join([app, "lib", "app.ex"]), "defmodule App do\nend\n")
    app_mix_exs(app, src, false)
    File.write!(Path.join(app, "mix.lock"), @without_o)

    build_path = Path.join([app, "_build", "host"])

    env = [
      {"MIX_ENV", "prod"},
      {"MIX_BUILD_PATH", build_path},
      {"MIX_DEPS_PATH", Path.join(app, "deps")}
    ]

    mix!(app, env, "deps.get")
    mix!(app, env, "compile")
    assert probe(build_path) == {false, false}

    %{app: app, src: src, env: env, build_path: build_path}
  end

  test "d reflects o after the pass adds it, drops it, and adds it again", ctx do
    %{app: app, env: env, build_path: build_path} = ctx
    {:ok, snapshot} = Project.snapshot(app)

    add(ctx)
    assert probe(build_path) == {true, true}

    assert :ok = Project.drop_optional_deps(snapshot, "p", env)
    assert File.read!(Path.join(app, "mix.lock")) == @without_o
    # `compile_host`: deps.get, then compile.
    mix!(app, env, "deps.get")
    mix!(app, env, "compile")
    assert probe(build_path) == {false, false}

    add(ctx)
    assert probe(build_path) == {true, true}
  end

  # The control: what the drop did before it removed the changed closures.
  # If Mix ever rebuilds d on its own, this fails and the removal is moot.
  test "without the removal, the drop leaves d and p's macro expansion built with o", ctx do
    %{app: app, env: env, build_path: build_path} = ctx
    {:ok, snapshot} = Project.snapshot(app)

    add(ctx)
    assert probe(build_path) == {true, true}

    assert :ok = Project.restore(snapshot)
    File.rm_rf!(Path.join([build_path, "lib", "p"]))
    mix!(app, env, "deps.get")
    mix!(app, env, "compile")

    assert probe(build_path) == {true, true}
  end

  defp add(%{app: app, src: src, env: env}) do
    app_mix_exs(app, src, true)

    deps_get = fn dir, deps_env ->
      mix!(dir, deps_env, "deps.get")
      File.write!(Path.join(dir, "mix.lock"), @with_o)
      :ok
    end

    assert :ok = Project.fetch_optional_deps(app, "p", env, deps_get)
    mix!(app, env, "compile")
  end

  defp fixture(src, name, deps, code) do
    dir = Path.join(src, name)
    File.mkdir_p!(Path.join(dir, "lib"))

    File.write!(Path.join(dir, "mix.exs"), """
    defmodule Fx#{String.upcase(name)}.MixProject do
      use Mix.Project
      def project, do: [app: :#{name}, version: "0.1.0", deps: [#{deps}]]
    end
    """)

    File.write!(Path.join([dir, "lib", "#{name}.ex"]), code)
  end

  defp app_mix_exs(app, src, with_o?) do
    o = if with_o?, do: ~s({:o, path: "#{src}/o"},\n      ), else: ""

    File.write!(Path.join(app, "mix.exs"), """
    defmodule App.MixProject do
      use Mix.Project

      def project do
        [app: :app, version: "0.1.0", deps: deps()]
      end

      defp deps do
        [
          #{o}{:p, path: "#{src}/p"}
        ]
      end
    end
    """)
  end

  defp mix!(dir, env, task) do
    {out, code} = System.cmd("mix", [task], cd: dir, env: env, stderr_to_stdout: true)
    assert code == 0, "mix #{task} failed:\n#{out}"
    out
  end

  # `{D.has_o(), P.via_macro()}` from the beams in the build, in a fresh VM.
  defp probe(build_path) do
    paths = Enum.flat_map(~w(d p), &["-pa", Path.join([build_path, "lib", &1, "ebin"])])

    {out, 0} =
      System.cmd("elixir", paths ++ ["-e", "IO.write(inspect({D.has_o(), P.via_macro()}))"])

    {result, _} = Code.eval_string(out)
    result
  end
end
