defmodule NccWorker.Tracer.HostModeTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{BuildIdentity, TracerFixtures, Tracer.Report}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  # A macro dependency, a plain one with a priv file and a protocol, a
  # mix-built Erlang one and the package, which implements the protocol.
  defp fixture(dir) do
    TracerFixtures.project(dir, ["fx_top"], %{
      "fx_top" => %{
        deps: ["fx_leaf", "fx_mac", "fx_erl"],
        files: %{
          "lib/fx_top.ex" => """
          defmodule FxTop do
            require FxMac
            @moduledoc "Top."
            def f, do: {FxLeaf.f(), FxMac.twice(21), :fx_erl.g()}
          end

          defimpl FxShape, for: Integer do
            def area(n), do: n * n
          end
          """
        }
      },
      "fx_leaf" => %{
        files: %{
          "lib/fx_leaf.ex" =>
            "defmodule FxLeaf do\n  @moduledoc \"Leaf.\"\n  @doc \"F.\"\n  def f, do: :ok\nend\n",
          "lib/fx_shape.ex" => "defprotocol FxShape do\n  def area(shape)\nend\n",
          "priv/data.txt" => "leaf data\n"
        }
      },
      "fx_mac" => %{
        files: %{
          "lib/fx_mac.ex" => """
          defmodule FxMac do
            defmacro twice(x), do: quote(do: unquote(x) * 2)
          end
          """
        }
      },
      "fx_erl" => %{
        files: %{"src/fx_erl.erl" => "-module(fx_erl).\n-export([g/0]).\ng() -> erl.\n"}
      }
    })
  end

  # Every published file of every built app (`subs`: the default, or
  # `["consolidated"]` for the project's consolidated protocols): path => bytes.
  defp published(proj, subs \\ ["ebin", "priv"]) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for app <- File.ls!(lib),
        sub <- subs,
        root = Path.join([lib, app, sub]),
        rel <- Path.wildcard(Path.join(root, "**"), match_dot: true),
        File.regular?(rel),
        into: %{},
        do: {Path.relative_to(rel, lib), File.read!(rel)}
  end

  # The mtime of every beam in an `ebin`.
  defp mtimes(proj) do
    lib = Path.join([proj, "_build", "host", "lib"])

    for path <- Path.wildcard(Path.join(lib, "*/ebin/*.beam")),
        into: %{},
        do: {Path.relative_to(path, lib), File.stat!(path, time: :posix).mtime}
  end

  defp plain_compile(proj) do
    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
  end

  # Identity in `NccWorker.BuildIdentity`'s sense: every file byte-equal,
  # except that a beam's Dbgi chunk only has to decode to `===` terms.
  test "the host-mode trace builds exactly what an untraced mix compile builds", %{tmp_dir: dir} do
    proj = fixture(dir)
    plain_compile(proj)
    untraced = published(proj)
    assert Map.has_key?(untraced, "fx_top/ebin/Elixir.FxTop.beam")
    assert Map.has_key?(untraced, "fx_erl/ebin/fx_erl.beam")
    assert Map.has_key?(untraced, "fx_leaf/priv/data.txt")
    assert Map.has_key?(untraced, "fixture_wrapper/ebin/fixture_wrapper.app")

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == []
    assert Report.mode(traced.report) == :host

    host = published(proj)
    assert Enum.sort(Map.keys(host)) == Enum.sort(Map.keys(untraced))
    assert BuildIdentity.differences(host, untraced) == []
  end

  # Consolidated protocols are not published; their ExCk chunk may differ in
  # map key order (Mix consolidates in parallel), so it is compared decoded.
  test "the host-mode trace consolidates exactly what an untraced mix compile does",
       %{tmp_dir: dir} do
    proj = fixture(dir)
    plain_compile(proj)
    untraced = published(proj, ["consolidated"])
    assert Map.has_key?(untraced, "fixture_wrapper/consolidated/Elixir.FxShape.beam")

    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert BuildIdentity.differences(published(proj, ["consolidated"]), untraced,
             consolidated: true
           ) == []
  end

  test "an untraced mix compile right after the host trace compiles nothing", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    before = mtimes(proj)
    consolidated = published(proj, ["consolidated"])
    assert Map.has_key?(consolidated, "fixture_wrapper/consolidated/Elixir.FxShape.beam")
    assert Map.has_key?(before, "fx_top/ebin/Elixir.FxTop.beam")
    # mtimes have one-second resolution: a rewrite now would show.
    Process.sleep(1_100)

    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status == 0, out
    refute out =~ "Compiling", out
    assert mtimes(proj) == before
    # Mix consolidates a project with path dependencies again on every
    # compile, untraced too. Its bytes are compared in the consolidation test.
    assert Map.keys(published(proj, ["consolidated"])) == Map.keys(consolidated)
  end

  test "the project itself is compiled, after the last window", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    wrapper = Path.join([proj, "_build", "host", "lib", "fixture_wrapper", "ebin"])
    assert File.regular?(Path.join(wrapper, "fixture_wrapper.app"))

    apps = Enum.map(traced.report.windows, & &1.app)
    assert Enum.sort(apps) == ["fx_erl", "fx_leaf", "fx_mac", "fx_top"]
    assert List.last(apps) == "fx_top"
    assert %{"status" => "ok", "final_sentinel" => true} = traced.report.ending
  end

  test "judge mode, the default, compiles the closure only", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"])
    assert {:ok, 0} = traced.result, traced.log
    assert Report.mode(traced.report) == :judge
    refute File.exists?(Path.join([proj, "_build", "host", "lib", "fixture_wrapper"]))
  end

  test "a dependency already in _build is compiled again in its window", %{tmp_dir: dir} do
    proj = fixture(dir)
    stale = Path.join([proj, "_build", "host", "lib", "fx_leaf", "ebin"])
    File.mkdir_p!(stale)
    File.write!(Path.join(stale, "Elixir.Stale.beam"), "not a beam")

    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    refute File.exists?(Path.join(stale, "Elixir.Stale.beam"))
    assert "fx_leaf" in Enum.map(traced.report.windows, & &1.app)
  end

  test "a project that does not compile makes the host-mode trace exit non-zero", %{tmp_dir: dir} do
    proj = fixture(dir)
    File.mkdir_p!(Path.join(proj, "lib"))
    File.write!(Path.join(proj, "lib/broken.ex"), "defmodule Broken do\n  def f, do: \nend\n")

    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, status} = traced.result
    assert status != 0
    assert traced.report.ending["status"] == "compile_failed"
  end

  test "a dependency rewritten after its window is not judged", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_top", traced)

    beam = Path.join([proj, "_build", "host", "lib", "fx_leaf", "ebin", "Elixir.FxLeaf.beam"])
    File.write!(beam, File.read!(beam) <> "x")

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_top", traced)

    assert "built outside the trace: fx_leaf" in obs["problems"]
  end

  test "the package's own build rewritten after the compile is not judged", %{tmp_dir: dir} do
    proj = fixture(dir)
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_top", traced)

    beam = Path.join([proj, "_build", "host", "lib", "fx_top", "ebin", "Elixir.FxTop.beam"])
    File.write!(beam, File.read!(beam) <> "x")

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_top", traced)

    assert "built outside the trace: fx_top" in obs["problems"]
  end

  test "run/3 judges no dependency rewritten after its window", %{tmp_dir: dir} do
    proj = fixture(dir)
    beam = Path.join([proj, "_build", "host", "lib", "fx_leaf", "ebin", "Elixir.FxLeaf.beam"])

    run = fn reap ->
      NccWorker.Portability.run(proj, "fx_top",
        env: TracerFixtures.env(proj),
        releases: %{},
        mode: :host,
        log_file: Path.join(dir, "run.log"),
        timeout_ms: 240_000,
        run_started_at: System.monotonic_time(:second),
        reap: reap
      )
    end

    assert %{status: :pass} = run.(fn _build -> :ok end), File.read!(Path.join(dir, "run.log"))

    # Stands in for a writer the compile left running: the reaper runs after
    # the compile, before the report is read.
    rewrite = fn _build ->
      File.write!(beam, File.read!(beam) <> "x")
      :ok
    end

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             run.(rewrite)

    assert "built outside the trace: fx_leaf" in obs["problems"]
    assert obs["trace_stats"]["transient"] == false
  end

  # A package whose module body evaluates `expr` at compile time, listing
  # `extra_applications` besides :logger.
  defp probe_fixture(dir, extra_applications, expr \\ "Code.ensure_loaded?(:dbg)") do
    TracerFixtures.project(dir, ["fx_probe"], %{
      "fx_probe" => %{
        extra_applications: extra_applications,
        files: %{
          "lib/fx_probe.ex" => """
          defmodule FxProbe do
            @probe #{expr}
            def probe, do: @probe
          end
          """
        }
      }
    })
  end

  # Compiles `proj` untraced, then traced from a clean _build: the
  # published files of each, and the trace.
  defp both(proj) do
    plain_compile(proj)
    untraced = published(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    {untraced, published(proj), traced}
  end

  defp probes(traced), do: Enum.filter(traced.report.events, &(&1["channel"] == "probe"))

  test "a probe of a module only the tracer loaded is not judged", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [])
    {untraced, host, traced} = both(proj)
    preloaded = traced.report.start["preloaded"]
    assert preloaded["dbg"] == "runtime_tools"
    # Loaded by the tracer's own work, not by patterning: its session and
    # its line writer.
    assert preloaded["trace"] == "kernel"
    assert preloaded["json"] == "stdlib"
    # No tracer module exists in an untraced compile.
    for m <- ~w(ncc_tracer ncc_tracer_digest ncc_tracer_probe Elixir.Mix.Tasks.Ncc.TraceCompile),
        do: assert(preloaded[m] == "ncc_tracer", m)

    assert traced.report.ending["late_loaded"] == []

    # The trace loaded :dbg, which fx_probe could not load untraced: the
    # beams differ, and the build must not publish.
    refute host == untraced

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    problem = "compile-time probe of a module the trace loaded: dbg (runtime_tools)"
    assert problem in obs["problems"]
  end

  # The answers that cannot differ: whether a module can be loaded, where it
  # is and its object code, when its application is on the package's path.
  test "a probe of a module its own applications provide is judged as usual", %{tmp_dir: dir} do
    expr =
      "{Code.ensure_loaded?(:dbg), is_list(:code.which(:dbg)), " <>
        "is_tuple(:code.get_object_code(:dbg))}"

    proj = probe_fixture(dir, [:runtime_tools], expr)
    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)

    mfas = traced |> probes() |> Enum.map(& &1["mfa"]) |> Enum.uniq() |> Enum.sort()
    assert ["code:ensure_loaded/1", "code:get_object_code/1", "code:which/1"] -- mfas == []
  end

  # Whether a module is loaded now is no question of the code path: under
  # the trace the answer is `true`, untraced `false`, listed or not.
  test "a loaded-module probe is not judged even with its application listed",
       %{tmp_dir: dir} do
    proj = probe_fixture(dir, [:runtime_tools], "function_exported?(:dbg, :p, 2)")
    {untraced, host, traced} = both(proj)
    refute host == untraced

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    assert Enum.any?(
             obs["problems"],
             &(&1 =~ "compile-time probe of a module the trace loaded: dbg (runtime_tools)")
           ),
           inspect(obs["problems"])
  end

  test "an is_loaded probe of httpc at compile time is not judged", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], ":code.is_loaded(:httpc) != false")
    {untraced, host, traced} = both(proj)
    refute host == untraced

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    assert Enum.any?(
             obs["problems"],
             &(&1 =~ "compile-time probe of a module the trace loaded: httpc (inets)")
           ),
           inspect(obs["problems"])
  end

  # The common case among published packages: `:json` is in stdlib, on
  # every path, so the answer is the same traced or not.
  test "a json probe in mix.exs and in a module body passes", %{tmp_dir: dir} do
    expr = "{Code.ensure_loaded?(:json), is_list(:code.which(:json))}"

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          mix_exs: TracerFixtures.mix_exs("fx_probe", ", json: Code.ensure_loaded?(:json)"),
          files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", expr)}
        }
      })

    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert Enum.any?(probes(traced), &(&1["arg"]["module"] == "json"))
  end

  # Mix loads these itself before it evaluates a dependency's mix.exs or
  # compiles anything, so the tracer does not count them as its own
  # (`:ncc_tracer.loaded_by_mix/0`): every kind of probe of them, from a
  # mix.exs (its description lands in the .app) and from a module body,
  # answers the same traced and untraced. (code:module_status/1 also reads
  # the code path, a host read of its own.)
  test "a probe of a module Mix loads anyway answers the same traced", %{tmp_dir: dir} do
    mods = :ncc_tracer.loaded_by_mix()
    assert mods != []

    expr =
      "for m <- #{inspect(mods)}, do: {:erlang.module_loaded(m), :code.is_loaded(m) != false, " <>
        "function_exported?(m, :module_info, 0), Code.ensure_loaded?(m)}"

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          mix_exs: TracerFixtures.mix_exs("fx_probe", ", description: inspect(#{expr})"),
          files: %{"lib/fx_probe.ex" => TracerFixtures.attr_module("FxProbe", expr)}
        }
      })

    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
    for m <- mods, do: refute(Map.has_key?(traced.report.start["preloaded"], to_string(m)))
  end

  test "a package that calls httpc only at runtime passes", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              "defmodule FxProbe do\n  def get(url), do: :httpc.request(url)\nend\n"
          }
        }
      })

    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
  end

  # The type checker looks :httpc up while it checks a nested compile the
  # package starts, and what it found reaches the package: untraced,
  # inets is not on the path and the checker warns; under the trace :httpc
  # is loaded and it does not. Its probes are judged.
  test "a nested compile's diagnostics about a tracer-loaded module are not judged",
       %{tmp_dir: dir} do
    inner = "defmodule FxProbe.Inner do\n  def get(u), do: :httpc.request(u)\nend\n"

    body = """
    defmodule FxProbe do
      {_, diagnostics} = Code.with_diagnostics(fn -> Code.compile_string(#{inspect(inner)}) end)
      @warned Enum.any?(diagnostics, &(&1.message =~ "httpc"))
      def warned?, do: @warned
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{files: %{"lib/fx_probe.ex" => body}}
      })

    {untraced, host, traced} = both(proj)
    refute host == untraced

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    assert Enum.any?(
             obs["problems"],
             &(&1 =~ "compile-time probe of a module the trace loaded: httpc (inets)")
           ),
           inspect(obs["problems"])
  end

  test "listing the loaded modules at compile time is not judged", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], "length(:code.all_loaded()) > 0")
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    assert "compile-time list of the loaded modules: code:all_loaded/0" in obs["problems"]
  end

  # Untraced, :ssl is not on the path of a package that does not list it,
  # and the compile fails (undef); under the trace it is loaded.
  test "a compile-time call into a module the trace loaded is not judged", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], ":ssl.format_error(:closed)")

    {out, status} =
      System.cmd("mix", ["compile"],
        cd: proj,
        env: TracerFixtures.env(proj),
        stderr_to_stdout: true
      )

    assert status != 0 and out =~ "undefined", out
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_probe"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    assert %{status: :skip, reason: "portability could not be judged", observations: obs} =
             TracerFixtures.judge(proj, "fx_probe", traced)

    assert "compile-time call into a module the trace loaded: ssl:format_error/1 (ssl)" in obs[
             "problems"
           ]
  end

  test "a compile-time call into an application the package lists passes", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [:ssl], ":ssl.format_error(:closed)")
    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert Enum.any?(traced.report.events, &(&1["channel"] == "app_call"))
  end

  test "a call into ssl only at runtime passes", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(dir, ["fx_probe"], %{
        "fx_probe" => %{
          files: %{
            "lib/fx_probe.ex" =>
              "defmodule FxProbe do\n  def v, do: :ssl.format_error(:closed)\nend\n"
          }
        }
      })

    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
  end

  # Marking a window refuses nothing by itself.
  test "a compile-time eval with no checker probe passes", %{tmp_dir: dir} do
    proj = probe_fixture(dir, [], ~S{elem(Code.eval_string("1 + 1"), 0)})
    {untraced, host, traced} = both(proj)
    assert BuildIdentity.differences(host, untraced) == []
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_probe", traced)
    assert Enum.any?(traced.report.events, &(&1["channel"] == "nested_compile"))
  end

  # A nested defmodule is type-checked inside its parent's module body, so
  # the checker's lookup of :httpc is a user-extent event in fx_top's
  # window. fx_dep marked its own window with an eval; fx_top's is not
  # marked, and its checker probes are dropped.
  test "a nested compile in one window leaves another window's checker probes dropped",
       %{tmp_dir: dir} do
    top = """
    defmodule FxTop do
      defmodule Inner do
        def get(u), do: :httpc.request(u)
      end

      def dep, do: FxDep.x()
    end
    """

    proj =
      TracerFixtures.project(dir, ["fx_top"], %{
        "fx_top" => %{deps: ["fx_dep"], files: %{"lib/fx_top.ex" => top}},
        "fx_dep" =>
          TracerFixtures.lib(
            "fx_dep",
            TracerFixtures.attr_module("FxDep", ~S{elem(Code.eval_string("1 + 1"), 0)})
          )
      })

    plain_compile(proj)
    untraced = published(proj)
    File.rm_rf!(Path.join(proj, "_build"))
    traced = TracerFixtures.trace(proj, ["fx_top"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log
    assert BuildIdentity.differences(published(proj), untraced) == []

    ctx = NccWorker.Portability.Context.build(proj, "fx_top", traced.report, [], releases: %{})
    assert Map.has_key?(ctx.nested, "fx_dep")
    refute Map.has_key?(ctx.nested, "fx_top")

    checker =
      for %{"arg" => %{"module" => "httpc", "checker" => true}} = e <- traced.report.events,
          NccWorker.Portability.Context.owner(ctx, e) == "fx_top",
          do: e

    assert checker != [], inspect(probes(traced), pretty: true)
    assert %{status: :pass} = TracerFixtures.judge(proj, "fx_top", traced)
  end
end
