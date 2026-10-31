defmodule NccAgent.NervesCacheTest do
  use ExUnit.Case, async: false

  # The warm run pulls the image (absent in the fake docker) and logs its exit code.
  @moduletag :capture_log

  alias NccAgent.{Config, NervesCache}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_ARGV_LOG FAKE_DOCKER_RESULT FAKE_DOCKER_EXIT)

  setup do
    dir = Path.join(System.tmp_dir!(), "nc-#{System.unique_integer([:positive])}")
    config = %{Config.defaults() | data_dir: dir, portal_url: "https://x", memory: "4g"}
    entry = Path.join([dir, "nerves-cache", "artifacts", "nerves_system_rpi4-1.30.0"])
    File.mkdir_p!(entry)
    File.write!(Path.join(entry, ".fingerprint"), "fp")

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      File.rm_rf(dir)
    end)

    %{config: config, dir: dir}
  end

  defp claim do
    %{
      "run_id" => "rb-jason-1.4.4-1",
      "image" => %{
        "name" => "ghcr.io/x/ncc-worker",
        "digest" => "sha256:" <> String.duplicate("a", 64)
      },
      "input" => %{
        "run_id" => "rb-jason-1.4.4-1",
        "image" => %{},
        "package" => %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
        "paths" => %{},
        "systems_filter" => ["rpi4"],
        "argus" => %{"enabled" => true}
      },
      "timeout_sec" => 60
    }
  end

  defp pair(name, version), do: %{"name" => name, "version" => version}

  test "prepare_cache creates the cache and its artifacts dir", %{dir: dir} do
    other = Path.join(dir, "fresh")
    config = %{Config.defaults() | data_dir: other, portal_url: "https://x"}
    assert :ok = NervesCache.prepare_cache(config)
    assert File.dir?(Path.join([other, "nerves-cache", "artifacts"]))
  end

  test "pairs keeps well-formed official pairs, deduplicated, at most four" do
    long = String.duplicate("a", 65)

    assert NervesCache.pairs([
             %{"name" => 1, "version" => "1.0.0"},
             %{"name" => "x"},
             "junk",
             pair("nerves_system_rpi4", "1"),
             pair("../etc", "1.0.0"),
             pair("evil_system", "1.0.0"),
             pair("Nerves_System_Rpi4", "1.0.0"),
             pair("nerves_system_" <> long, "1.0.0"),
             pair("nerves_system_rpi4", "1.0.0-" <> long),
             pair("nerves_system_rpi4", "2.0.0-rc.1"),
             pair("nerves_system_rpi4", "2.0.0-rc.1"),
             pair("nerves_toolchain_aarch64_nerves_linux_gnu", "13.2.0")
           ]) == [
             %{name: "nerves_system_rpi4", version: "2.0.0-rc.1"},
             %{name: "nerves_toolchain_aarch64_nerves_linux_gnu", version: "13.2.0"}
           ]

    many = for n <- 1..6, do: pair("nerves_system_rpi#{n}", "1.0.0")
    assert length(NervesCache.pairs(many)) == 4
    assert NervesCache.pairs("nope") == []
    assert NervesCache.pairs(nil) == []
  end

  test "a symlinked artifacts dir is replaced, never followed", %{config: config, dir: dir} do
    victim = Path.join(dir, "victim")
    File.mkdir_p!(Path.join(victim, "secret"))
    cache_artifacts = Path.join([dir, "nerves-cache", "artifacts"])
    File.rm_rf!(cache_artifacts)
    File.ln_s!(victim, cache_artifacts)

    assert :ok = NervesCache.prepare_cache(config)

    assert File.ls!(victim) == ["secret"]
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(cache_artifacts)
    assert File.ls!(cache_artifacts) == []
  end

  test "a symlinked or file cache root is replaced", %{config: config, dir: dir} do
    victim = Path.join(dir, "victim")
    File.mkdir_p!(Path.join(victim, "artifacts/x-1.0.0"))
    cache = Path.join(dir, "nerves-cache")
    File.rm_rf!(cache)
    File.ln_s!(victim, cache)

    assert :ok = NervesCache.prepare_cache(config)
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(cache)
    assert File.ls!(Path.join(victim, "artifacts")) == ["x-1.0.0"]
    assert File.ls!(Path.join(cache, "artifacts")) == []

    File.rm_rf!(cache)
    File.write!(cache, "not a dir")
    assert :ok = NervesCache.prepare_cache(config)
    assert {:ok, %File.Stat{type: :directory}} = File.lstat(Path.join(cache, "artifacts"))
  end

  test "warm runs the worker read-write in warm_nerves mode for the portal's pairs", %{
    config: config,
    dir: dir
  } do
    argv_log = Path.join(dir, "argv.log")
    System.put_env("FAKE_DOCKER_ARGV_LOG", argv_log)
    System.put_env("FAKE_DOCKER_RESULT", ~s({"scope":"warm_nerves"}))
    config = %{config | docker_bin: @fake}

    assert :skipped = NervesCache.warm(config, claim(), [pair("evil", "1.0.0")])
    assert :skipped = NervesCache.warm(config, claim(), [])
    assert :skipped = NervesCache.warm(config, claim(), nil)
    refute File.exists?(argv_log)

    pairs = [pair("nerves_system_rpi4", "1.30.0")]
    assert :ok = NervesCache.warm(config, claim(), pairs, keep_scratch: true)
    argv = File.read!(argv_log)
    assert argv =~ "type=bind,source=#{Path.join(dir, "nerves-cache")},target=/nerves-cache\n"
    refute argv =~ "target=/nerves-cache,readonly"
    refute argv =~ "NCC_NERVES_CACHE_RW"
    refute argv =~ "build-cache"
    assert argv =~ "--read-only\n"
    assert argv =~ "--runtime=runsc\n"
    assert argv =~ "ncc-rb-jason-1.4.4-1-warm\n"

    [input] =
      Path.join(dir, "scratch/*/work/input.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))

    assert input["mode"] == "warm_nerves"
    assert input["nerves_packages"] == [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}]
    assert input["run_id"] == "rb-jason-1.4.4-1-warm"
    refute Map.has_key?(input, "package")
    refute Map.has_key?(input, "systems_filter")
    refute Map.has_key?(input, "argus")
    assert [_] = Path.wildcard(Path.join(dir, "scratch/rb-jason-1.4.4-1-warm"))
  end

  test "warm removes its scratch and reports a failing exit", %{config: config, dir: dir} do
    System.put_env("FAKE_DOCKER_EXIT", "10")
    config = %{config | docker_bin: @fake}
    pairs = [pair("nerves_system_rpi4", "1.30.0")]

    assert {:error, {:exit, 10}} = NervesCache.warm(config, claim(), pairs)
    refute File.exists?(Path.join(dir, "scratch/rb-jason-1.4.4-1-warm"))
  end
end
