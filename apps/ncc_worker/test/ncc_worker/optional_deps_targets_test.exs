defmodule NccWorker.OptionalDepsTargetsTest do
  # Every runner that would reach Hex or run `mix` is a stub: the files the
  # pass moves aside, compiles into and puts back are real, so what a target
  # publishes is checked byte for byte. The real resolution and compile are
  # covered by the Docker integration test.
  use ExUnit.Case, async: true

  alias NccWorker.OptionalDepsTargets

  @mix_exs """
  defmodule Foo.MixProject do
    use Mix.Project

    def project do
      [deps: deps()]
    end

    defp deps do
      [
        {:nerves, "~> 1.13", runtime: false},
        {:pkg, "1.0.0"}
      ]
    end
  end
  """

  # The status build's lock: pkg depends on telemetry, its optional jason is
  # unresolved.
  @lock """
  %{
    "pkg": {:hex, :pkg, "1.0.0", "i-pkg", [:mix], [{:telemetry, "~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}], "hexpm", "o-pkg"},
    "telemetry": {:hex, :telemetry, "1.3.0", "i-tel", [:rebar3], [], "hexpm", "o-tel"},
  }
  """

  # The lock after the pass's deps.get resolved jason.
  @lock_with_jason """
  %{
    "jason": {:hex, :jason, "1.4.4", "i-jason", [:mix], [], "hexpm", "o-jason"},
    "pkg": {:hex, :pkg, "1.0.0", "i-pkg", [:mix], [{:telemetry, "~> 1.0", [hex: :telemetry, repo: "hexpm", optional: false]}, {:jason, "~> 1.0", [hex: :jason, repo: "hexpm", optional: true]}], "hexpm", "o-pkg"},
    "telemetry": {:hex, :telemetry, "1.3.0", "i-tel", [:rebar3], [], "hexpm", "o-tel"},
  }
  """

  @jason [%{app: "jason", package: "jason", requirement: "~> 1.0"}]

  @targets ~w(rpi4 bbb)

  setup do
    dir = Path.join(System.tmp_dir!(), "opt_targets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join(dir, "mix.exs"), @mix_exs)
    File.write!(Path.join(dir, "mix.lock"), @lock)

    for target <- @targets do
      write!(beam(dir, target), "first-#{target}")
      write!(Path.join([dir, "_build", target, "lib", "other", "ebin", "other.beam"]), "dep")
    end

    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp beam(dir, target), do: Path.join([dir, "_build", target, "lib", "pkg", "ebin", "pkg.beam"])

  defp aside(dir, target), do: Path.join([dir, "_build", target, "lib", ".pkg.status-build"])

  defp log(dir, target), do: Path.join([dir, "logs", "nerves_system_#{target}.log"])

  defp passing(target) do
    %{
      status: :pass,
      duration_sec: 10.0,
      phase_timings: %{deps_sec: 1.0},
      firmware_size_bytes: 1234,
      log_tail: "tail-#{target}",
      system_version: "1.0.0",
      compile_env: [%{"first" => target}],
      beam_scan: %{"first" => target},
      dependency_scans: %{"other@1" => %{}},
      cache_candidates: [%{"key" => "k-#{target}"}],
      error: nil
    }
  end

  defp params(dir, overrides \\ %{}) do
    systems = %{
      "nerves_system_rpi4" => passing("rpi4"),
      "nerves_system_bbb" => passing("bbb"),
      "nerves_system_x86_64" => %{
        status: :fail,
        duration_sec: 1.0,
        firmware_size_bytes: nil,
        log_tail: "boom",
        beam_scan: nil,
        dependency_scans: nil,
        error: "mix command exited with code 1"
      }
    }

    targets =
      for target <- ["rpi4", "bbb", "x86_64"] do
        env = [
          {"MIX_TARGET", target},
          {"MIX_BUILD_PATH", Path.join([dir, "_build", target])},
          {"MIX_DEPS_PATH", Path.join(dir, "deps_#{target}")},
          {"MIX_ENV", "prod"}
        ]

        {"nerves_system_#{target}", %{env: env, log_file: log(dir, target)}}
      end

    Map.merge(
      %{
        project_dir: dir,
        package: "pkg",
        deps: @jason,
        systems: systems,
        targets: targets,
        timeout_sec: 600,
        concurrency: 2
      },
      overrides
    )
  end

  defp target_of(env), do: env |> List.keyfind("MIX_TARGET", 0) |> elem(1)

  defp build_path_of(env), do: env |> List.keyfind("MIX_BUILD_PATH", 0) |> elem(1)

  # deps.get resolves jason into the root lock, as the real one does.
  defp deps_get_ok(dir) do
    fn _project_dir, _env, _log_file, _timeout ->
      File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
      :ok
    end
  end

  # A compile that writes the target's new build, and one that fails partway,
  # leaving half a lib dir behind.
  defp compile_by_target(dir, outcomes) do
    fn _project_dir, env, _log_file, _timeout ->
      target = target_of(env)

      case Map.fetch!(outcomes, target) do
        :ok ->
          write!(beam(dir, target), "second-#{target}")
          :ok

        {:error, _} = error ->
          write!(beam(dir, target), "half-#{target}")
          write!(Path.join([dir, "_build", target, "lib", "pkg", "ebin", "x.beam"]), "half")
          error
      end
    end
  end

  defp runners(dir, overrides) do
    Map.merge(
      %{
        deps_get: deps_get_ok(dir),
        lock_policy: fn _ -> :ok end,
        compile: compile_by_target(dir, %{"rpi4" => :ok, "bbb" => :ok}),
        scan: fn build_path, "pkg" -> %{"rescanned" => Path.basename(build_path)} end,
        compile_env: fn build_path, "pkg" -> [%{"second" => Path.basename(build_path)}] end,
        reap: fn _build_path -> :ok end
      },
      overrides
    )
  end

  defp never("inject"), do: fn _, _ -> flunk("inject ran") end
  defp never("deps.get"), do: fn _, _, _, _ -> flunk("deps.get ran") end
  defp never("compile"), do: fn _, _, _, _ -> flunk("compile ran") end

  describe "run/2 with one target kept and one dropped" do
    setup %{dir: dir} do
      runners =
        runners(dir, %{
          compile:
            compile_by_target(dir, %{
              "rpi4" => :ok,
              "bbb" => {:error, "mix command exited with code 1"}
            })
        })

      assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners)
      {:ok, out: out}
    end

    test "the kept target publishes the new build with its own lock", %{dir: dir, out: out} do
      rpi4 = out.systems["nerves_system_rpi4"]

      assert File.read!(beam(dir, "rpi4")) == "second-rpi4"
      refute File.exists?(aside(dir, "rpi4"))
      assert rpi4.beam_scan == %{"rescanned" => "rpi4"}
      assert rpi4.compile_env == [%{"second" => "rpi4"}]
      assert rpi4.optional_deps == %{added: ["jason"], dropped: [], reason: nil}

      assert rpi4.deps_lock == %{
               "jason" => %{"version" => "1.4.4", "checksum" => "o-jason"},
               "telemetry" => %{"version" => "1.3.0", "checksum" => "o-tel"}
             }
    end

    test "the dropped target publishes exactly its first build", %{dir: dir, out: out} do
      bbb = out.systems["nerves_system_bbb"]

      assert File.read!(beam(dir, "bbb")) == "first-bbb"
      refute File.exists?(Path.join([dir, "_build", "bbb", "lib", "pkg", "ebin", "x.beam"]))
      refute File.exists?(aside(dir, "bbb"))
      assert bbb.beam_scan == %{"first" => "bbb"}
      assert bbb.compile_env == [%{"first" => "bbb"}]
      refute Map.has_key?(bbb, :deps_lock)

      assert bbb.optional_deps == %{
               added: [],
               dropped: ["jason"],
               reason: "target_compile_failed"
             }
    end

    test "nothing the first build decided changes", %{out: out} do
      for target <- @targets do
        before = passing(target)
        after_pass = out.systems["nerves_system_#{target}"]

        for key <- [
              :status,
              :firmware_size_bytes,
              :log_tail,
              :error,
              :dependency_scans,
              :cache_candidates,
              :duration_sec,
              :phase_timings,
              :system_version
            ],
            do: assert(Map.fetch!(after_pass, key) == Map.fetch!(before, key))
      end
    end

    test "a system that was not passing gets no optional_deps", %{out: out} do
      x86 = out.systems["nerves_system_x86_64"]

      refute Map.has_key?(x86, :optional_deps)
      refute Map.has_key?(x86, :deps_lock)
    end

    test "mix.exs and mix.lock are back as the status build left them", %{dir: dir} do
      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
      assert File.read!(Path.join(dir, "mix.lock")) == @lock
    end

    test "the run-level lock is the status build's, read before the pass", %{out: out} do
      assert out.deps_lock == %{"telemetry" => %{"version" => "1.3.0", "checksum" => "o-tel"}}
      assert out.package_checksum == "o-pkg"
    end

    test "the run-level summary names what was kept anywhere", %{out: out} do
      assert out.optional_deps == %{added: ["jason"], dropped: [], reason: nil}
    end

    test "each target's log gets a header and the outcome", %{dir: dir} do
      for target <- @targets,
          do: assert(File.read!(log(dir, target)) =~ "==> optional dependencies: jason")

      assert File.read!(log(dir, "bbb")) =~ "target_compile_failed"
      refute File.exists?(log(dir, "x86_64"))
    end
  end

  test "the first build is moved aside while the pass compiles", %{dir: dir} do
    test_pid = self()

    compile = fn _project_dir, env, _log_file, _timeout ->
      target = target_of(env)
      lib = Path.join([build_path_of(env), "lib"])

      send(
        test_pid,
        {:during, target, File.exists?(Path.join(lib, "pkg")),
         File.read!(Path.join([lib, ".pkg.status-build", "ebin", "pkg.beam"])),
         File.read!(Path.join(dir, "mix.exs"))}
      )

      write!(beam(dir, target), "second-#{target}")
      :ok
    end

    assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners(dir, %{compile: compile}))

    for target <- @targets do
      first = "first-#{target}"
      assert_received {:during, ^target, false, ^first, mix_exs}
      assert mix_exs =~ ~s[{:jason, "~> 1.0"},]
      assert File.read!(beam(dir, target)) == "second-#{target}"
    end

    assert out.optional_deps == %{added: ["jason"], dropped: [], reason: nil}
  end

  test "deps.get runs serially per target with that target's env", %{dir: dir} do
    test_pid = self()
    # 1: in flight now, 2: most ever in flight, 3: finished.
    counters = :counters.new(3, [])

    deps_get = fn _dir, env, log_file, _timeout ->
      :counters.add(counters, 1, 1)
      in_flight = :counters.get(counters, 1)
      if in_flight > :counters.get(counters, 2), do: :counters.put(counters, 2, in_flight)
      send(test_pid, {:deps_get, target_of(env), log_file})
      Process.sleep(20)
      File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
      :counters.sub(counters, 1, 1)
      :counters.add(counters, 3, 1)
      :ok
    end

    compile = fn _dir, env, _log, _timeout ->
      send(test_pid, {:compile_after, :counters.get(counters, 3)})
      write!(beam(dir, target_of(env)), "second")
      :ok
    end

    assert {:ok, _} =
             OptionalDepsTargets.run(
               params(dir),
               runners(dir, %{deps_get: deps_get, compile: compile})
             )

    assert :counters.get(counters, 2) == 1
    assert_received {:compile_after, 2}
    assert_received {:compile_after, 2}

    rpi4_log = log(dir, "rpi4")
    bbb_log = log(dir, "bbb")
    assert_received {:deps_get, "rpi4", ^rpi4_log}
    assert_received {:deps_get, "bbb", ^bbb_log}
    refute_received {:deps_get, "x86_64", _}
  end

  test "a failed deps.get or lock policy drops that target only", %{dir: dir} do
    deps_get = fn _dir, env, _log, _timeout ->
      case target_of(env) do
        "bbb" ->
          {:error, {:deps_get_failed, "exit code 1"}}

        _ ->
          File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
          :ok
      end
    end

    compile =
      compile_by_target(dir, %{"rpi4" => :ok, "bbb" => {:error, "must not compile"}})

    assert {:ok, out} =
             OptionalDepsTargets.run(
               params(dir),
               runners(dir, %{deps_get: deps_get, compile: compile})
             )

    assert out.systems["nerves_system_bbb"].optional_deps.reason == "deps_get_failed"
    assert File.read!(beam(dir, "bbb")) == "first-bbb"
    assert out.systems["nerves_system_rpi4"].optional_deps.added == ["jason"]

    policy = fn _dir -> {:error, :policy_violation} end

    File.write!(Path.join(dir, "mix.lock"), @lock)

    assert {:ok, out} =
             OptionalDepsTargets.run(params(dir), runners(dir, %{lock_policy: policy}))

    for target <- @targets do
      assert out.systems["nerves_system_#{target}"].optional_deps.reason ==
               "lock_policy_violation"
    end

    assert out.optional_deps == %{added: [], dropped: ["jason"], reason: "lock_policy_violation"}
  end

  test "a compile that runs out of time drops the target as timeout", %{dir: dir} do
    compile = compile_by_target(dir, %{"rpi4" => {:error, :timeout}, "bbb" => :ok})

    assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners(dir, %{compile: compile}))

    assert out.systems["nerves_system_rpi4"].optional_deps.reason == "timeout"
    assert File.read!(beam(dir, "rpi4")) == "first-rpi4"
  end

  test "when every target drops them, the summary takes the first target's reason",
       %{dir: dir} do
    compile =
      compile_by_target(dir, %{
        "rpi4" => {:error, :timeout},
        "bbb" => {:error, "mix command exited with code 1"}
      })

    assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners(dir, %{compile: compile}))

    assert out.optional_deps == %{added: [], dropped: ["jason"], reason: "timeout"}

    for target <- @targets do
      assert File.read!(beam(dir, target)) == "first-#{target}"
      refute Map.has_key?(out.systems["nerves_system_#{target}"], :deps_lock)
    end
  end

  test "a failed inject drops the pass for every target", %{dir: dir} do
    inject = fn dir, _deps ->
      File.write!(Path.join(dir, "mix.exs"), "half an edit")
      {:error, :no_deps_block}
    end

    assert {:ok, out} =
             OptionalDepsTargets.run(
               params(dir),
               runners(dir, %{
                 inject: inject,
                 deps_get: never("deps.get"),
                 compile: never("compile")
               })
             )

    for target <- @targets do
      assert out.systems["nerves_system_#{target}"].optional_deps.reason ==
               "mix_exs_edit_failed"

      assert File.read!(beam(dir, target)) == "first-#{target}"
    end

    assert out.optional_deps.reason == "mix_exs_edit_failed"
    assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
  end

  describe "no pass" do
    test "with nothing to add, the systems are untouched", %{dir: dir} do
      p = params(dir, %{deps: []})

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 p,
                 %{
                   deps_get: never("deps.get"),
                   compile: never("compile"),
                   inject: never("inject")
                 }
               )

      assert out.systems == p.systems
      assert out.optional_deps == %{added: [], dropped: [], reason: nil}
      assert out.deps_lock == %{"telemetry" => %{"version" => "1.3.0", "checksum" => "o-tel"}}
    end

    test "when the template declares them all already", %{dir: dir} do
      p = params(dir)

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 p,
                 %{
                   inject: fn _dir, _deps -> {:ok, []} end,
                   deps_get: never("deps.get"),
                   compile: never("compile")
                 }
               )

      assert out.systems == p.systems
      assert out.optional_deps == %{added: [], dropped: [], reason: nil}

      for target <- @targets, do: assert(File.read!(beam(dir, target)) == "first-#{target}")
    end

    test "when no target passed", %{dir: dir} do
      p = params(dir)

      systems =
        Map.new(p.systems, fn {name, sys} -> {name, %{sys | status: :fail}} end)

      p = %{p | systems: systems}

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 p,
                 %{
                   deps_get: never("deps.get"),
                   compile: never("compile"),
                   inject: never("inject")
                 }
               )

      assert out.systems == systems
      assert out.optional_deps == %{added: [], dropped: ["jason"], reason: "no_passing_target"}
      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
    end
  end

  describe "revert failure" do
    test "a first build that cannot be put back is an error", %{dir: dir} do
      rename = fn from, to ->
        if String.ends_with?(from, ".pkg.status-build"),
          do: {:error, :eio},
          else: File.rename(from, to)
      end

      compile = compile_by_target(dir, %{"rpi4" => :ok, "bbb" => {:error, "exit 1"}})

      assert {:error, {:optional_deps_revert_failed, _}} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{rename: rename, compile: compile})
               )

      # mix.exs and mix.lock are still put back.
      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
      assert File.read!(Path.join(dir, "mix.lock")) == @lock
    end

    test "a mix.exs or mix.lock that cannot be restored is an error", %{dir: dir} do
      assert {:error, {:optional_deps_revert_failed, :eacces}} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{restore: fn _snapshot -> {:error, :eacces} end})
               )
    end
  end

  describe "more drop paths" do
    test "an unreadable lock after deps.get drops every fetched target", %{dir: dir} do
      read_lock = fn project_dir, package ->
        if File.read!(Path.join(project_dir, "mix.lock")) == @lock_with_jason,
          do: nil,
          else: NccWorker.DepsLock.read(project_dir, package)
      end

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{read_lock: read_lock, compile: never("compile")})
               )

      for target <- @targets do
        assert out.systems["nerves_system_#{target}"].optional_deps.reason ==
                 "deps_lock_unreadable"

        assert File.read!(beam(dir, target)) == "first-#{target}"
      end

      assert out.deps_lock == %{"telemetry" => %{"version" => "1.3.0", "checksum" => "o-tel"}}
    end

    test "a move-aside that fails drops that target and the other still runs", %{dir: dir} do
      rename = fn from, to ->
        if String.ends_with?(from, "rpi4/lib/pkg"),
          do: {:error, :exdev},
          else: File.rename(from, to)
      end

      assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners(dir, %{rename: rename}))

      assert out.systems["nerves_system_rpi4"].optional_deps.reason == "stale_build_not_removed"
      assert File.read!(beam(dir, "rpi4")) == "first-rpi4"
      assert out.systems["nerves_system_bbb"].optional_deps.added == ["jason"]
      assert File.read!(beam(dir, "bbb")) == "second-bbb"
    end

    test "a compile, scan or compile_env that raises drops the target", %{dir: dir} do
      compile = fn _dir, env, _log, _timeout ->
        target = target_of(env)
        write!(beam(dir, target), "half-#{target}")
        if target == "rpi4", do: raise("compile blew up"), else: :ok
      end

      scan = fn build_path, _pkg ->
        if Path.basename(build_path) == "bbb", do: raise("scan blew up"), else: %{}
      end

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{compile: compile, scan: scan})
               )

      for target <- @targets do
        assert out.systems["nerves_system_#{target}"].optional_deps.reason ==
                 "target_compile_failed"

        assert File.read!(beam(dir, target)) == "first-#{target}"
      end
    end
  end

  describe "reaping a timed-out compile's writers" do
    test "runs before the first build goes back, for every dropped target", %{dir: dir} do
      test_pid = self()
      write!(beam(dir, "x86_64"), "first-x86_64")

      reap = fn build_path ->
        target = Path.basename(build_path)

        send(
          test_pid,
          {:reap, target, File.exists?(aside(dir, target)), File.read!(beam(dir, target))}
        )

        :ok
      end

      # rpi4 times out, bbb fails (an OOM-killed mix exits 137 the same way),
      # x86_64's runner raises after the compile started writing.
      compile = fn _dir, env, _log, _timeout ->
        target = target_of(env)
        write!(beam(dir, target), "half-#{target}")

        case target do
          "rpi4" -> {:error, :timeout}
          "bbb" -> {:error, "mix compile exited with code 137"}
          "x86_64" -> raise "runner blew up"
        end
      end

      p = params(dir)
      p = put_in(p.systems["nerves_system_x86_64"], passing("x86_64"))

      assert {:ok, out} =
               OptionalDepsTargets.run(p, runners(dir, %{reap: reap, compile: compile}))

      for target <- ~w(rpi4 bbb x86_64) do
        half = "half-#{target}"
        assert_received {:reap, ^target, true, ^half}
        assert File.read!(beam(dir, target)) == "first-#{target}"
      end

      assert out.systems["nerves_system_rpi4"].optional_deps.reason == "timeout"
      assert out.systems["nerves_system_bbb"].optional_deps.reason == "target_compile_failed"
      assert out.systems["nerves_system_x86_64"].optional_deps.reason == "target_compile_failed"
    end

    test "a kept target is not reaped", %{dir: dir} do
      test_pid = self()

      reap = fn build_path ->
        send(test_pid, {:reap, Path.basename(build_path)})
        :ok
      end

      assert {:ok, _} = OptionalDepsTargets.run(params(dir), runners(dir, %{reap: reap}))
      refute_received {:reap, _}
    end

    test "writers that survive are a revert failure, and the first build stays aside",
         %{dir: dir} do
      reap = fn _build_path -> {:error, {:writers_survived, ["4242"]}} end
      compile = compile_by_target(dir, %{"rpi4" => {:error, :timeout}, "bbb" => :ok})

      assert {:error, {:optional_deps_revert_failed, {:writers_survived, ["4242"]}}} =
               OptionalDepsTargets.run(params(dir), runners(dir, %{reap: reap, compile: compile}))

      assert File.read!(Path.join([aside(dir, "rpi4"), "ebin", "pkg.beam"])) == "first-rpi4"
      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
      assert File.read!(Path.join(dir, "mix.lock")) == @lock
    end

    test "reap_writers/1 kills a process carrying the build path", %{dir: dir} do
      build_path = Path.join([dir, "_build", "reap_me"])

      if File.dir?("/proc") do
        port =
          Port.open({:spawn_executable, System.find_executable("sleep")}, [
            :binary,
            args: ["30"],
            env: [{~c"MIX_BUILD_PATH", String.to_charlist(build_path)}]
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        assert :ok = OptionalDepsTargets.reap_writers(build_path)

        # Gone, or a zombie (its environ reads empty) until it is reaped.
        assert File.read("/proc/#{os_pid}/environ") in [{:error, :enoent}, {:ok, ""}]
      else
        assert :ok = OptionalDepsTargets.reap_writers(build_path)
      end
    end
  end

  describe "budgets" do
    test "each compile gets at most what is left of the pass's budget", %{dir: dir} do
      test_pid = self()

      compile = fn _dir, env, _log, timeout_sec ->
        send(test_pid, {:timeout, timeout_sec})
        write!(beam(dir, target_of(env)), "second")
        :ok
      end

      assert {:ok, _} =
               OptionalDepsTargets.run(
                 params(dir, %{budget_sec: 100}),
                 runners(dir, %{compile: compile, now: fn -> 5000 end})
               )

      assert_received {:timeout, 100}
      assert_received {:timeout, 100}
    end

    test "targets not started by the deadline keep their first build as timeout",
         %{dir: dir} do
      clock = :counters.new(1, [])
      test_pid = self()

      deps_get = fn _dir, env, _log, _timeout ->
        send(test_pid, {:deps_get, target_of(env)})
        File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
        # rpi4's deps.get uses up the whole budget.
        :counters.put(clock, 1, 200)
        :ok
      end

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 params(dir, %{budget_sec: 100}),
                 runners(dir, %{
                   deps_get: deps_get,
                   compile: never("compile"),
                   now: fn -> :counters.get(clock, 1) end
                 })
               )

      assert_received {:deps_get, "rpi4"}
      refute_received {:deps_get, "bbb"}

      for target <- @targets do
        assert out.systems["nerves_system_#{target}"].optional_deps.reason == "timeout"
        assert File.read!(beam(dir, target)) == "first-#{target}"
      end

      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
    end

    test "a run past 75 minutes does not start the pass", %{dir: dir} do
      p = params(dir, %{run_elapsed_sec: 75 * 60 + 1})

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 p,
                 %{
                   inject: never("inject"),
                   deps_get: never("deps.get"),
                   compile: never("compile")
                 }
               )

      for target <- @targets do
        sys = out.systems["nerves_system_#{target}"]

        assert sys.optional_deps == %{
                 added: [],
                 dropped: ["jason"],
                 reason: "run_budget_exhausted"
               }

        assert sys.beam_scan == %{"first" => target}
        assert File.read!(beam(dir, target)) == "first-#{target}"
        refute File.exists?(aside(dir, target))
      end

      refute Map.has_key?(out.systems["nerves_system_x86_64"], :optional_deps)
      assert out.optional_deps.reason == "run_budget_exhausted"
      assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
    end
  end

  describe "final review" do
    # Mix links `_build/<t>/lib/<pkg>/priv` to `deps_<t>/<pkg>/priv`, so a
    # pass that writes a NIF there would write into the first build too.
    test "a put-back first build keeps its own priv bytes behind a symlink", %{dir: dir} do
      src_priv = Path.join([dir, "deps_rpi4", "pkg", "priv"])
      nif = Path.join(src_priv, "pkg_nif.so")
      write!(nif, "first-nif")
      File.chmod!(nif, 0o755)
      lib_priv = Path.join([dir, "_build", "rpi4", "lib", "pkg", "priv"])
      File.ln_s!("../../../../deps_rpi4/pkg/priv", lib_priv)
      assert File.read!(Path.join(lib_priv, "pkg_nif.so")) == "first-nif"

      compile = fn _dir, env, _log, _timeout ->
        target = target_of(env)

        if target == "rpi4" do
          # Mix recreates the link in the new lib dir, the NIF build writes
          # through it, then the Elixir step fails.
          write!(beam(dir, "rpi4"), "half-rpi4")
          File.ln_s!("../../../../deps_rpi4/pkg/priv", lib_priv)
          File.write!(Path.join(lib_priv, "pkg_nif.so"), "second-nif")
          {:error, "mix command exited with code 1"}
        else
          write!(beam(dir, target), "second-#{target}")
          :ok
        end
      end

      assert {:ok, out} = OptionalDepsTargets.run(params(dir), runners(dir, %{compile: compile}))

      assert out.systems["nerves_system_rpi4"].optional_deps.reason == "target_compile_failed"
      assert File.read!(beam(dir, "rpi4")) == "first-rpi4"
      put_back = Path.join(lib_priv, "pkg_nif.so")
      assert File.read!(put_back) == "first-nif"
      assert Bitwise.band(File.stat!(put_back).mode, 0o777) == 0o755
      refute File.exists?(aside(dir, "rpi4"))
    end

    test "a kept target whose rescan errors goes back to its first build", %{dir: dir} do
      scan = fn build_path, _pkg ->
        if Path.basename(build_path) == "rpi4",
          do: %{"errors" => ["beam scan failed: :enoent"]},
          else: %{"rescanned" => "bbb"}
      end

      compile_env = fn build_path, _pkg ->
        if Path.basename(build_path) == "bbb", do: nil, else: []
      end

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{scan: scan, compile_env: compile_env})
               )

      for target <- @targets do
        sys = out.systems["nerves_system_#{target}"]
        assert sys.optional_deps.reason == "target_compile_failed"
        assert sys.beam_scan == %{"first" => target}
        refute Map.has_key?(sys, :deps_lock)
        assert File.read!(beam(dir, target)) == "first-#{target}"
      end
    end

    test "deps.get is bounded by min(per-system timeout, time left)", %{dir: dir} do
      test_pid = self()

      deps_get = fn _dir, env, _log, timeout_sec ->
        send(test_pid, {:deps_get, target_of(env), timeout_sec})
        File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
        :ok
      end

      assert {:ok, _} =
               OptionalDepsTargets.run(
                 params(dir, %{budget_sec: 100}),
                 runners(dir, %{deps_get: deps_get, now: fn -> 0 end})
               )

      assert_received {:deps_get, "rpi4", 100}

      assert {:ok, _} =
               OptionalDepsTargets.run(
                 params(dir, %{budget_sec: 5000}),
                 runners(dir, %{deps_get: deps_get, now: fn -> 0 end})
               )

      assert_received {:deps_get, "rpi4", 600}
    end

    test "a deps.get that times out is reaped and the first build goes back", %{dir: dir} do
      test_pid = self()

      deps_get = fn _dir, env, _log, _timeout ->
        if target_of(env) == "rpi4" do
          write!(beam(dir, "rpi4"), "half-rpi4")
          {:error, :timeout}
        else
          File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
          :ok
        end
      end

      reap = fn build_path ->
        send(test_pid, {:reap, Path.basename(build_path)})
        :ok
      end

      assert {:ok, out} =
               OptionalDepsTargets.run(
                 params(dir),
                 runners(dir, %{deps_get: deps_get, reap: reap})
               )

      assert out.systems["nerves_system_rpi4"].optional_deps.reason == "timeout"
      assert_received {:reap, "rpi4"}
      assert File.read!(beam(dir, "rpi4")) == "first-rpi4"
      assert out.systems["nerves_system_bbb"].optional_deps.added == ["jason"]
    end
  end
end
