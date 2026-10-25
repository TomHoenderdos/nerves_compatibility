defmodule NccAgent.NervesCacheTest do
  use ExUnit.Case, async: false

  # The warm run pulls the image (absent in the fake docker) and logs its exit code.
  @moduletag :capture_log

  alias NccAgent.{Config, NervesCache}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_ARGV_LOG FAKE_DOCKER_RESULT FAKE_DOCKER_EXIT)

  setup do
    dir = Path.join(System.tmp_dir!(), "nc-#{System.unique_integer([:positive])}")
    config = %{Config.defaults() | data_dir: dir, portal_url: "https://x"}
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
        "package" => %{},
        "paths" => %{},
        "systems_filter" => ["rpi4"],
        "argus" => %{"enabled" => true}
      },
      "warm_allowlist" => ["nerves_system_rpi4"],
      "timeout_sec" => 60
    }
  end

  defp miss(name, version), do: %{"name" => name, "version" => version}

  test "builds a symlink farm pointing at the container path and an empty dl dir", %{
    config: config,
    dir: dir
  } do
    work = Path.join(dir, "work")
    assert %{env: env, artifacts_dir: artifacts, dl_dir: dl} = NervesCache.prepare(config, work)

    assert env == [
             {"NERVES_ARTIFACTS_DIR", "/work/nerves/artifacts"},
             {"NERVES_DL_DIR", "/work/nerves/dl"}
           ]

    assert File.dir?(dl)
    assert File.ls!(dl) == []
    link = Path.join(artifacts, "nerves_system_rpi4-1.30.0")
    assert {:ok, "/nerves-cache/artifacts/nerves_system_rpi4-1.30.0"} = File.read_link(link)
    # Removing the link (Nerves' fingerprint-mismatch path) leaves the cache untouched.
    File.rm_rf!(link)

    assert File.exists?(
             Path.join([
               dir,
               "nerves-cache",
               "artifacts",
               "nerves_system_rpi4-1.30.0",
               ".fingerprint"
             ])
           )
  end

  test "prepare creates the cache's artifacts dir when it is missing", %{dir: dir} do
    other = Path.join(dir, "fresh")
    config = %{Config.defaults() | data_dir: other, portal_url: "https://x"}
    %{artifacts_dir: artifacts} = NervesCache.prepare(config, Path.join(other, "work"))
    assert File.dir?(Path.join([other, "nerves-cache", "artifacts"]))
    assert File.ls!(artifacts) == []
  end

  test "misses are bounded and filtered by the portal's allowlist" do
    result = %{
      "nerves_cache" => %{
        "misses" => [
          miss("nerves_system_rpi4", "1.30.0"),
          miss("evil_system", "1.0.0"),
          miss("nerves_system_rpi4", "1.30.0"),
          miss("a", "1"),
          miss("b", "1"),
          miss("c", "1"),
          miss("d", "1")
        ]
      }
    }

    misses = NervesCache.misses(result)
    assert length(misses) == 4

    assert NervesCache.allowed(misses, ["nerves_system_rpi4", "a"]) == [
             %{name: "nerves_system_rpi4", version: "1.30.0"},
             %{name: "a", version: "1"}
           ]

    assert NervesCache.misses(%{}) == []
  end

  test "misses keep only string names and versions" do
    result = %{
      "nerves_cache" => %{
        "misses" => [
          %{"name" => 1, "version" => "1"},
          %{"name" => "x"},
          "junk",
          miss("ok", "2")
        ]
      }
    }

    assert NervesCache.misses(result) == [%{name: "ok", version: "2"}]
    assert NervesCache.misses(%{"nerves_cache" => %{"misses" => "nope"}}) == []
    assert NervesCache.misses(nil) == []
    assert NervesCache.allowed([%{name: "ok", version: "2"}], nil) == []
  end

  test "warm runs the worker read-write in warm_nerves mode only for allowed pairs", %{
    config: config,
    dir: dir
  } do
    argv_log = Path.join(dir, "argv.log")
    System.put_env("FAKE_DOCKER_ARGV_LOG", argv_log)
    System.put_env("FAKE_DOCKER_RESULT", ~s({"scope":"warm_nerves"}))
    config = %{config | docker_bin: @fake}
    evil = %{"nerves_cache" => %{"misses" => [miss("evil", "1")]}}

    assert :skipped = NervesCache.warm(config, claim(), evil)
    assert :skipped = NervesCache.warm(config, claim(), nil)
    refute File.exists?(argv_log)

    result = %{"nerves_cache" => %{"misses" => [miss("nerves_system_rpi4", "1.30.0")]}}
    assert :ok = NervesCache.warm(config, claim(), result, keep_scratch: true)
    argv = File.read!(argv_log)
    assert argv =~ "type=bind,source=#{Path.join(dir, "nerves-cache")},target=/nerves-cache\n"
    refute argv =~ "target=/nerves-cache,readonly"
    assert argv =~ "--read-only\n"
    assert argv =~ "ncc-rb-jason-1.4.4-1-warm\n"
    assert argv =~ "NERVES_ARTIFACTS_DIR=/work/nerves/artifacts\n"

    [input] =
      Path.join(dir, "scratch/*/work/input.json")
      |> Path.wildcard()
      |> Enum.map(&(&1 |> File.read!() |> Jason.decode!()))

    assert input["mode"] == "warm_nerves"
    assert input["nerves_packages"] == [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}]
    assert input["run_id"] == "rb-jason-1.4.4-1-warm"
    refute Map.has_key?(input, "systems_filter")
    refute Map.has_key?(input, "argus")
    assert [_] = Path.wildcard(Path.join(dir, "scratch/rb-jason-1.4.4-1-warm"))
  end

  test "warm removes its scratch and reports a failing exit", %{config: config, dir: dir} do
    System.put_env("FAKE_DOCKER_EXIT", "10")
    config = %{config | docker_bin: @fake}
    result = %{"nerves_cache" => %{"misses" => [miss("nerves_system_rpi4", "1.30.0")]}}

    assert {:error, {:exit, 10}} = NervesCache.warm(config, claim(), result)
    refute File.exists?(Path.join(dir, "scratch/rb-jason-1.4.4-1-warm"))
  end
end
