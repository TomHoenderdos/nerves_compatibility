defmodule NccWorker.Tracer.FixturesOwnPrivTest do
  # A package's own compile writing into its own build priv (judge revision
  # 21), on real traced compiles with the second build
  # (`NccWorker.Portability.run/3`, `NccWorker.Portability.PrivRepro`).
  # Shaped like kino's `Kino.JS.__before_compile__/1`: `:code.priv_dir/1`,
  # `File.rm_rf!/1` and `File.mkdir_p!/1`, which on Elixir 1.20 probes every
  # directory from `/` down. Deterministic bytes publish, with the files in
  # `built_priv`; the time, a host read, a value that differs between two
  # builds, a path only the first build has, and a write into another
  # package's priv do not. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 900_000

  # The kino-like hook: `use <App>.Hook, app: :x` packs the using module's
  # assets (`content`, an expression evaluated at compile time) into `x`'s
  # own priv.
  defp hook(app, content) do
    """
    defmodule #{Macro.camelize(app)}.Hook do
      defmacro __using__(opts) do
        quote do
          @hook_app unquote(opts[:app])
          @before_compile #{Macro.camelize(app)}.Hook
        end
      end

      defmacro __before_compile__(env) do
        app = Module.get_attribute(env.module, :hook_app)
        dir = Path.join([:code.priv_dir(app), "assets", inspect(env.module)])
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "main.txt"), #{content})
        quote(do: def(assets, do: unquote(Path.basename(dir))))
      end
    end
    """
  end

  defp hooked(app, module, content) do
    use_it = "defmodule #{module} do\n  use #{Macro.camelize(app)}.Hook, app: :#{app}\nend\n"
    %{files: %{"lib/hook.ex" => hook(app, content), "lib/#{app}.ex" => use_it}}
  end

  # A package whose compile packs `content` into
  # `priv/assets/<Module>/main.tar.gz` with `:erl_tar`, as kino does.
  defp tarred(app, content) do
    mod = Macro.camelize(app)

    lib(app, """
    defmodule #{mod}.Hook do
      defmacro __using__(_opts), do: quote(do: @before_compile #{mod}.Hook)

      defmacro __before_compile__(env) do
        dir = Path.join([:code.priv_dir(:#{app}), "assets", inspect(env.module)])
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        archive = String.to_charlist(Path.join(dir, "main.tar.gz"))
        :ok = :erl_tar.create(archive, [{~c"main.js", #{content}}], [:compressed])
        quote(do: def(assets, do: true))
      end
    end

    defmodule #{mod} do
      use #{mod}.Hook
    end
    """)
  end

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-own-priv-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj_dir = Path.join(root, "p/proj")

    deps = %{
      "fx_priv_det" => hooked("fx_priv_det", "FxPrivDet", ~s("assets of " <> "FxPrivDet")),
      "fx_priv_time" =>
        hooked("fx_priv_time", "FxPrivTime", "Integer.to_string(System.os_time(:nanosecond))"),
      "fx_priv_host" =>
        hooked("fx_priv_host", "FxPrivHost", "elem(:inet.gethostname(), 1) |> to_string()"),
      "fx_priv_env" =>
        hooked("fx_priv_env", "FxPrivEnv", ~S{System.get_env("FX_PRIV_ENV") || "unset"}),
      "fx_priv_build" =>
        hooked("fx_priv_build", "FxPrivBuild", ~S{System.get_env("MIX_BUILD_PATH") || ""}),
      # Names the first build's own priv by its path, as no user's build has it.
      "fx_priv_literal" =>
        lib("fx_priv_literal", """
        defmodule FxPrivLiteral do
          @dir #{inspect(Path.join(proj_dir, "_build/host/lib/fx_priv_literal/priv"))}
          File.mkdir_p!(@dir)
          File.write!(Path.join(@dir, "x.txt"), "x")
          def x, do: true
        end
        """),
      # kino's own shape: an `:erl_tar` archive of the assets, whose members
      # carry the time they were packed at.
      "fx_priv_tar" => tarred("fx_priv_tar", ~S|"export function init() {}"|),
      # The same, with the time in a member's bytes.
      "fx_priv_tar_time" =>
        tarred("fx_priv_tar_time", "Integer.to_string(System.os_time(:nanosecond))"),
      # kino_db's shape: a dependent whose compile packs its assets into the
      # hook's own package's priv.
      "fx_priv_user" =>
        lib(
          "fx_priv_user",
          """
          defmodule FxPrivUser do
            use FxPrivDet.Hook, app: :fx_priv_det
          end
          """,
          %{deps: ["fx_priv_det"]}
        )
    }

    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(deps), deps)
    ^proj = proj_dir

    # One package at a time: each run rebuilds the closure into _build/host.
    verdicts =
      for app <- ~w(fx_priv_det fx_priv_time fx_priv_host fx_priv_env fx_priv_build
                    fx_priv_literal fx_priv_user fx_priv_tar fx_priv_tar_time),
          into: %{} do
        {app, run(root, proj, app)}
      end

    %{proj: proj, verdicts: verdicts}
  end

  defp run(root, proj, app) do
    Portability.run(proj, app,
      env: TracerFixtures.env(proj) ++ [{"FX_PRIV_ENV", "on"}],
      releases: %{},
      mode: :judge,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 240_000,
      run_started_at: System.monotonic_time(:second),
      # The project is under the system temp dir: the second build goes
      # under the checkout, which shares no directory with it but `/`.
      repro_root: Path.join(File.cwd!(), "tmp")
    )
  end

  {family, _name} = :os.type()
  @family_only %{"kind" => "os_type", "family" => Atom.to_string(family)}

  defp log(ctx, app), do: inspect(ctx.verdicts[app].observations, pretty: true, limit: 60)

  test "deterministic bytes in the package's own priv publish, listed in built_priv", ctx do
    v = ctx.verdicts["fx_priv_det"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_priv_det")
    assert v.built_priv == ["assets/FxPrivDet/main.txt"]
    assert v.compile_inputs == [@family_only]
    assert is_list(v.compile_env)
    refute Map.has_key?(v, :priv_repro)
    assert v.observations["trace_stats"]["priv_repro"] == "same"
    assert v.observations["problems"] == []

    # The writes and File.mkdir_p/1's probes above priv were observed.
    assert Enum.any?(
             v.observations["priv_writes"],
             &(&1["written"] == "assets/FxPrivDet/main.txt")
           )

    assert v.observations["priv_probes"] != []

    built = Path.join(ctx.proj, "_build/host/lib/fx_priv_det/priv/assets/FxPrivDet/main.txt")
    assert File.read!(built) == "assets of FxPrivDet"
  end

  test "the time in a priv file differs between two builds and refuses", ctx do
    v = ctx.verdicts["fx_priv_time"]
    assert v.status == :skip

    assert v.reason ==
             Reasons.priv_not_reproduced() <>
               "priv/assets/FxPrivTime/main.txt differs between two builds"

    assert v.observations["trace_stats"]["priv_repro"] == "differs"
    assert v.compile_inputs == nil
    refute Map.has_key?(v, :built_priv)
  end

  # The hostname read refuses (OTP's own inet config read with it makes the
  # trace could-not-judge first): either way nothing publishes and no second
  # build runs.
  test "a host read for a priv file refuses before any second build", ctx do
    v = ctx.verdicts["fx_priv_host"]
    assert v.status == :skip
    assert refused?(v, "fx_priv_host", "compile-time host read: inet:gethostname/0")
    assert v.observations["trace_stats"]["priv_repro"] == nil
    refute Map.has_key?(v, :built_priv)
  end

  test "an environment value in a priv file is a compile input the client compares", ctx do
    v = ctx.verdicts["fx_priv_env"]
    assert %{status: :pass} = v, log(ctx, "fx_priv_env")
    assert v.built_priv == ["assets/FxPrivEnv/main.txt"]
    assert Enum.any?(v.compile_inputs, &match?(%{"kind" => "env", "name" => "FX_PRIV_ENV"}, &1))
  end

  test "a value that differs between two builds (the build path) refuses", ctx do
    v = ctx.verdicts["fx_priv_build"]

    assert v.reason ==
             Reasons.priv_not_reproduced() <>
               "priv/assets/FxPrivBuild/main.txt differs between two builds"
  end

  test "the first build's priv named by its path refuses in the second build", ctx do
    v = ctx.verdicts["fx_priv_literal"]
    assert v.status == :skip

    assert String.starts_with?(
             v.reason,
             Reasons.priv_not_reproduced() <>
               "a second build refused (compile-time write outside ebin: "
           )
  end

  # kino_db's shape: never the dependent's own priv. The write refuses in the
  # dependent's window, and it changed the package's build after the
  # package's window closed, which the built check sees first.
  test "a dependent's compile writing into the package's priv refuses", ctx do
    v = ctx.verdicts["fx_priv_user"]
    assert v.status == :skip
    assert "built outside the trace: fx_priv_det" in v.observations["problems"]

    assert Enum.any?(
             v.observations["refusals"],
             &(&1["owner"] == "fx_priv_user" and
                 &1["reason"] =~ "fx_priv_det/priv/assets/FxPrivUser")
           )

    refute Map.has_key?(v, :built_priv)
  end

  defp refused?(v, owner, prefix) do
    Enum.any?(
      v.observations["refusals"],
      &(&1["owner"] == owner and String.starts_with?(&1["reason"], prefix))
    )
  end

  test "an :erl_tar archive whose members' times alone differ publishes", ctx do
    v = ctx.verdicts["fx_priv_tar"]
    assert %{status: :pass, reason: nil} = v, log(ctx, "fx_priv_tar")
    assert v.built_priv == ["assets/FxPrivTar/main.tar.gz"]
    assert v.observations["priv_tar_times"] == ["assets/FxPrivTar/main.tar.gz"]
    assert v.observations["trace_stats"]["priv_repro"] == "same_but_tar_times"
  end

  test "an :erl_tar archive holding the time refuses", ctx do
    v = ctx.verdicts["fx_priv_tar_time"]

    assert v.reason ==
             Reasons.priv_not_reproduced() <>
               "priv/assets/FxPrivTarTime/main.tar.gz differs between two builds"
  end
end
