defmodule NccWorker.Tracer.FixturesOwnPrivRootsTest do
  # A package's own compile writing a path into its own build priv (judge
  # revision 21) that both builds share but no user's machine has: the
  # source path of the module being compiled (`env.file`, the project dir's
  # `deps/<package>`) and the OTP install. The second build varies only the
  # build path, so building twice does not see them; R2 for priv does
  # (`NccWorker.Portability.PrivRoots`), in a plain file and inside a
  # `.tar.gz`. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  import NccWorker.TracerFixtures, only: [lib: 2]

  @moduletag timeout: 900_000

  # Packs `content`, evaluated in `__before_compile__/1` (where `env` is the
  # using module's), into `priv/assets/<Module>/main.txt`, or into
  # `main.tar.gz` with `:erl_tar` when `tar?`.
  defp hooked(app, content, tar?) do
    mod = Macro.camelize(app)

    write =
      if tar?,
        do: """
        archive = String.to_charlist(Path.join(dir, "main.tar.gz"))
        :ok = :erl_tar.create(archive, [{~c"main.js", #{content}}], [:compressed])
        """,
        else: ~s|File.write!(Path.join(dir, "main.txt"), #{content})|

    lib(app, """
    defmodule #{mod}.Hook do
      defmacro __using__(_opts), do: quote(do: @before_compile #{mod}.Hook)

      defmacro __before_compile__(env) do
        dir = Path.join([:code.priv_dir(:#{app}), "assets", inspect(env.module)])
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        #{write}
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
        "ncc-fixtures-own-priv-roots-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)

    deps = %{
      "fx_priv_src" => hooked("fx_priv_src", "env.file", false),
      "fx_priv_tar_src" => hooked("fx_priv_tar_src", "env.file", true),
      "fx_priv_otp" => hooked("fx_priv_otp", "List.to_string(:code.root_dir())", false)
    }

    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(deps), deps)

    verdicts =
      for app <- ~w(fx_priv_src fx_priv_tar_src fx_priv_otp), into: %{} do
        {app, run(root, proj, app)}
      end

    %{proj: proj, verdicts: verdicts}
  end

  defp run(root, proj, app) do
    Portability.run(proj, app,
      env: TracerFixtures.env(proj),
      releases: %{},
      mode: :judge,
      trace_dir: Path.join(root, "trace-#{app}"),
      log_file: Path.join(root, "#{app}.log"),
      timeout_ms: 240_000,
      run_started_at: System.monotonic_time(:second),
      repro_root: Path.join(File.cwd!(), "tmp")
    )
  end

  defp log(ctx, app), do: inspect(ctx.verdicts[app], pretty: true, limit: 60)

  test "a source path the compile wrote into its own priv refuses", ctx do
    v = ctx.verdicts["fx_priv_src"]
    assert v.status == :skip, log(ctx, "fx_priv_src")
    assert v.reason == "bakes the build path: priv/assets/FxPrivSrc/main.txt"
    refute Map.has_key?(v, :built_priv)
    # Refused before any second build.
    assert v.observations["trace_stats"]["priv_repro"] == nil
  end

  test "a source path inside a .tar.gz the compile wrote refuses", ctx do
    v = ctx.verdicts["fx_priv_tar_src"]
    assert v.status == :skip, log(ctx, "fx_priv_tar_src")
    assert v.reason == "bakes the build path: priv/assets/FxPrivTarSrc/main.tar.gz"
    refute Map.has_key?(v, :built_priv)
  end

  # `:code.root_dir/0` may itself refuse as a host read; either way nothing
  # publishes.
  test "the OTP install path the compile wrote into its own priv refuses", ctx do
    v = ctx.verdicts["fx_priv_otp"]
    assert v.status == :skip, log(ctx, "fx_priv_otp")
    refute Map.has_key?(v, :built_priv)
  end
end
