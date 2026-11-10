defmodule NccWorker.Tracer.FixturesTreesCompiledTest do
  # Item 5e when the closure was compiled before the traced judge compile,
  # as on a full run's `pure_elixir` path: Mix's leex compiler writes the
  # `.erl` it generates into the dependency's own `src/`, so only a tree
  # snapshot taken before that compile says anything about the tarball.
  # Real traced compiles.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability
  alias NccWorker.Portability.Trees
  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 900_000

  @mix_exs mix_exs("fx_lex", "")
  @contents %{
    "mix.exs" => @mix_exs,
    "src/fx_lex_lexer.xrl" => """
    Definitions.
    D = [0-9]
    Rules.
    {D}+ : {token, {int, TokenLine, list_to_integer(TokenChars)}}.
    Erlang code.
    """,
    # Lists its own source dir at compile time, one level deep.
    "lib/fx_lex.ex" => """
    defmodule FxLex do
      @root File.ls!(".") |> Enum.sort()
      def root, do: @root
      def ints(s), do: :fx_lex_lexer.string(String.to_charlist(s))
    end
    """
  }
  @dep %{mix_exs: @mix_exs, files: Map.delete(@contents, "mix.exs")}

  setup_all do
    root = Path.join(System.tmp_dir!(), "ncc-fixtures-lex-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")

    {app, release} =
      TracerFixtures.hex_release(home, "fx_lex", Map.keys(@contents), @contents)

    releases = %{app => release}

    # Compiled first, untraced, after a pre-compile snapshot.
    proj = TracerFixtures.project(Path.join(root, "compiled"), ["fx_lex"], %{"fx_lex" => @dep})
    before = Portability.tree_snapshot(proj, releases: {:ok, releases}, hex_home: home)

    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    after_compile = Trees.snapshot(proj, releases, home, [])
    run = &portability_run(&1, &2, releases, home, &3)
    with_snapshot = run.(proj, "with", trees: before)
    without = run.(proj, "without", [])

    # Tampered before its first compile, the toolchain path's own snapshot.
    tampered =
      TracerFixtures.project(Path.join(root, "tampered"), ["fx_lex"], %{"fx_lex" => @dep})

    File.write!(Path.join([tampered, "deps", "fx_lex", "lib", "extra.ex"]), "x = 1\n")

    %{
      compile: {status, out},
      proj: proj,
      before: before,
      after_compile: after_compile,
      with_snapshot: with_snapshot,
      without: without,
      tampered: run.(tampered, "tampered", mode: :host)
    }
  end

  defp portability_run(proj, name, releases, home, opts) do
    dir = Path.join(Path.dirname(proj), name)
    File.mkdir_p!(dir)

    Portability.run(
      proj,
      "fx_lex",
      [
        env: TracerFixtures.env(proj),
        releases: {:ok, releases},
        hex_home: home,
        trace_dir: Path.join(dir, "trace"),
        log_file: Path.join(dir, "trace.log")
      ] ++ opts
    )
  end

  test "the compile writes into the dependency's source dir", ctx do
    assert {0, _} = ctx.compile, elem(ctx.compile, 1)
    assert File.regular?(Path.join([ctx.proj, "deps", "fx_lex", "src", "fx_lex_lexer.erl"]))
    assert {:ok, _members} = ctx.before["fx_lex"]
    assert {:differs, "extra file src/fx_lex_lexer.erl"} = ctx.after_compile["fx_lex"]
  end

  test "a closure compiled first is judged on the snapshot taken before it", ctx do
    v = ctx.with_snapshot
    assert %{status: :pass, reason: nil} = v, inspect(v.observations["problems"])
    assert v.observations["tree_check"] == %{"fx_lex" => "ok"}
  end

  test "without a snapshot a compiled closure cannot be judged, never refused", ctx do
    v = ctx.without
    assert %{status: :skip, reason: "portability could not be judged"} = v

    assert Enum.any?(
             v.observations["problems"],
             &String.starts_with?(&1, "no tree snapshot taken before the closure was compiled")
           ),
           inspect(v.observations["problems"])
  end

  test "the toolchain path still refuses a tree tampered with before its compile", ctx do
    assert %{
             status: :skip,
             reason: "dependency tree differs from its tarball: fx_lex (extra file lib/extra.ex)"
           } = ctx.tampered
  end
end
