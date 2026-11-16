defmodule NccWorker.Tracer.FixturesOwnPrivTreesTest do
  # The second build of a package that writes its own priv (judge revision
  # 21, `NccWorker.Portability.PrivRepro`) when its closure holds a leex
  # lexer: the first compile wrote the generated `.erl` into the
  # dependency's own `src/`, so a tree snapshot taken for the second build
  # would refuse what Mix itself wrote. The second build is judged on the
  # snapshot the first one was (item 5e, `Trees`). Real traced compiles,
  # with a Hex release for the tree check.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [mix_exs: 2]

  @moduletag timeout: 900_000

  @mix_exs mix_exs("fx_lex_priv", "")
  @contents %{
    "mix.exs" => @mix_exs,
    "src/fx_lex_priv_lexer.xrl" => """
    Definitions.
    D = [0-9]
    Rules.
    {D}+ : {token, {int, TokenLine, list_to_integer(TokenChars)}}.
    Erlang code.
    """,
    "lib/fx_lex_priv.ex" => """
    defmodule FxLexPriv do
      dir = Path.join([:code.priv_dir(:fx_lex_priv), "assets"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "a.txt"), "fixed bytes")
      def ints(s), do: :fx_lex_priv_lexer.string(String.to_charlist(s))
    end
    """
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-own-priv-trees-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")

    {app, release} =
      TracerFixtures.hex_release(home, "fx_lex_priv", Map.keys(@contents), @contents)

    releases = %{app => release}
    dep = %{mix_exs: @mix_exs, files: Map.delete(@contents, "mix.exs")}
    proj = TracerFixtures.project(Path.join(root, "p"), ["fx_lex_priv"], %{"fx_lex_priv" => dep})
    before = Portability.tree_snapshot(proj, releases: {:ok, releases}, hex_home: home)

    verdict =
      Portability.run(proj, "fx_lex_priv",
        env: TracerFixtures.env(proj),
        releases: {:ok, releases},
        hex_home: home,
        trees: before,
        mode: :judge,
        trace_dir: Path.join(root, "trace"),
        log_file: Path.join(root, "trace.log"),
        timeout_ms: 240_000,
        run_started_at: System.monotonic_time(:second),
        repro_root: Path.join(File.cwd!(), "tmp")
      )

    %{proj: proj, before: before, verdict: verdict}
  end

  test "the second build is judged on the first one's tree snapshot", ctx do
    assert {:ok, _members} = ctx.before["fx_lex_priv"]

    assert File.regular?(
             Path.join([ctx.proj, "deps", "fx_lex_priv", "src", "fx_lex_priv_lexer.erl"])
           )

    v = ctx.verdict

    assert %{status: :pass, reason: nil} = v,
           inspect({v.reason, v.observations["problems"]}, pretty: true)

    assert v.built_priv == ["assets/a.txt"]
    assert v.observations["trace_stats"]["priv_repro"] == "same"
    assert v.observations["tree_check"] == %{"fx_lex_priv" => "ok"}
  end
end
