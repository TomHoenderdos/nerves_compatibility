defmodule NccWorker.WorldTargetsTest do
  # The runners that would reach Hex or run `mix` are stubs over a Hex
  # registry in miniature; the files the sub-pass copies, compiles into,
  # renames and checks are real.
  use ExUnit.Case, async: true

  alias NccWorker.WorldTargets

  {:ok, members} = Compatibility.Worlds.firmware_members("nerves")
  @members members

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

  # nerves_motd's shape: nerves_time and muontrap are members,
  # nerves_time_zones is not.
  @motd %{
    "nerves" => [],
    "pkg" => [
      {"nerves_runtime", false},
      {"nerves_time", true},
      {"muontrap", true},
      {"nerves_time_zones", true}
    ],
    "nerves_runtime" => [],
    "nerves_time" => [{"muontrap", false}],
    "muontrap" => [],
    "nerves_time_zones" => []
  }

  # The jason class: no optional dependency of its own, an optional jason
  # under ecto. decimal under jason is not a member.
  @jason %{
    "nerves" => [],
    "pkg" => [{"ecto", false}],
    "ecto" => [{"decimal", false}, {"jason", true}],
    "jason" => [{"decimal", true}],
    "decimal" => []
  }

  # Nothing a member reaches.
  @plain %{"nerves" => [], "pkg" => [{"telemetry", false}, {"cowboy", true}], "telemetry" => []}

  @targets ~w(rpi4 bbb)

  setup do
    dir = Path.join(System.tmp_dir!(), "world_targets_#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "logs"))
    File.write!(Path.join(dir, "mix.exs"), @mix_exs)
    on_exit(fn -> File.rm_rf!(dir) end)
    {:ok, dir: dir}
  end

  # ── fixtures ────────────────────────────────────────────────────────────

  defp write!(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp lib(dir, target), do: Path.join([dir, "_build", target, "lib"])
  defp log(dir, target), do: Path.join([dir, "logs", "nerves_system_#{target}.log"])

  # The project as the optional pass left it: the lock resolved from
  # `mix.exs`, each passing target's published build with a priv link into
  # its deps dir, and one dependency build per lock entry.
  defp project!(dir, registry) do
    write_lock(dir, resolve(registry, top_level(dir), MapSet.new()), registry)

    for target <- @targets do
      write!(Path.join([lib(dir, target), "pkg", "ebin", "pkg.beam"]), "first-#{target}")
      write!(Path.join([dir, "deps_#{target}", "pkg", "priv", "data.txt"]), "priv-#{target}")

      File.ln_s!(
        "../../../../deps_#{target}/pkg/priv",
        Path.join([lib(dir, target), "pkg", "priv"])
      )

      for name <- Map.keys(registry), name not in ["pkg"] do
        write!(Path.join([lib(dir, target), name, "ebin", "#{name}.beam"]), "dep")
      end
    end

    dir
  end

  defp top_level(dir) do
    ~r/\{:([a-z0-9_]+),/
    |> Regex.scan(File.read!(Path.join(dir, "mix.exs")), capture: :all_but_first)
    |> List.flatten()
  end

  defp resolve(_registry, [], seen), do: seen

  defp resolve(registry, [name | rest], seen) do
    if MapSet.member?(seen, name) do
      resolve(registry, rest, seen)
    else
      required = for {dep, false} <- Map.fetch!(registry, name), do: dep
      resolve(registry, required ++ rest, MapSet.put(seen, name))
    end
  end

  defp write_lock(dir, names, registry) do
    entries =
      names
      |> Enum.sort()
      |> Enum.map_join("\n", fn name ->
        deps =
          Enum.map_join(Map.fetch!(registry, name), ", ", fn {dep, optional} ->
            ~s|{:#{dep}, "~> 1.0", [hex: :#{dep}, repo: "hexpm", optional: #{optional}]}|
          end)

        ~s|  "#{name}": {:hex, :#{name}, "1.0.0", "i-#{name}", [:mix], [#{deps}], "hexpm", "o-#{name}"},|
      end)

    File.write!(Path.join(dir, "mix.lock"), "%{\n#{entries}\n}\n")
  end

  defp lock_of(names), do: Map.new(names, &{&1, %{"version" => "1.0.0", "checksum" => "o-#{&1}"}})

  defp manifest_of(app_dir),
    do: %{"ebin" => entries(app_dir, "ebin"), "priv" => entries(app_dir, "priv")}

  defp entries(app_dir, sub) do
    root = Path.join(app_dir, sub)

    for file <- Path.wildcard(Path.join(root, "**"), match_dot: true), File.regular?(file) do
      bytes = File.read!(file)
      %File.Stat{size: size, mode: mode} = File.stat!(file)

      %{
        "path" => Path.relative_to(file, app_dir),
        "sha256" => Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
        "size" => size,
        "mode" => mode
      }
    end
  end

  defp passing(dir, target, extra \\ %{}) do
    Map.merge(
      %{
        status: :pass,
        beam_scan: %{
          "footprint" => %{"file_manifest" => manifest_of(Path.join(lib(dir, target), "pkg"))},
          "errors" => []
        },
        compile_env: []
      },
      extra
    )
  end

  defp params(dir, overrides \\ %{}) do
    systems = %{
      "nerves_system_rpi4" => passing(dir, "rpi4"),
      "nerves_system_bbb" => passing(dir, "bbb"),
      "nerves_system_x86_64" => %{status: :fail, beam_scan: nil}
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
        world: %{name: "nerves", members: @members},
        systems: systems,
        targets: targets,
        timeout_sec: 600,
        concurrency: 2,
        deadline: 1_000,
        run_deps_lock: nil
      },
      overrides
    )
  end

  defp env_value(env, key), do: env |> List.keyfind(key, 0) |> elem(1)

  defp registry_deps_get(test_pid, dir, registry) do
    fn _project_dir, env, _log, _timeout ->
      send(test_pid, {:deps_get, env_value(env, "MIX_TARGET"), env_value(env, "MIX_BUILD_PATH")})
      write_lock(dir, resolve(registry, top_level(dir), MapSet.new()), registry)
      :ok
    end
  end

  # Writes the world build into the env's build path, and reports what the
  # world lib held when it started.
  defp compile(test_pid) do
    fn _project_dir, env, _log, _timeout ->
      target = env_value(env, "MIX_TARGET")
      build_path = env_value(env, "MIX_BUILD_PATH")
      lib = Path.join(build_path, "lib")
      send(test_pid, {:compile, target, build_path, File.ls!(lib) |> Enum.sort()})
      write!(Path.join([lib, "pkg", "ebin", "pkg.beam"]), "world-#{target}")
      :ok
    end
  end

  defp runners(test_pid, dir, registry, overrides \\ %{}) do
    Map.merge(
      %{
        deps_get: registry_deps_get(test_pid, dir, registry),
        lock_policy: fn _ -> :ok end,
        compile: compile(test_pid),
        scan: fn build_path, "pkg" ->
          %{
            "footprint" => %{
              "file_manifest" => manifest_of(Path.join([build_path, "lib", "pkg"]))
            },
            "errors" => []
          }
        end,
        compile_env: fn _build_path, "pkg" -> [%{"world" => true}] end,
        reap: fn _ -> :ok end,
        now: fn -> 0 end
      },
      overrides
    )
  end

  defp assert_clean(dir, lock_before) do
    for target <- @targets,
        do: refute(File.exists?(Path.join([dir, "_build", target <> ".world"])))

    assert File.read!(Path.join(dir, "mix.exs")) == @mix_exs
    assert File.read!(Path.join(dir, "mix.lock")) == lock_before
  end

  defp world_variant(system),
    do: Enum.find(List.wrap(system[:published_variants]), &(&1.variant == "world_nerves"))

  # ── tests ───────────────────────────────────────────────────────────────

  test "the nerves_motd shape gets the world build on every passing target", %{dir: dir} do
    project!(dir, @motd)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    with_lock = lock_of(~w(nerves_runtime nerves_time muontrap nerves_time_zones))

    systems =
      params(dir).systems
      |> put_in(["nerves_system_rpi4", :deps_lock], with_lock)
      |> put_in(["nerves_system_bbb", :deps_lock], with_lock)

    params = params(dir, %{systems: systems, run_deps_lock: lock_of(~w(nerves_runtime))})

    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @motd))

    for target <- @targets do
      system = out.systems["nerves_system_#{target}"]
      variant = world_variant(system)
      assert variant.deps_lock == lock_of(~w(muontrap nerves_runtime nerves_time))
      assert variant.compile_env == [%{"world" => true}]

      assert [%{"path" => "ebin/pkg.beam"}] =
               variant.beam_scan["footprint"]["file_manifest"]["ebin"]

      variant_dir = Path.join(lib(dir, target), ".pkg.world_nerves")
      assert File.read!(Path.join([variant_dir, "ebin", "pkg.beam"])) == "world-#{target}"
      # The published build is untouched.
      assert File.read!(Path.join([lib(dir, target), "pkg", "ebin", "pkg.beam"])) ==
               "first-#{target}"

      assert File.read!(log(dir, target)) =~ "world nerves: kept"
    end

    assert out.systems["nerves_system_x86_64"] == params.systems["nerves_system_x86_64"]

    assert %{name: "nerves", kept: kept, added: added, reason: nil} = out.world
    assert Enum.sort(kept) == ~w(nerves_system_bbb nerves_system_rpi4)
    assert Enum.sort(added) == ~w(muontrap nerves_time)

    # Built only under the world build path.
    assert_received {:compile, "rpi4", rpi4_path, _}
    assert String.ends_with?(rpi4_path, "_build/rpi4.world")
    assert_clean(dir, lock_before)
  end

  test "the jason class (no direct optional dep) gets it too", %{dir: dir} do
    project!(dir, @jason)
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @jason))

    for target <- @targets do
      variant = world_variant(out.systems["nerves_system_#{target}"])
      assert variant.deps_lock == lock_of(~w(decimal ecto jason))
    end

    assert out.world.added == ["jason"]
  end

  test "an ancestor whose closure changed is removed before the compile", %{dir: dir} do
    project!(dir, @jason)
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    assert {:ok, _out} = WorldTargets.run(params, runners(self(), dir, @jason))

    for target <- @targets do
      assert_received {:compile, ^target, _path, world_lib}
      # ecto gained jason: rebuilt. decimal did not: kept. pkg: rebuilt.
      refute "ecto" in world_lib
      refute "pkg" in world_lib
      assert "decimal" in world_lib
      # No variant dir was copied in.
      refute Enum.any?(world_lib, &String.starts_with?(&1, ".pkg."))
      # The real build path keeps its ecto.
      assert File.exists?(Path.join([lib(dir, target), "ecto", "ebin", "ecto.beam"]))
    end
  end

  # The optional pass (`NccWorker.OptionalDepsTargets`) left
  # `_build/<t>/lib` as its build with saw it: ecto rebuilt with x_lib, the
  # package's own optional dep, which the world does not add. The run lock
  # is restored, so ecto's closure does not change between the run lock and
  # the world's, yet its build in the copy is the one with x_lib.
  @with_left %{
    "nerves" => [],
    "pkg" => [{"ecto", false}, {"nerves_time", true}, {"x_lib", true}],
    "ecto" => [{"decimal", false}, {"x_lib", true}],
    "decimal" => [],
    "nerves_time" => [],
    "x_lib" => []
  }

  test "a dep the build with recompiled with an optional dep the world lacks is rebuilt",
       %{dir: dir} do
    project!(dir, @with_left)
    with_lock = lock_of(~w(decimal ecto nerves_time x_lib))

    systems =
      params(dir).systems
      |> put_in(["nerves_system_rpi4", :deps_lock], with_lock)
      |> put_in(["nerves_system_bbb", :deps_lock], with_lock)

    # The build with compiled x_lib on rpi4 only.
    File.rm_rf!(Path.join(lib(dir, "bbb"), "x_lib"))

    params = params(dir, %{systems: systems, run_deps_lock: lock_of(~w(decimal ecto))})
    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @with_left))

    assert world_variant(out.systems["nerves_system_rpi4"]).deps_lock ==
             lock_of(~w(decimal ecto nerves_time))

    assert_received {:compile, "rpi4", _path, rpi4_lib}
    # ecto may have been built with x_lib: rebuilt in the world.
    refute "ecto" in rpi4_lib
    assert "decimal" in rpi4_lib

    assert_received {:compile, "bbb", _path, bbb_lib}
    # x_lib was never built on bbb, so its ecto cannot have seen it.
    assert "ecto" in bbb_lib
  end

  # The build with added mdns_lite, the package's own optional dep, alone:
  # it compiled mdns_lite without vintage_net, its optional dep, which only
  # the world's fixpoint adds. mdns_lite is in no closure of the run lock, so
  # its closure never "changed", and Mix keeps the copy's build of it at the
  # same lock entry.
  @new_in_world %{
    "nerves" => [],
    "pkg" => [{"mdns_lite", true}],
    "mdns_lite" => [{"vintage_net", true}],
    "vintage_net" => []
  }

  test "a dep the run lock lacks is rebuilt in the world, not kept from the build with",
       %{dir: dir} do
    project!(dir, @new_in_world)
    with_lock = lock_of(~w(mdns_lite))

    systems =
      params(dir).systems
      |> put_in(["nerves_system_rpi4", :deps_lock], with_lock)
      |> put_in(["nerves_system_bbb", :deps_lock], with_lock)

    # The build with never compiled vintage_net.
    for target <- @targets, do: File.rm_rf!(Path.join(lib(dir, target), "vintage_net"))

    params = params(dir, %{systems: systems, run_deps_lock: lock_of([])})
    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @new_in_world))

    for target <- @targets do
      assert world_variant(out.systems["nerves_system_#{target}"]).deps_lock ==
               lock_of(~w(mdns_lite vintage_net))

      assert_received {:compile, ^target, _path, world_lib}
      refute "mdns_lite" in world_lib
      # The real build path keeps the build with's.
      assert File.exists?(Path.join([lib(dir, target), "mdns_lite", "ebin", "mdns_lite.beam"]))
    end
  end

  test "a published build without is never copied and stays as it was", %{dir: dir} do
    project!(dir, @jason)

    for target <- @targets,
        do: write!(Path.join([lib(dir, target), ".pkg.without", "ebin", "pkg.beam"]), "w")

    without = fn target ->
      %{
        variant: "without",
        beam_scan: %{
          "footprint" => %{
            "file_manifest" => manifest_of(Path.join(lib(dir, target), ".pkg.without"))
          }
        },
        compile_env: [],
        deps_lock: lock_of(~w(decimal ecto))
      }
    end

    systems =
      params(dir).systems
      |> put_in(["nerves_system_rpi4", :published_variants], [without.("rpi4")])
      |> put_in(["nerves_system_bbb", :published_variants], [without.("bbb")])

    params = params(dir, %{systems: systems, run_deps_lock: lock_of(~w(decimal ecto))})
    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @jason))

    for target <- @targets do
      assert [%{variant: "without"}, %{variant: "world_nerves"}] =
               out.systems["nerves_system_#{target}"].published_variants

      assert File.read!(Path.join([lib(dir, target), ".pkg.without", "ebin", "pkg.beam"])) == "w"
    end
  end

  test "nothing a member reaches: no copy, no deps.get, no compile", %{dir: dir} do
    project!(dir, @plain)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(telemetry))})

    never = fn _, _, _, _ -> flunk("ran") end

    runners =
      runners(self(), dir, @plain, %{
        deps_get: never,
        compile: never,
        copy: fn _, _ -> flunk("copied") end
      })

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert out.systems == params.systems
    assert out.world.reason == "same_closure_as_without"
    assert out.world.kept == []
    assert_clean(dir, lock_before)
  end

  test "a target whose build with has the world closure is dropped", %{dir: dir} do
    project!(dir, @motd)
    lock_before = File.read!(Path.join(dir, "mix.lock"))

    systems =
      params(dir).systems
      |> put_in(
        ["nerves_system_rpi4", :deps_lock],
        lock_of(~w(muontrap nerves_runtime nerves_time))
      )
      |> put_in(
        ["nerves_system_bbb", :deps_lock],
        lock_of(~w(muontrap nerves_runtime nerves_time nerves_time_zones))
      )

    params = params(dir, %{systems: systems, run_deps_lock: lock_of(~w(nerves_runtime))})
    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @motd))

    assert world_variant(out.systems["nerves_system_rpi4"]) == nil
    assert world_variant(out.systems["nerves_system_bbb"])
    assert out.world.kept == ["nerves_system_bbb"]
    assert File.read!(log(dir, "rpi4")) =~ "dropped (same_closure_as_with)"
    refute_received {:compile, "rpi4", _, _}
    assert_clean(dir, lock_before)
  end

  test "a published byte changed by the world pass fails the run", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    compile = compile(self())

    runners =
      runners(self(), dir, @jason, %{
        compile: fn project_dir, env, log, timeout ->
          # Something writes the published build behind the pass's back.
          File.write!(Path.join([lib(dir, "bbb"), "pkg", "ebin", "pkg.beam"]), "tampered")
          compile.(project_dir, env, log, timeout)
        end
      })

    assert {:error, {:optional_deps_revert_failed, {:world_changed_published_build, _, _}}} =
             WorldTargets.run(params, runners)

    assert_clean(dir, lock_before)
  end

  test "a write through the deps priv dir never reaches the published build", %{dir: dir} do
    project!(dir, @jason)
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})
    compile = compile(self())

    runners =
      runners(self(), dir, @jason, %{
        compile: fn project_dir, env, log, timeout ->
          target = env_value(env, "MIX_TARGET")
          File.write!(Path.join([dir, "deps_#{target}", "pkg", "priv", "data.txt"]), "rebuilt")
          compile.(project_dir, env, log, timeout)
        end
      })

    assert {:ok, _out} = WorldTargets.run(params, runners)

    for target <- @targets do
      priv = Path.join([lib(dir, target), "pkg", "priv"])
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(priv)
      assert File.read!(Path.join(priv, "data.txt")) == "priv-#{target}"
    end
  end

  test "a spent budget skips the world and leaves every build as it was", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto)), deadline: 10})
    never = fn _, _, _, _ -> flunk("ran") end
    runners = runners(self(), dir, @jason, %{now: fn -> 10 end, deps_get: never, compile: never})

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert out.systems == params.systems
    assert out.world.reason == "timeout"

    for target <- @targets do
      assert File.read!(Path.join([lib(dir, target), "pkg", "ebin", "pkg.beam"])) ==
               "first-#{target}"

      assert File.read!(log(dir, target)) =~ "not built (timeout)"
    end

    assert_clean(dir, lock_before)
  end

  test "a run past 75 minutes does not start", %{dir: dir} do
    project!(dir, @jason)

    params =
      params(dir, %{run_deps_lock: lock_of(~w(decimal ecto)), run_elapsed_sec: 75 * 60 + 1})

    never = fn _, _, _, _ -> flunk("ran") end

    assert {:ok, out} =
             WorldTargets.run(
               params,
               runners(self(), dir, @jason, %{deps_get: never, compile: never})
             )

    assert out.world.reason == "run_budget_exhausted"
  end

  test "a copy that fails half way drops that target and leaves no world dir", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    copy = fn from, to ->
      if String.contains?(to, "/rpi4.world/") do
        File.mkdir_p!(Path.join(to, "partial"))
        {:error, {1, "No space left on device"}}
      else
        {_, 0} = System.cmd("cp", ["-a", from, to])
        :ok
      end
    end

    runners = runners(self(), dir, @jason, %{copy: copy})

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert world_variant(out.systems["nerves_system_rpi4"]) == nil
    assert world_variant(out.systems["nerves_system_bbb"])
    assert File.read!(log(dir, "rpi4")) =~ "dropped (copy_failed)"
    assert_clean(dir, lock_before)
  end

  test "a failed compile drops that target only and cleans up", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})
    compile = compile(self())

    runners =
      runners(self(), dir, @jason, %{
        compile: fn project_dir, env, log, timeout ->
          if env_value(env, "MIX_TARGET") == "rpi4",
            do: {:error, "mix compile exited with code 1"},
            else: compile.(project_dir, env, log, timeout)
        end
      })

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert world_variant(out.systems["nerves_system_rpi4"]) == nil
    assert world_variant(out.systems["nerves_system_bbb"])
    assert File.read!(log(dir, "rpi4")) =~ "dropped (target_compile_failed)"
    refute File.exists?(Path.join(lib(dir, "rpi4"), ".pkg.world_nerves"))
    assert_clean(dir, lock_before)
  end

  test "the other targets fetch into their own deps path, serially", %{dir: dir} do
    project!(dir, @jason)
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    assert {:ok, _} = WorldTargets.run(params, runners(self(), dir, @jason))

    # The fixpoint's (rpi4, the first target), then bbb's.
    assert_received {:deps_get, "rpi4", rpi4_path}
    assert String.ends_with?(rpi4_path, "rpi4.world")
    assert_received {:deps_get, "bbb", bbb_path}
    assert String.ends_with?(bbb_path, "bbb.world")
  end

  test "a lock the other target's deps.get moves drops it", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})
    deps_get = registry_deps_get(self(), dir, @jason)

    runners =
      runners(self(), dir, @jason, %{
        deps_get: fn project_dir, env, log, timeout ->
          :ok = deps_get.(project_dir, env, log, timeout)

          if env_value(env, "MIX_TARGET") == "bbb",
            do:
              File.write!(
                Path.join(dir, "mix.lock"),
                File.read!(Path.join(dir, "mix.lock")) <> "\n"
              )

          :ok
        end
      })

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert out.world.kept == ["nerves_system_rpi4"]
    assert File.read!(log(dir, "bbb")) =~ "dropped (world_lock_moved)"
    assert_clean(dir, lock_before)
  end

  test "a world closure equal to the build without's publishes nothing", %{dir: dir} do
    project!(dir, @jason)
    # As if the run lock already held jason.
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto jason))})

    assert {:ok, out} = WorldTargets.run(params, runners(self(), dir, @jason))
    assert out.world.kept == []
    assert out.world.reason == "same_closure_as_without"
    refute_received {:compile, _, _, _}
  end

  test "no passing target", %{dir: dir} do
    project!(dir, @jason)
    systems = Map.new(params(dir).systems, fn {k, v} -> {k, %{v | status: :fail}} end)

    assert {:ok, %{world: %{reason: "no_passing_target"}}} =
             WorldTargets.run(params(dir, %{systems: systems}), runners(self(), dir, @jason))
  end

  test "the world build path holds no world after a failed fixpoint", %{dir: dir} do
    project!(dir, @jason)
    lock_before = File.read!(Path.join(dir, "mix.lock"))
    params = params(dir, %{run_deps_lock: lock_of(~w(decimal ecto))})

    runners =
      runners(self(), dir, @jason, %{
        deps_get: fn _, _, _, _ -> {:error, {:deps_get_failed, "no network"}} end
      })

    assert {:ok, out} = WorldTargets.run(params, runners)
    assert out.world.reason == "deps_get_failed"
    assert out.systems == params.systems
    assert_clean(dir, lock_before)
  end
end
