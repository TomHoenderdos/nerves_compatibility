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
    fn _project_dir, _env, _log_file ->
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
        compile_env: fn build_path, "pkg" -> [%{"second" => Path.basename(build_path)}] end
      },
      overrides
    )
  end

  defp never("inject"), do: fn _, _ -> flunk("inject ran") end
  defp never("deps.get"), do: fn _, _, _ -> flunk("deps.get ran") end
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

    deps_get = fn _dir, env, log_file ->
      send(test_pid, {:deps_get, target_of(env), log_file})
      File.write!(Path.join(dir, "mix.lock"), @lock_with_jason)
      :ok
    end

    assert {:ok, _} = OptionalDepsTargets.run(params(dir), runners(dir, %{deps_get: deps_get}))

    rpi4_log = log(dir, "rpi4")
    bbb_log = log(dir, "bbb")
    assert_received {:deps_get, "rpi4", ^rpi4_log}
    assert_received {:deps_get, "bbb", ^bbb_log}
    refute_received {:deps_get, "x86_64", _}
  end

  test "a failed deps.get or lock policy drops that target only", %{dir: dir} do
    deps_get = fn _dir, env, _log ->
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
    inject = fn _dir, _deps -> {:error, :no_deps_block} end

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
end
