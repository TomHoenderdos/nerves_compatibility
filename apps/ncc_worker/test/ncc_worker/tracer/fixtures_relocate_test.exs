defmodule NccWorker.Tracer.FixturesRelocateTest do
  # Relocatable builds (S4), on real traced compiles with the second build
  # at another root (`NccWorker.Portability.run/3` with `relocate: true`,
  # `NccWorker.Portability.Relocate`). `fx_fine` is shaped like fine 0.2.0:
  # `Path.expand("c_include")` from its own dir, returned by a function.
  # Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias Compatibility.Relocation
  alias NccWorker.{Portability, TracerFixtures}
  alias NccWorker.Portability.Context

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 1_200_000

  @fine """
  defmodule FxFine do
    @include_dir Path.expand("c_include")
    def include_dir, do: @include_dir
  end
  """

  setup_all do
    # A real path: R2's roots and `__DIR__` are real paths, and macOS's
    # temp dir is under the /var link.
    root =
      Path.join(
        Context.realpath(System.tmp_dir!()),
        "ncc-fixtures-relocate-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    deps = %{
      "fx_fine" => lib("fx_fine", @fine),
      # Calls fx_fine only at run time.
      "fx_quiet" =>
        lib("fx_quiet", "defmodule FxQuiet do\n  def dir, do: FxFine.include_dir()\nend\n", %{
          deps: ["fx_fine"]
        }),
      # Hashes the path at compile time: no path in its own beams.
      "fx_hash" =>
        lib(
          "fx_hash",
          "defmodule FxHash do\n  @h :erlang.md5(FxFine.include_dir())\n  def h, do: @h\nend\n",
          %{deps: ["fx_fine"]}
        ),
      # A dependency that hashes it, and a package above it that does not.
      "fx_mid" =>
        lib(
          "fx_mid",
          "defmodule FxMid do\n  @h :erlang.md5(FxFine.include_dir())\n  def h, do: @h\nend\n",
          %{deps: ["fx_fine"]}
        ),
      "fx_top" =>
        lib("fx_top", "defmodule FxTop do\n  def h, do: FxMid.h()\nend\n", %{deps: ["fx_mid"]}),
      # The umbrella review's B2: a holder's md5 read at compile time, a
      # value its relocation changes.
      "fx_md5" =>
        lib(
          "fx_md5",
          "defmodule FxMd5 do\n  @m FxFine.__info__(:md5)\n  def m, do: @m\nend\n",
          %{deps: ["fx_fine"]}
        ),
      # A value derived from where fx_fine was built, through a channel the
      # holder patterns do not see: the package's own ebin, compared at the
      # two roots, must catch it.
      "fx_len" =>
        lib(
          "fx_len",
          "defmodule FxLen do\n  @n FxFine.__info__(:module) |> :code.which() |> length()\n  def n, do: @n\nend\n",
          %{deps: ["fx_fine"]}
        ),
      # membrane_core's shape: a macro module whose quoted code keeps its
      # location (a path R2 allows), and a task module that bakes its dir.
      "fx_macro" =>
        lib("fx_macro", """
        defmodule FxMacro do
          defmacro __using__(_opts) do
            quote location: :keep do
              def hello, do: :hello
            end
          end
        end

        defmodule FxMacro.Task do
          @dir __DIR__
          def dir, do: @dir
        end
        """),
      "fx_user" =>
        lib("fx_user", "defmodule FxUser do\n  use FxMacro\nend\n", %{deps: ["fx_macro"]}),
      # The umbrella re-review's Q1: a holder, and beside it a module that
      # holds no path but bakes a test of it against a constant; a dependent
      # reads that test at compile time, through no holder.
      "fx_flag" =>
        lib("fx_flag", """
        defmodule FxFlag do
          @dir __DIR__
          def dir, do: @dir
        end

        defmodule FxFlag.Mac do
          @mac String.contains?(__DIR__, "/Users/")
          def mac?, do: @mac
        end
        """),
      "fx_flag_user" =>
        lib(
          "fx_flag_user",
          "defmodule FxFlagUser do\n  @mac FxFlag.Mac.mac?()\n  def mac?, do: @mac\nend\n",
          %{deps: ["fx_flag"]}
        ),
      # The path inside a binary the code builds: the string table.
      "fx_strt" =>
        lib(
          "fx_strt",
          "defmodule FxStrt do\n  def f(x), do: <<__DIR__::binary, x::binary>>\nend\n"
        )
    }

    top = ~w(fx_fine fx_quiet fx_hash fx_top fx_strt fx_user fx_md5 fx_len fx_flag fx_flag_user)
    proj = TracerFixtures.project(Path.join(root, "p"), top, deps)
    deps_from_env!(proj)

    # One package at a time, each from a clean build path; fx_fine's served
    # beam is kept.
    verdicts =
      for app <- top, into: %{} do
        File.rm_rf!(Path.join(proj, "_build"))
        verdict = run(root, proj, app)
        beam = Path.join(proj, "_build/host/lib/fx_fine/ebin/Elixir.FxFine.beam")
        if app == "fx_fine", do: File.cp!(beam, Path.join(root, "fx_fine.beam"))
        {app, verdict}
      end

    %{proj: proj, root: root, verdicts: verdicts}
  end

  # The wrapper's own dependencies at `MIX_DEPS_PATH`, as Hex dependencies
  # are, so the second build finds them in its own deps dir.
  defp deps_from_env!(proj) do
    file = Path.join(proj, "mix.exs")

    body =
      Regex.replace(~r/path: "deps\/([^"]+)"/, File.read!(file), fn _, app ->
        ~s|path: Path.join(System.fetch_env!("MIX_DEPS_PATH"), "#{app}")|
      end)

    File.write!(file, body)
  end

  defp run(root, proj, app) do
    Portability.run(proj, app,
      env: TracerFixtures.container_env(proj, root),
      releases: %{},
      mode: :judge,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 240_000,
      run_started_at: System.monotonic_time(:second),
      relocate: true,
      relocate_root: root
    )
  end

  defp log(ctx, app), do: inspect(ctx.verdicts[app], pretty: true, limit: 60)
  defp stat(v), do: v.observations["trace_stats"]["relocate"]

  test "a package that bakes its deps path passes with the occurrences to rewrite", ctx do
    v = ctx.verdicts["fx_fine"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_fine")
    assert stat(v) == "relocated"
    refute Map.has_key?(v, :relocate)

    deps = Path.join(ctx.proj, "deps")

    assert %{
             "deps" => ^deps,
             "build" => build,
             "files" => [file],
             "second" => second,
             "third" => third
           } = v.relocation

    assert build == Path.join(ctx.proj, "_build/host")

    # The other two roots, the worker's layouts under `relocate_root:` for
    # one run token (B1, R1).
    [_, n] = Regex.run(~r"/ncc-relocate-([0-9]+)/", second["deps"])
    n = String.to_integer(n)
    base = Context.realpath(ctx.root)
    at = &Map.take(&1, ["deps", "build"])
    assert at.(Relocation.second_layout(Path.join(base, "home/ncc-relocate"), n)) == second
    refute String.starts_with?(second["deps"], Path.join(base, "home/nerves"))
    assert at.(Relocation.third_layout(Path.join(base, "Users"), n)) == third
    refute File.exists?(Path.join(base, "Users/Ncc-Relocate #{n}"))

    assert Relocation.record_problem(v.relocation, ["ebin/Elixir.FxFine.beam", "ebin/fx_fine.app"]) ==
             nil

    assert %{"path" => "ebin/Elixir.FxFine.beam", "occurrences" => [occ]} = file

    assert %{"chunk" => "LitT", "kind" => "binary", "parts" => ["", "deps", "/fx_fine/c_include"]} =
             occ

    # The served beam, relocated to another user's paths, holds theirs.
    beam = File.read!(Path.join(ctx.root, "fx_fine.beam"))
    user = %{"deps" => "/home/u/app/deps", "build" => "/home/u/app/_build/dev"}

    assert {:ok, moved} =
             Relocation.relocate(
               beam,
               file["occurrences"],
               Map.take(v.relocation, ["deps", "build"]),
               user
             )

    assert {:ok, {FxFine, [{~c"LitT", _}]}} = :beam_lib.chunks(moved, [~c"LitT"])
    assert :binary.match(moved, "/home/u/app/deps/fx_fine/c_include") != :nomatch
  end

  # The umbrella re-review's Q1: a dependent that passed because a
  # dependency was held rests on the same residual, so it carries the same
  # record (the three roots), with nothing to rewrite in its own beams, and
  # is stored, served and revoked as a relocated build.
  test "a dependent that never calls the holder at compile time passes, relocated", ctx do
    v = ctx.verdicts["fx_quiet"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_quiet")
    assert stat(v) == "dependencies"
    assert %{"files" => [], "second" => _, "third" => _} = v.relocation
    assert Relocation.record_problem(v.relocation, ["ebin/Elixir.FxQuiet.beam"]) == nil
  end

  # Its line table names fx_macro's file by the builder's path (a `keep`
  # location R2 allows): the record rewrites it to the user's.
  test "a dependent that expands a macro of a module R2 allows passes, relocated", ctx do
    v = ctx.verdicts["fx_user"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_user")
    assert stat(v) == "dependencies"

    assert %{"files" => [%{"path" => "ebin/Elixir.FxUser.beam", "occurrences" => occs}]} =
             v.relocation

    assert Enum.all?(occs, &(&1["chunk"] == "Line"))
  end

  # The umbrella re-review's Q1, its reproduction: the third root, built for
  # every hold, refuses the dependency's test of its path against
  # `/Users/`, so the dependent stays refused and is never a pass.
  test "a dependent that reads a dependency's test of its path stays refused", ctx do
    flag = ctx.verdicts["fx_flag"]
    assert flag.status == :skip, log(ctx, "fx_flag")
    assert stat(flag) =~ "fx_flag: Elixir.FxFlag.Mac.beam: AtU8 differs at another root"

    v = ctx.verdicts["fx_flag_user"]
    assert v.status == :skip, log(ctx, "fx_flag_user")
    refute Map.has_key?(v, :relocation)
    assert stat(v) =~ "fx_flag: Elixir.FxFlag.Mac.beam: AtU8 differs at another root"
  end

  # The umbrella review's B2: a holder's md5, read at compile time, is a
  # holder call, and the dependent stays refused.
  test "a dependent that reads a holder's md5 at compile time stays refused", ctx do
    v = ctx.verdicts["fx_md5"]
    assert v.status == :skip, log(ctx, "fx_md5")
    assert stat(v) =~ "calls a build-path holder at compile time: FxFine.__info__/1"
  end

  # What the holder patterns do not see, the package's own ebin, compared
  # at the two roots, refuses.
  test "a dependent's own beams that differ at the two roots stay refused", ctx do
    v = ctx.verdicts["fx_len"]
    assert v.status == :skip, log(ctx, "fx_len")
    assert stat(v) =~ "fx_len: Elixir.FxLen.beam: Code differs at another root"
  end

  test "a package whose compile calls the holder stays refused", ctx do
    v = ctx.verdicts["fx_hash"]
    assert v.status == :skip
    assert v.reason =~ "closure dependency observed the host: fx_fine (bakes the build path"

    assert stat(v) ==
             "refused: the second build refused " <>
               "(calls a build-path holder at compile time: FxFine.include_dir/0)"
  end

  test "a dependency whose compile calls the holder taints the package above it", ctx do
    v = ctx.verdicts["fx_top"]
    assert v.status == :skip
    assert v.reason =~ "closure dependency observed the host: fx_fine"

    assert stat(v) ==
             "refused: the second build refused (closure dependency observed the host: " <>
               "fx_mid (calls a build-path holder at compile time: FxFine.include_dir/0))"
  end

  # The umbrella re-review's Q3: a verdict with nothing held still says
  # relocation was on.
  test "a path in the string table is not held for a second build", ctx do
    v = ctx.verdicts["fx_strt"]
    assert v.status == :skip
    assert v.reason =~ "bakes the build path: Elixir.FxStrt string table"
    assert stat(v) == "on"
  end
end
