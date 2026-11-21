defmodule NccWorker.Tracer.FixturesOtpProbeTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{BuildIdentity, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # Mix compiles a dependency on a code path pruned to the applications its
  # closure lists (`Mix.Tasks.Compile.All`); Mix.install does not prune
  # (`prune_code_paths: false`, which the dependencies inherit). A probe of
  # an installed OTP application the package does not list answers `false`
  # in a Mix project and `true` under Mix.install, so the two compile
  # different code (vega_lite 0.1.11's `VegaLite.WxViewer` and `:wx`).
  # mnesia stands in for wx: every OTP build has it, and neither Mix, Hex
  # nor the tracer loads it.
  @refusal "compile-time probe of an OTP application outside the closure: "

  defp probe_fixture(dir, extra_applications, expr \\ "Code.ensure_loaded?(:mnesia)") do
    TracerFixtures.project(dir, ["fx_probe"], %{
      "fx_probe" => %{
        extra_applications: extra_applications,
        files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", expr)}
      }
    })
  end

  defp compile(proj) do
    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  # What `FxProbe.x/0` returns in the build under `_build/host`.
  defp built_value(proj) do
    ebin = Path.join([proj, "_build", "host", "lib", "fx_probe", "ebin"])
    {out, 0} = System.cmd("elixir", ["-pa", ebin, "-e", "IO.write(inspect(FxProbe.x()))"])
    out
  end

  # The wrapper project as Mix.install configures its own: no pruning.
  defp unpruned!(proj) do
    path = Path.join(proj, "mix.exs")
    mix_exs = File.read!(path)

    File.write!(
      path,
      String.replace(mix_exs, "deps: [", "prune_code_paths: false, deps: [", global: false)
    )
  end

  defp published(proj) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for path <- Path.wildcard(Path.join(lib, "*/{ebin,priv}/**")),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, lib), File.read!(path)}
  end

  defp probes(traced), do: Enum.filter(traced.report.events, &(&1["channel"] == "probe"))

  # Read from the installs' ebin dirs, not the code path: what Mix.install
  # finds. Not a module loaded before the tracer started, nor one it
  # loaded itself (`preloaded`), nor one of an application on every
  # compile's path.
  test "the tracer watches the installed modules off every compile's path" do
    mods = :ncc_tracer.installed_modules(%{mnesia_lib: true}, %{"mnesia_log" => "mnesia"})

    assert mods["mnesia"] == "mnesia"
    assert mods["mnesia_tm"] == "mnesia"
    assert mods["Elixir.EEx"] == "eex"
    refute Map.has_key?(mods, "mnesia_lib")
    refute Map.has_key?(mods, "mnesia_log")

    # Mix loads these in every compile (`:ncc_tracer.loaded_by_mix/0`).
    for m <- :ncc_tracer.loaded_by_mix(), do: refute(Map.has_key?(mods, Atom.to_string(m)))

    for m <- ~w(lists gen_server compile Elixir.Kernel Elixir.Mix.Project Elixir.IEx
                Elixir.ExUnit Elixir.Logger.Formatter erlang prim_file ncc_tracer),
        do: refute(Map.has_key?(mods, m), m)
  end

  test "a probe of an OTP application the package does not list is refused", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [])

    # The class itself: the same project compiles `false` pruned, `true`
    # unpruned.
    compile(proj)
    assert built_value(proj) == "false"
    untraced = published(proj)

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    # The trace builds what a Mix project builds.
    assert BuildIdentity.differences(published(proj), untraced) == []

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via Code.ensure_loaded?/1"

    # A firmware target's trace refuses it too: `mix firmware` prunes, but
    # what an earlier compile loaded stays visible (below).
    firmware = TracerFixtures.judge(proj, "fx_probe", traced, [], target: "rpi4")
    assert %{status: :skip, reason: ^reason} = firmware

    # The event shapes the judge reads (pinned on this toolchain): the
    # package's probe, and the code server's own module_loaded/1 inside it.
    mnesia = probes(traced) |> Enum.filter(&(&1["arg"]["module"] == "mnesia"))
    assert [event] = Enum.filter(mnesia, &(&1["mfa"] == "code:ensure_loaded/1"))
    assert [inner] = Enum.filter(mnesia, &(&1["mfa"] == "erlang:module_loaded/1"))
    assert inner["caller"]["module"] == "code"
    assert inner["caller"]["function"] == "ensure_loaded"
    assert event["arg"]["otp_app"] == "mnesia"
    assert event["arg"]["app"] == nil
    assert event["arg"]["checker"] == false
    assert event["caller"]["module"] == "Elixir.Code"
    assert event["caller"]["function"] == "ensure_loaded?"
    assert event["extent"] == "frame"
    refute Map.has_key?(traced.report.start["preloaded"], "mnesia")

    unpruned!(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    compile(proj)
    assert built_value(proj) == "true"
  end

  # Why a pruned Mix project (`mix firmware` included) is no stand-in for
  # the builder: pruning decides only what can be newly found. fx_a lists
  # mnesia and loads it; fx_probe, compiled after it in the same VM, finds
  # it loaded although its own path is pruned. Built alone, as the builder
  # builds it, fx_probe finds nothing.
  test "an earlier dependency's load is visible to a pruned compile", %{tmp_dir: dir} do
    probe = TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(:mnesia)")

    alone =
      TracerFixtures.project(Path.join(dir, "alone"), ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    both =
      TracerFixtures.project(Path.join(dir, "both"), ["fx_a", "fx_probe"], %{
        "fx_a" => %{
          extra_applications: [:mnesia],
          files: %{
            "lib/fx_a.ex" => TracerFixtures.attr_module("FxA", "Code.ensure_loaded?(:mnesia)")
          }
        },
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => probe}}
      })

    compile(alone)
    compile(both)
    assert built_value(alone) == "false"
    assert built_value(both) == "true"
  end

  test "a probe of an OTP application the package lists passes", %{tmp_dir: dir} do
    expr = "{Code.ensure_loaded?(:mnesia), is_list(:code.which(:mnesia_lib))}"
    proj = probe_fixture(dir, [:mnesia], expr)
    compile(proj)
    assert built_value(proj) == "{true, true}"
    untraced = published(proj)

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)

    modules = traced |> probes() |> Enum.map(& &1["arg"]["module"])
    assert "mnesia" in modules and "mnesia_lib" in modules, inspect(modules)
  end

  # Calls the package makes only at run time, and a behaviour it declares,
  # of an application it does not list: the compiler's own lookups (the
  # type checker's, which also checks behaviours) reach its warnings only.
  test "run-time calls and a behaviour of an unlisted OTP application pass", %{tmp_dir: dir} do
    body = """
    defmodule FxProbe do
      @behaviour :mnesia_frag_hash
      def init_state(_tab, state), do: state
      def add_frag(state), do: {state, [], []}
      def del_frag(state), do: {state, [], []}
      def key_to_frag_number(_state, _key), do: 1
      def match_spec_to_frag_numbers(_state, _spec), do: [1]
      def x, do: :mnesia.system_info(:version)
      def y, do: :mnesia_lib.dir()
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => body}}
      })

    compile(proj)
    untraced = published(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []

    verdict = TracerFixtures.judge(proj, "fx_probe", traced)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    # The lookup `@behaviour` makes, pinned on this toolchain.
    assert [lookup] =
             Enum.filter(
               probes(traced),
               &(&1["arg"]["module"] == "mnesia_frag_hash" and &1["mfa"] == "code:ensure_loaded/1")
             )

    assert lookup["arg"]["attribute"] == true
    assert lookup["arg"]["otp_app"] == "mnesia"
    assert lookup["caller"]["module"] == "Elixir.Code"
    assert lookup["caller"]["function"] == "ensure_compiled"

    # And what makes it no concern: unpruned, the beams are the same.
    unpruned!(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    compile(proj)
    assert BuildIdentity.differences(published(proj), untraced) == []
  end

  # Whether a module is loaded now: untraced and pruned, nothing loads
  # mnesia; under Mix.install another compile may have.
  test "a loaded-now probe of an OTP application the package does not list is refused",
       %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], "function_exported?(:mnesia, :start, 0)")
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via erlang:function_exported/3"
  end

  # easel 0.3.4's `optional_apps/0`: its mix.exs asks for :wx when
  # compile.all reads its application/0, on whatever code path the previous
  # dependency's compile left.
  test "a probe from a dependency's mix.exs is refused even when it lists the application",
       %{tmp_dir: dir} do
    mix_exs = """
    defmodule FxProbe.MixProject do
      use Mix.Project
      def project, do: [app: :fx_probe, version: "0.1.0", deps: []]
      def application, do: [extra_applications: [:logger] ++ optional_apps()]
      defp optional_apps, do: if(Code.ensure_loaded?(:mnesia), do: [:mnesia], else: [])
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          mix_exs: mix_exs,
          files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", "1")}
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert reason == @refusal <> "mnesia via Code.ensure_loaded?/1 in mix.exs"
  end

  # A closure dependency's probe is a refusal in its window, which taints
  # every package that depends on it (R3), as any refusal there does.
  test "a closure dependency's probe taints the package", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_top"], %{
        "fx_top" => %{
          deps: ["fx_probe"],
          files: %{"lib/fx_top.ex" => "defmodule FxTop do\n  def f, do: FxProbe.x()\nend\n"}
        },
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              TracerFixtures.attr_module("FxProbe", "Code.ensure_loaded?(:mnesia)")
          }
        }
      })

    traced = TracerFixtures.trace(proj, ["fx_top"])
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: reason} = TracerFixtures.judge(proj, "fx_top", traced)

    assert reason ==
             "closure dependency observed the host: fx_probe (" <>
               @refusal <> "mnesia via Code.ensure_loaded?/1)"
  end
end
