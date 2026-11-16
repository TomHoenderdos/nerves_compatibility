defmodule NccWorker.Portability.HostNativeJudgeTest do
  # A host-native build's verdict on hand-built reports (`target: "host"`,
  # `host_native: true`): the firmware target mode plus the package's own
  # priv libraries and R2 on its ebin. The tool's activity on real compiles
  # is `NccWorker.Tracer.FixturesHostNativeTest`.
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}
  @host_native [target: "host", host_native: true]

  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")

    for app <- ["dep", "pkg"] do
      File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib", app, "ebin"]))
      File.write!(Path.join([proj, "deps", app, "lib", app <> ".ex"]), "")
      File.write!(Path.join([proj, "deps", app, "mix.exs"]), "")
    end

    File.mkdir_p!(Path.join([proj, "_build/host/lib/pkg/priv/native"]))
    File.write!(Path.join(proj, "mix.exs"), "")
    %{proj: proj}
  end

  defp dep(proj, app, children) do
    %{
      "app" => app,
      "dest" => Path.join([proj, "deps", app]),
      "build" => Path.join([proj, "_build/host/lib", app]),
      "manager" => "mix",
      "children" => children
    }
  end

  defp window(app, open, close, libs),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: libs
    }

  # `pkg_libs`: what is mapped when pkg's window closes and at the end.
  defp report(proj, pkg_libs \\ @libs) do
    %Report{
      start: Map.merge(%{"otp_root" => "/nonexistent-otp"}, @libs),
      closure: %{
        "packages" => ["pkg"],
        "deps" => [dep(proj, "dep", []), dep(proj, "pkg", ["dep"])]
      },
      windows: [window("dep", 10, 20, @libs), window("pkg", 30, 40, pkg_libs)],
      sentinels: [
        %{app: "dep", ts: 11, integrity_ok: true},
        %{app: "pkg", ts: 31, integrity_ok: true}
      ],
      stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
      ending:
        Map.merge(
          %{
            "status" => "ok",
            "depth_ok" => true,
            "final_sentinel" => true,
            "overflow" => false,
            "integrity_ok" => true,
            "delivered" => true
          },
          pkg_libs
        )
    }
  end

  defp judge(proj, report, opts),
    do:
      Portability.judge(proj, "pkg", report, [], [built_check: false, nif_waiver: false] ++ opts)

  defp mapped(proj, path),
    do: %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6", Path.join(proj, path)]}

  test "a clean trace passes, as a firmware target's does", %{proj: proj} do
    assert %{status: :pass, compile_inputs: [], compile_env: []} =
             judge(proj, report(proj), @host_native)
  end

  test "the package's own priv library may be mapped in its compile", %{proj: proj} do
    libs = mapped(proj, "_build/host/lib/pkg/priv/native/libpkg.so")
    File.write!(Path.join(proj, "_build/host/lib/pkg/priv/native/libpkg.so"), "x")

    assert %{status: :pass, observations: obs} = judge(proj, report(proj, libs), @host_native)
    assert Enum.any?(obs["native_libs"], &String.ends_with?(&1, "/priv/native/libpkg.so"))

    # Not without host_native, and not on the toolchain judge.
    assert %{status: :skip, reason: "compile-time native library load: " <> _} =
             judge(proj, report(proj, libs), target: "host")

    assert %{status: :skip, reason: "compile-time native library load: " <> _} =
             judge(proj, report(proj, libs), [])

    # `host_native:` alone is off.
    assert %{status: :skip} = judge(proj, report(proj, libs), host_native: true)
  end

  test "a library outside the package's priv still refuses", %{proj: proj} do
    for path <- ["_build/host/lib/pkg/ebin/libpkg.so", "_build/host/lib/dep/priv/libdep.so"] do
      libs = mapped(proj, path)

      assert %{status: :skip, reason: "compile-time native library load: " <> _} =
               judge(proj, report(proj, libs), @host_native),
             path
    end
  end

  test "a baked build path in the package's beams refuses", %{proj: proj} do
    source =
      "defmodule HostNativeR2Bake do\n  def f, do: #{inspect(Path.join(proj, "x") <> " y")}\nend\n"

    ebin = Path.join(proj, "_build/host/lib/pkg/ebin")

    for {module, binary} <-
          Code.compile_string(source, Path.join(proj, "deps/pkg/lib/pkg.ex")) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end

    assert %{status: :skip, reason: "bakes the build path: " <> _} =
             judge(proj, report(proj), @host_native)

    # A firmware target's verdict leaves R2 to FirmwareBuildRoot.
    assert %{status: :pass} = judge(proj, report(proj), target: "host")
  end

  test "the tools a host-native build sets apart" do
    assert Portability.native_tools() == ["elixir_make"]
    assert Portability.host_native_tools() == ["rustler_precompiled"]
  end
end
