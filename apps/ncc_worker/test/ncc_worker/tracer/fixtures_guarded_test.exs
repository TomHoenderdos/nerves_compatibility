defmodule NccWorker.Tracer.FixturesGuardedTest do
  # Starts real `elixir` and `mix` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.{Portability, TracerFixtures}

  @moduletag :tmp_dir
  @moduletag timeout: 300_000

  @cnj "portability could not be judged"

  # Coverage drop 2026-11-22, F4, and S9 fix round 1: websock_adapter's
  # `if Code.ensure_loaded?(:cowboy_websocket) do defmodule
  # WebSockAdapter.CowboyAdapter ... end`, as 0.7.2 ships it (the reviewed
  # entry keys on the file, the probe and the locked release). The builder
  # has no cowboy, so the module is not built and websock_adapter's own
  # build refuses. A dependent's waiver is proved by building it again with
  # the guarded package present (`NccWorker.Portability.GuardedProof`):
  # here `fx_cowboy`, a path dependency that defines `cowboy_websocket`,
  # in place of Hex's cowboy. The dependent passes only when its app is the
  # same in both builds.
  @adapter """
  if Code.ensure_loaded?(:cowboy_websocket) do
    defmodule WebSockAdapter.CowboyAdapter do
      @moduledoc false
      def init(req, state), do: {:cowboy_websocket, req, state}
    end
  end
  """

  # As 0.5.0 to 0.7.2 ship it (review N4): `upgrade/4` returns what
  # `Plug.Conn.upgrade_adapter/3` returns, so the guarded atom is in no
  # public return type of `WebSockAdapter`.
  @main """
  defmodule WebSockAdapter do
    def upgrade(websock, state), do: deliver(tuple_for(websock, state))
    defp tuple_for(websock, state), do: {WebSockAdapter.CowboyAdapter, {websock, state}, %{}}
    defp deliver(tuple), do: :persistent_term.put(:fx_upgrade, tuple)
  end
  """

  @refusal "compile-time probe of a dependency outside the closure: cowboy_websocket via " <>
             "Code.ensure_loaded?/1"

  # S10: what the builder answered "absent" is a `probe` compile input,
  # which client 0.10 checks against the user's project. A waived probe
  # needs none; one whose waiver the proof refuses, or that no waiver
  # covers, passes with it.
  @cowboy_input %{
    "kind" => "probe",
    "of" => "module",
    "name" => "cowboy_websocket",
    "answer" => "absent",
    "definers" => []
  }
  @poison_input %{
    "kind" => "probe",
    "of" => "module",
    "name" => "Elixir.Poison",
    "answer" => "absent",
    "definers" => []
  }

  defp probe_inputs(verdict),
    do: Enum.filter(verdict.compile_inputs || [], &(&1["kind"] == "probe"))

  @cowboy %{
    files: %{
      "src/cowboy_websocket.erl" =>
        "-module(cowboy_websocket).\n-export([upgrade/0]).\nupgrade() -> ok.\n"
    }
  }

  @present %{
    "websock_adapter:cowboy_adapter" => %{
      deps: [~s({:fx_cowboy, path: "deps/fx_cowboy"})],
      first: ["fx_cowboy"]
    },
    "jose:poison" => %{
      deps: [~s({:fx_poison, path: "deps/fx_poison"})],
      first: ["fx_poison"]
    }
  }

  # jose 1.11.x's `lib/jose/poison.ex` shape, and a stand-in for poison.
  @jose %{
    files: %{
      "lib/jose.ex" => "defmodule JOSE do\n  def f, do: :ok\nend\n",
      "lib/jose/poison.ex" => """
      if Code.ensure_loaded?(Poison) do
        defmodule JOSE.Poison do
          def lexical_encode!(v), do: v
        end
      end
      """
    }
  }

  @poison %{files: %{"lib/poison.ex" => "defmodule Poison do\n  def encode!(v), do: v\nend\n"}}

  defp project(dir, dep_body, extra \\ %{}) do
    TracerFixtures.project(
      dir,
      ["fx_dep"],
      Map.merge(
        %{
          "websock_adapter" => %{
            files: %{
              "lib/websock_adapter.ex" => @main,
              "lib/websock_adapter/cowboy_adapter.ex" => @adapter
            }
          },
          "fx_dep" => %{
            deps: ["websock_adapter"],
            files: %{"lib/fx_dep.ex" => dep_body}
          },
          "fx_cowboy" => @cowboy
        },
        extra
      )
    )
  end

  defp hex(dir) do
    home = Path.join(dir, "hex")

    {app, release} =
      TracerFixtures.hex_release(home, "websock_adapter", ["lib"], %{}, [{"version", "0.7.2"}])

    {jose, jose_release} =
      TracerFixtures.hex_release(home, "jose", ["lib"], %{}, [{"version", "1.11.13"}])

    [releases: %{app => release, jose => jose_release}, hex_home: home]
  end

  # The traced host compile and its judgement, the proof build included.
  defp run(dir, proj, package, extra \\ []) do
    # `extra` first: a keyword's first value is the one read.
    Portability.run(
      proj,
      package,
      extra ++
        [
          env: TracerFixtures.env(proj),
          trace_dir: Path.join(dir, "trace"),
          log_file: Path.join(dir, "trace.log"),
          timeout_ms: 240_000,
          mode: :host,
          guarded_present: @present
        ] ++ hex(dir)
    )
  end

  defp app_files(proj, app) do
    lib = Path.join([proj, "_build", "host", "lib", app])

    for path <- Path.wildcard(Path.join(lib, "{ebin,priv}/**")),
        File.regular?(path),
        into: %{},
        do: {Path.relative_to(path, lib), File.read!(path)}
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

  @dependent """
  defmodule FxDep do
    def connect(websock, state), do: WebSockAdapter.upgrade(websock, state)
  end
  """

  test "a dependent that only calls the prober passes once the proof build shows the same app",
       %{tmp_dir: dir} do
    proj = project(Path.join(dir, "w"), @dependent)
    verdict = run(dir, proj, "fx_dep")
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert verdict.observations["guarded_taint"] == [
             %{
               "app" => "websock_adapter",
               "entries" => ["websock_adapter:cowboy_adapter"],
               "reasons" => [@refusal]
             }
           ]

    assert %{"result" => "same", "present" => ["fx_cowboy"]} =
             verdict.observations["trace_stats"]["guarded_proof"]

    refute Portability.GuardedProof.hold_problem() in verdict.observations["problems"]
    # Waived: no probe input.
    assert probe_inputs(verdict) == []

    # The first build is back where it was, without the guarded module, and
    # the proof's dirs are gone.
    refute Map.has_key?(
             app_files(proj, "websock_adapter"),
             "ebin/Elixir.WebSockAdapter.CowboyAdapter.beam"
           )

    assert Map.has_key?(app_files(proj, "fx_dep"), "ebin/Elixir.FxDep.beam")
    refute File.exists?(proj <> ".ncc-guarded-first")
    refute File.exists?(Path.join(dir, "trace-guarded"))
  end

  test "judged alone, a waived pass waits for its proof; a firmware target is never waived",
       %{tmp_dir: dir} do
    proj = project(dir, @dependent)
    traced = TracerFixtures.trace(proj, ["fx_dep"], mode: :host)
    assert {:ok, 0} = traced.result, traced.log

    verdict = TracerFixtures.judge(proj, "fx_dep", traced, [], hex(dir))
    assert %{status: :skip, reason: @cnj} = verdict
    assert Portability.GuardedProof.hold_problem() in verdict.observations["problems"]
    assert [%{"app" => "websock_adapter"}] = verdict.observations["guarded_taint"]

    firmware = TracerFixtures.judge(proj, "fx_dep", traced, [], hex(dir) ++ [target: "rpi4"])
    assert %{status: :skip, reason: @refusal} = firmware
  end

  # The prober's own build is never waived (F4); S10 records its probe.
  test "the prober's own build passes with its probe input", %{tmp_dir: dir} do
    proj = project(dir, @dependent)
    verdict = run(dir, proj, "websock_adapter")
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
    assert probe_inputs(verdict) == [@cowboy_input]
    assert verdict.observations["guarded_taint"] == []
  end

  # The review's counter-examples (S9 review B1, B2): both pass every static
  # condition, and the proof build refuses them.
  for {name, body, differs} <- [
        # B1: a call through a value of the guarded atom's type. The type
        # checker reads the guarded module's signature, untraced, and the
        # dependent's `ExCk` differs.
        {"calls through a value of the guarded atom's type",
         """
         defmodule FxDep do
           def connect(req, state) do
             mod = WebSockAdapter.CowboyAdapter
             mod.init(req, state)
           end
         end
         """, "ExCk differs"},
        # B2: a read of the prober's Mix manifest, under its build dir but
        # not its ebin: it lists the guarded module where it was built.
        {"reads the prober's Mix manifest at compile time",
         """
         defmodule FxDep do
           @x "../../_build/host/lib/websock_adapter/.mix/compile.elixir"
              |> File.read!()
              |> :erlang.binary_to_term()
              |> elem(1)
              |> Map.has_key?(WebSockAdapter.CowboyAdapter)
           def x, do: @x
         end
         """, "differs"}
      ] do
    @body body
    @differs differs
    # S10: the proof refuses the waiver, and the build passes with the probe
    # input instead: client 0.10 takes it only where cowboy is absent.
    test "a dependent that #{name} is not waived by the proof build", %{tmp_dir: dir} do
      proj = project(Path.join(dir, "w"), @body)
      verdict = run(dir, proj, "fx_dep")
      assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
      assert probe_inputs(verdict) == [@cowboy_input]

      assert %{"result" => "input", "why" => why} =
               verdict.observations["trace_stats"]["guarded_proof"]

      assert why =~ "the package builds otherwise with the guarded packages present", why
      assert why =~ @differs, why
      assert verdict.observations["taint"] == %{}
      assert verdict.observations["trace_stats"]["transient"] == false

      # The first build is back.
      assert Map.has_key?(app_files(proj, "fx_dep"), "ebin/Elixir.FxDep.beam")
      refute File.exists?(proj <> ".ncc-guarded-first")
    end
  end

  # S9 re-review R1-1: a user's world is any presence vector over the
  # waived entries. The dependent below reads two probers' manifests and
  # compares them: `true` with neither guarded module and with both, `false`
  # for a user with cowboy and without poison (or the reverse). A proof of
  # the all-present world alone passed it; one world per non-empty subset
  # refuses it, at the first one-package world.
  test "a dependent of two probers whose beams depend on the pair refuses in a subset world",
       %{tmp_dir: dir} do
    body = """
    defmodule FxDep do
      m = fn app, mod ->
        "../../_build/host/lib/\#{app}/.mix/compile.elixir"
        |> File.read!()
        |> :erlang.binary_to_term()
        |> elem(1)
        |> Map.has_key?(mod)
      end

      @x m.(:websock_adapter, WebSockAdapter.CowboyAdapter) == m.(:jose, JOSE.Poison)
      def x, do: @x
    end
    """

    proj =
      TracerFixtures.project(Path.join(dir, "w"), ["fx_dep"], %{
        "websock_adapter" => %{
          files: %{
            "lib/websock_adapter.ex" => @main,
            "lib/websock_adapter/cowboy_adapter.ex" => @adapter
          }
        },
        "jose" => @jose,
        "fx_dep" => %{deps: ["websock_adapter", "jose"], files: %{"lib/fx_dep.ex" => body}},
        "fx_cowboy" => @cowboy,
        "fx_poison" => @poison
      })

    verdict = run(dir, proj, "fx_dep")
    # S10: the waiver is refused, and both probes are inputs.
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
    assert probe_inputs(verdict) == [@poison_input, @cowboy_input]

    assert [%{"app" => "jose"}, %{"app" => "websock_adapter"}] =
             verdict.observations["guarded_taint"]

    assert %{"result" => "input", "why" => why} =
             verdict.observations["trace_stats"]["guarded_proof"]

    # The first world, jose's guarded package alone, already differs.
    assert why =~ "with fx_poison present: the package builds otherwise", why
    refute File.exists?(proj <> ".ncc-guarded-first")
    assert Map.has_key?(app_files(proj, "fx_dep"), "ebin/Elixir.FxDep.beam")
  end

  # Two probers whose guarded modules a dependent cannot see: every one of
  # the three worlds is the first build.
  test "a dependent of two probers passes once all three worlds are the same", %{tmp_dir: dir} do
    proj =
      TracerFixtures.project(Path.join(dir, "w"), ["fx_dep"], %{
        "websock_adapter" => %{
          files: %{
            "lib/websock_adapter.ex" => @main,
            "lib/websock_adapter/cowboy_adapter.ex" => @adapter
          }
        },
        "jose" => @jose,
        "fx_dep" => %{
          deps: ["websock_adapter", "jose"],
          files: %{
            "lib/fx_dep.ex" =>
              "defmodule FxDep do\n  def f(w, s), do: {WebSockAdapter.upgrade(w, s), JOSE.f()}\nend\n"
          }
        },
        "fx_cowboy" => @cowboy,
        "fx_poison" => @poison
      })

    verdict = run(dir, proj, "fx_dep")
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))

    assert %{"result" => "same", "worlds" => 3, "present" => present} =
             verdict.observations["trace_stats"]["guarded_proof"]

    assert Enum.sort(present) == ["fx_cowboy", "fx_poison"]
    assert probe_inputs(verdict) == []
  end

  # S9 re-review R1-3: the project dir reached through a link (macOS's
  # `/var`, which is `/private/var`), the build dir named by its real path.
  # Both are resolved before they are compared, and the real dir is what
  # moves aside.
  test "a project dir reached through a link is resolved before the proof", %{tmp_dir: dir} do
    real = project(Path.join(dir, "w"), @dependent)
    link = Path.join(dir, "link")
    File.ln_s!(Path.dirname(real), link)
    proj = Path.join(link, "proj")

    env =
      TracerFixtures.env(proj)
      |> List.keystore(
        "MIX_BUILD_PATH",
        0,
        {"MIX_BUILD_PATH", Path.join([real, "_build", "host"])}
      )

    verdict = run(dir, proj, "fx_dep", env: env)
    assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
    assert %{"result" => "same"} = verdict.observations["trace_stats"]["guarded_proof"]
    assert File.lstat!(link).type == :symlink
    assert Map.has_key?(app_files(real, "fx_dep"), "ebin/Elixir.FxDep.beam")
    refute File.exists?(real <> ".ncc-guarded-first")
  end

  # The proof build refuses when it cannot be made, or proves nothing. S10:
  # the first build is back untouched, so it passes with the probe input.
  @lock ~s(%{"jason": {:hex, :jason, "1.4.4", "inner", [:mix], [], "hexpm", "outer"}}\n)
  @moved ~s(%{"jason": {:hex, :jason, "1.4.5", "inner", [:mix], [], "hexpm", "other"}}\n)

  for {name, extra, why} <- [
        {"deps.get fails", [guarded_deps_get: &__MODULE__.failing_deps_get/2],
         "the guarded packages cannot be added: deps.get failed"},
        {"the guarded package moves a locked release",
         [guarded_deps_get: &__MODULE__.moving_deps_get/2],
         "the guarded packages cannot be added: jason would be locked otherwise"},
        {"the build with the guarded package fails",
         [
           guarded_present: %{
             "websock_adapter:cowboy_adapter" => %{
               deps: [~s({:fx_broken, path: "deps/fx_broken"})],
               first: ["fx_broken"]
             }
           }
         ], "the build with the guarded packages did not finish"},
        {"the guarded modules are not built",
         [
           guarded_present: %{
             "websock_adapter:cowboy_adapter" => %{
               deps: [~s({:fx_other, path: "deps/fx_other"})],
               first: ["fx_other"]
             }
           }
         ], "the guarded modules were not built with their package present: websock_adapter"}
      ] do
    @extra extra
    @why why
    test "#{name}: the probe input instead", %{tmp_dir: dir} do
      proj =
        project(Path.join(dir, "w"), @dependent, %{
          "fx_broken" =>
            TracerFixtures.lib("fx_broken", "defmodule FxBroken do\n  def f, do: \nend\n"),
          "fx_other" => TracerFixtures.lib("fx_other", "defmodule FxOther do\nend\n")
        })

      File.write!(Path.join(proj, "mix.lock"), @lock)
      verdict = run(dir, proj, "fx_dep", @extra)
      assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
      assert probe_inputs(verdict) == [@cowboy_input]

      assert %{"result" => "input", "why" => why} =
               verdict.observations["trace_stats"]["guarded_proof"]

      assert why =~ @why, why

      # The first project is back as it was, its lock included.
      assert Map.has_key?(app_files(proj, "fx_dep"), "ebin/Elixir.FxDep.beam")
      assert File.read!(Path.join(proj, "mix.lock")) == @lock
      refute File.exists?(proj <> ".ncc-guarded-first")
    end
  end

  def failing_deps_get(_dir, _env), do: {:error, {:deps_get_failed, "no route to repo.hex.pm"}}

  def moving_deps_get(dir, env) do
    :ok = NccWorker.Project.run_deps_get(dir, env)
    File.write!(Path.join(dir, "mix.lock"), @moved)
  end

  # The static conditions stay a pre-filter: a dependent that fails one
  # gets no waiver and no proof build. S10: websock_adapter's probe is the
  # dependent's input, and the dependent's own probe of the guarded module
  # (nothing in the build defines it) is one too.
  @guarded_input %{
    "kind" => "probe",
    "of" => "module",
    "name" => "Elixir.WebSockAdapter.CowboyAdapter",
    "answer" => "absent",
    "definers" => []
  }

  for {name, body, inputs} <- [
        {"calls the guarded module",
         """
         defmodule FxDep do
           @compile {:no_warn_undefined, WebSockAdapter.CowboyAdapter}
           def init(req, state), do: WebSockAdapter.CowboyAdapter.init(req, state)
         end
         """, [@cowboy_input]},
        {"probes the guarded module at compile time",
         TracerFixtures.attr_module("FxDep", "Code.ensure_loaded?(WebSockAdapter.CowboyAdapter)"),
         [@guarded_input, @cowboy_input]},
        {"lists the prober's ebin at compile time",
         TracerFixtures.attr_module(
           "FxDep",
           ~S{"../../_build/host/lib/websock_adapter/ebin" |> File.ls!() |> Enum.sort()}
         ), [@cowboy_input]},
        {"calls the guarded module at compile time",
         TracerFixtures.attr_module(
           "FxDep",
           "(try do WebSockAdapter.CowboyAdapter.init(1, 2) rescue _ -> :none end)"
         ), [@guarded_input, @cowboy_input]}
      ] do
    @body body
    @inputs inputs
    test "a dependent that #{name} passes with probe inputs and no proof build",
         %{tmp_dir: dir} do
      proj = project(dir, @body)
      verdict = run(dir, proj, "fx_dep")
      assert %{status: :pass} = verdict, inspect(Map.take(verdict, [:reason, :observations]))
      assert probe_inputs(verdict) == @inputs
      assert verdict.observations["guarded_taint"] == []
      refute Map.has_key?(verdict.observations["trace_stats"], "guarded_proof")
    end
  end
end
