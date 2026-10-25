defmodule NccWorker.WarmNervesTest do
  use ExUnit.Case, async: true

  alias NccWorker.{NervesCache, Systems, WarmNerves}

  @moduletag :tmp_dir

  @lock """
  %{
    "nerves_system_bbb": {:hex, :nerves_system_bbb, "2.0.0", "i", [:mix], [], "hexpm", "o"},
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "2.0.0", "i", [:mix], [], "hexpm", "o"},
    "nerves_toolchain_aarch64_nerves_linux_gnu": {:hex, :nerves_toolchain_aarch64_nerves_linux_gnu, "14.2.0", "i", [:mix], [], "hexpm", "o"},
  }
  """

  @toolchain %{elixir: "1.20.3", erlang: "29", mix: "1.20.3", nerves_bootstrap: "1.17.3"}

  defp p(name, version), do: %{"name" => name, "version" => version}

  # run/5 sets HEX_HOME for the whole VM; tests run async and must not.
  defp no_put_env(_name, _value), do: :ok

  describe "plan/2" do
    test "pins a requested system exactly and builds only its target" do
      plan = WarmNerves.plan([p("nerves_system_rpi4", "2.0.0")], Systems.default())

      assert plan.overrides == %{"nerves_system_rpi4" => "== 2.0.0"}
      assert Enum.map(plan.systems, & &1.name) == ["nerves_system_rpi4"]
      assert plan.requested == [p("nerves_system_rpi4", "2.0.0")]
      assert plan.rejected == []
    end

    test "no pairs warms every default target with nothing pinned" do
      plan = WarmNerves.plan([], Systems.default())

      assert plan.overrides == %{}
      assert plan.systems == Systems.default()
    end

    # A toolchain is a dependency of a system, not of the project: it is
    # resolved through whichever system needs it, on every target.
    test "a toolchain is never pinned and warms every target" do
      toolchain = p("nerves_toolchain_aarch64_nerves_linux_gnu", "14.2.0")
      plan = WarmNerves.plan([p("nerves_system_rpi4", "2.0.0"), toolchain], Systems.default())

      assert plan.overrides == %{"nerves_system_rpi4" => "== 2.0.0"}
      assert plan.systems == Systems.default()
      assert toolchain in plan.requested
    end

    test "rejects anything that is not a Nerves system or toolchain at a version" do
      bad = [
        p("jason", "1.4.4"),
        p("nerves_system_rpi4", "2.0.0\"}, {:evil, \"1"),
        p("nerves_system_rpi4", ">= 0.0.0"),
        p("../nerves_system_rpi4", "2.0.0"),
        p("nerves_system_unknown_board", "1.0.0"),
        %{"name" => "nerves_system_rpi4"},
        "nerves_system_rpi4-2.0.0"
      ]

      plan = WarmNerves.plan(bad, Systems.default())

      assert plan.overrides == %{}
      assert plan.requested == []
      assert Enum.sort(plan.rejected) == Enum.sort(bad)
    end

    test "a second version of one system is rejected, not pinned twice" do
      plan =
        WarmNerves.plan(
          [p("nerves_system_rpi4", "2.0.0"), p("nerves_system_rpi4", "2.0.1")],
          Systems.default()
        )

      assert plan.overrides == %{"nerves_system_rpi4" => "== 2.0.0"}
      assert plan.rejected == [p("nerves_system_rpi4", "2.0.1")]
    end
  end

  describe "run/5" do
    setup %{tmp_dir: tmp} do
      cache = Path.join(tmp, "cache")
      out = Path.join(tmp, "out")
      File.mkdir_p!(Path.join(out, "logs"))

      paths = %{
        work_dir: Path.join(tmp, "work"),
        output_dir: out,
        logs_dir: Path.join(out, "logs")
      }

      {:ok, layout} =
        NervesCache.prepare(:warm,
          cache_root: cache,
          work_dir: paths.work_dir,
          run_id: "warm_nerves-42"
        )

      %{cache: cache, paths: paths, layout: layout}
    end

    defp input(pairs),
      do: %{
        run_id: "warm_nerves-42",
        image: %{name: "ncc-worker:local", digest: "sha256:x"},
        mode: "warm_nerves",
        nerves_packages: pairs
      }

    # Stands in for `Project.create/3`: a project with a lock.
    defp fake_project do
      me = self()

      fn work_dir, overrides, targets ->
        send(me, {:created, overrides, targets})
        dir = Path.join(work_dir, "proj")
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, "mix.lock"), @lock)
        {:ok, dir}
      end
    end

    # Stands in for `mix`: `nerves.artifact.get` for a target extracts that
    # target's artifacts the way Nerves does, into the staging farm.
    defp fake_mix(layout, extracted, fail \\ nil) do
      me = self()

      fn args, _dir, env, _log ->
        {"MIX_TARGET", target} = List.keyfind(env, "MIX_TARGET", 0)
        send(me, {:mix, target, args})

        cond do
          {target, args} == fail ->
            {:error, 1}

          args == ["nerves.artifact.get"] ->
            extract_artifacts(layout, Map.get(extracted, target, []))
            :ok

          true ->
            :ok
        end
      end
    end

    defp extract_artifacts(layout, entries) do
      for {entry, fingerprint} <- entries do
        dir = Path.join(layout.artifacts_dir, entry)
        File.rm_rf!(dir)
        File.mkdir_p!(dir)
        File.write!(Path.join(dir, ".fingerprint"), fingerprint)
      end
    end

    test "installs what it extracted, reports what it resolved, removes staging", ctx do
      %{cache: cache, paths: paths, layout: layout} = ctx
      mix = fake_mix(layout, %{"rpi4" => [{"nerves_system_rpi4-2.0.0", "abc1234"}]})

      assert {:ok, result} =
               WarmNerves.run(
                 input([p("nerves_system_rpi4", "2.0.0")]),
                 paths,
                 @toolchain,
                 layout,
                 create_project: fake_project(),
                 put_env: &no_put_env/2,
                 mix: mix
               )

      assert_received {:created, %{"nerves_system_rpi4" => "== 2.0.0"}, _targets}
      assert_received {:mix, "rpi4", ["deps.get"]}
      assert_received {:mix, "rpi4", ["nerves.artifact.get"]}
      refute_received {:mix, "bbb", _}

      entry = Path.join([cache, "artifacts", "nerves_system_rpi4-2.0.0"])
      assert File.read!(Path.join(entry, ".fingerprint")) == "abc1234"
      refute File.exists?(Path.join([cache, "staging", "warm_nerves-42"]))

      assert result.scope == "warm_nerves"
      assert result.package == nil
      assert result.systems == %{}
      assert result.warm.installed == ["nerves_system_rpi4-2.0.0"]
      assert result.warm.targets == ["nerves_system_rpi4"]
      assert "nerves_system_rpi4-2.0.0" in result.warm.resolved
      assert "nerves_toolchain_aarch64_nerves_linux_gnu-14.2.0" in result.warm.resolved
      assert result.warm.not_warmed == []
    end

    test "no pairs warms the template on every default target", ctx do
      %{paths: paths, layout: layout} = ctx

      assert {:ok, result} =
               WarmNerves.run(input([]), paths, @toolchain, layout,
                 create_project: fake_project(),
                 put_env: &no_put_env/2,
                 mix: fake_mix(layout, %{})
               )

      assert_received {:created, nil, _targets}
      assert result.warm.targets == Enum.map(Systems.default(), & &1.name)
    end

    test "a target that fails installs nothing and leaves no staging", ctx do
      %{cache: cache, paths: paths, layout: layout} = ctx

      mix =
        fake_mix(
          layout,
          %{"bbb" => [{"nerves_system_bbb-2.0.0", "bbb0001"}]},
          {"x86_64", ["deps.get"]}
        )

      assert {:error, {:warm_failed, "nerves_system_x86_64", "deps.get", 1}} =
               WarmNerves.run(input([]), paths, @toolchain, layout,
                 create_project: fake_project(),
                 put_env: &no_put_env/2,
                 mix: mix
               )

      refute File.exists?(Path.join([cache, "artifacts", "nerves_system_bbb-2.0.0"]))
      refute File.exists?(Path.join([cache, "staging", "warm_nerves-42"]))
    end

    # Every build mounts /hex-cache read-write and can plant hex.config,
    # cache.ets or tarballs there; the warm, the only container that writes
    # the Nerves cache, must resolve through a Hex home no build has touched.
    test "runs every mix with a fresh HEX_HOME under /work, never /hex-cache", ctx do
      %{paths: paths, layout: layout} = ctx
      me = self()
      hex_home = Path.join(paths.work_dir, "hex-home")
      File.mkdir_p!(hex_home)
      File.write!(Path.join(hex_home, "hex.config"), "planted")

      mix = fn args, _dir, env, _log ->
        send(me, {:mix_env, args, env})
        :ok
      end

      create = fn work_dir, _overrides, _targets ->
        send(me, :created)
        fake_project().(work_dir, nil, [])
      end

      put_env = fn name, value ->
        send(me, {:put_env, name, value, File.ls!(value)})
        :ok
      end

      assert {:ok, _result} =
               WarmNerves.run(
                 input([p("nerves_system_rpi4", "2.0.0")]),
                 paths,
                 @toolchain,
                 layout,
                 create_project: create,
                 mix: mix,
                 put_env: put_env
               )

      {:messages, messages} = Process.info(self(), :messages)

      # Set, fresh and empty, before Project.create runs its first mix.
      assert [{:put_env, "HEX_HOME", ^hex_home, []}, :created | _] = messages

      envs = for {:mix_env, _args, env} <- messages, do: env
      assert envs != []

      for env <- envs do
        assert List.keyfind(env, "HEX_HOME", 0) == {"HEX_HOME", hex_home}

        refute Enum.any?(env, fn {_k, v} ->
                 is_binary(v) and String.starts_with?(v, "/hex-cache")
               end)
      end
    end

    test "a requested pair the project did not lock is reported not warmed", ctx do
      %{paths: paths, layout: layout} = ctx
      wanted = p("nerves_toolchain_aarch64_nerves_linux_gnu", "13.2.0")

      assert {:ok, result} =
               WarmNerves.run(input([wanted]), paths, @toolchain, layout,
                 create_project: fake_project(),
                 put_env: &no_put_env/2,
                 mix: fake_mix(layout, %{})
               )

      assert result.warm.not_warmed == [wanted]
    end
  end
end
