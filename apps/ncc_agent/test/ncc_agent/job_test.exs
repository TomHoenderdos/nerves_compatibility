defmodule NccAgent.JobTest do
  use ExUnit.Case, async: false

  # Failed chowns (not root here), timeouts, crashes and refused updates are logged.
  @moduletag :capture_log

  alias NccAgent.{Config, Identity, Job}
  alias NccAgent.Test.{CA, FakePortal}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_EXIT FAKE_DOCKER_RESULT FAKE_DOCKER_ARGV_LOG FAKE_DOCKER_FILE_CONTENT
          FAKE_DOCKER_IMAGE_PRESENT FAKE_DOCKER_SLEEP FAKE_DOCKER_PLANT FAKE_DOCKER_RESULT_LINK
          FAKE_DOCKER_OUTPUT_BYTES FAKE_DOCKER_CONTAINER_PRESENT FAKE_DOCKER_DOWN
          FAKE_DOCKER_HEX_TARBALL FAKE_DOCKER_HEX_LABEL)
  @lease "5b0c8a8e-1111-4c2d-9e3f-0a1b2c3d4e5f"
  @digest "sha256:" <> String.duplicate("a", 64)
  @content "the archived artifact"

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-job-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))
    %{url: url, script: script} = FakePortal.start(ca, self(), %{})

    config = %{
      Config.defaults()
      | portal_url: url,
        data_dir: Path.join(dir, "data"),
        enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}",
        docker_bin: @fake,
        build_user: "4242:4242",
        cpus: "2",
        memory: "4g"
    }

    Config.put(config)
    {:ok, req} = Identity.ensure()

    argv_log = Path.join(dir, "argv.log")
    System.put_env("FAKE_DOCKER_ARGV_LOG", argv_log)
    System.put_env("FAKE_DOCKER_FILE_CONTENT", @content)
    # A current worker image; the tests about older ones unset it.
    System.put_env("FAKE_DOCKER_HEX_LABEL", "seeded")
    System.put_env("FAKE_DOCKER_RESULT", ~s({"status":"pass","nerves_cache":{"misses":[]}}))

    # Retries back off by nothing here.
    Application.put_env(:ncc_agent, :retry_ms, 0)

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      Application.delete_env(:ncc_agent, :caps)
      Application.delete_env(:ncc_agent, :retry_ms)
      File.rm_rf(dir)
    end)

    flush()
    %{req: req, config: config, argv_log: argv_log, script: script, dir: dir}
  end

  defp claim do
    %{
      "lease_id" => @lease,
      "run_id" => "rb-jason-1.4.4-1",
      "image" => %{"name" => "ghcr.io/x/ncc-worker", "digest" => @digest},
      "input" => %{
        "run_id" => "rb-jason-1.4.4-1",
        "image" => %{"name" => "ghcr.io/x/ncc-worker", "digest" => @digest},
        "package" => %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
        "paths" => %{"work_dir" => "/work", "output_dir" => "/out", "files_dir" => "/files"}
      },
      "timeout_sec" => 60,
      "upload" => %{
        "max_file_bytes" => 1_000_000,
        "max_total_bytes" => 10_000_000,
        "max_batch_bytes" => 1_000_000,
        "max_files" => 100
      }
    }
  end

  test "a passing run uploads the missing file and completes with the result", %{
    req: req,
    config: config,
    argv_log: argv_log
  } do
    sha = :crypto.hash(:sha256, @content) |> Base.encode16(case: :lower)

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"phase" => "pulling"},
                     _}

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> rest, %{"shas" => [^sha]}, _}

    assert String.ends_with?(rest, "/files/missing")

    assert_received {:portal_request, "PUT", "/builder/v1/jobs/" <> _,
                     %{"names" => [^sha], "content_type" => "application/x-tar"}, _}

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> complete, params, _}
                    when is_map_key(params, "exit_code")

    assert String.ends_with?(complete, "/complete")
    assert params["exit_code"] == "0"
    assert {"result.json", result} = params["result"]
    assert Jason.decode!(result)["status"] == "pass"
    assert {"logs.tar.gz", logs} = params["logs"]
    assert {:ok, [~c"host.log"]} = :erl_tar.table({:binary, logs}, [:compressed])
    assert {"runner.log", runner_log} = params["runner_log"]
    assert runner_log =~ "fake build output"

    refute File.exists?(Path.join(Config.path(config, :scratch), "rb-jason-1.4.4-1"))

    argv = argv_log |> File.read!() |> String.split("\n", trim: true)
    assert "--read-only" in argv

    data = config.data_dir

    assert "type=bind,source=#{data}/nerves-cache,target=/nerves-cache,readonly" in argv

    assert "4242:4242" ==
             argv |> Enum.drop_while(&(&1 != "--user")) |> Enum.at(1)

    # Never a build cache: a remote builder has no promotion.
    refute Enum.any?(argv, &String.contains?(&1, "build-cache"))
    assert List.last(argv) == "ghcr.io/x/ncc-worker@" <> @digest
    # Exactly one container ran: the portal named nothing to warm.
    assert Enum.count(argv, &(&1 == "run")) == 1

    # The image was absent, so it was pulled first.
    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"phase" => "building"},
                     _}
  end

  test "a failing run completes with its exit code and uploads nothing", %{
    req: req,
    config: config
  } do
    System.put_env("FAKE_DOCKER_EXIT", "10")

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "10"
    refute_received {:portal_request, "PUT", _, _, _}
    refute_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"shas" => _}, _}
    refute File.exists?(Path.join(Config.path(config, :scratch), "rb-jason-1.4.4-1"))
  end

  test "the worker sees input.json exactly as the portal sent it", %{
    req: req,
    config: config,
    dir: dir
  } do
    # A fake that copies input.json out before the scratch dir goes.
    copy = Path.join(dir, "input-copy.json")
    wrapper = Path.join(dir, "docker.sh")

    File.write!(wrapper, """
    #!/usr/bin/env bash
    if [ "$1" = "run" ]; then
      for arg in "$@"; do
        case "$arg" in
          *target=/work) src="${arg#*source=}"; cp "${src%%,*}/input.json" "#{copy}" ;;
        esac
      done
    fi
    exec "#{@fake}" "$@"
    """)

    File.chmod!(wrapper, 0o755)

    assert {:ok, :done} = Job.run(req, claim(), %{config | docker_bin: wrapper})

    input = copy |> File.read!() |> Jason.decode!()
    assert input == claim()["input"]
  end

  test "a done completion that names pairs runs a read-write warm container", %{
    req: req,
    config: config,
    argv_log: argv_log,
    script: script
  } do
    pairs = [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}, %{"name" => "evil"}]
    Agent.update(script, &Map.put(&1, :warm, pairs))

    assert {:ok, :done} = Job.run(req, claim(), config)

    argv = argv_log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(argv, &(&1 == "run")) == 2
    data = config.data_dir
    assert "type=bind,source=#{data}/nerves-cache,target=/nerves-cache,readonly" in argv
    assert "type=bind,source=#{data}/nerves-cache,target=/nerves-cache" in argv
    assert "ncc-rb-jason-1.4.4-1-warm" in argv
    refute File.exists?(Path.join(Config.path(config, :scratch), "rb-jason-1.4.4-1-warm"))
  end

  test "a failing run is never followed by a warm, whatever the portal says", %{
    req: req,
    config: config,
    argv_log: argv_log,
    script: script
  } do
    Agent.update(
      script,
      &Map.put(&1, :warm, [%{"name" => "nerves_system_rpi4", "version" => "1.30.0"}])
    )

    System.put_env("FAKE_DOCKER_EXIT", "10")

    assert {:ok, :done} = Job.run(req, claim(), config)

    argv = argv_log |> File.read!() |> String.split("\n", trim: true)
    assert Enum.count(argv, &(&1 == "run")) == 1
  end

  # A CLI that died or detached leaves the container running; nothing it
  # wrote is read then, since it could swap a file for a symlink mid-read.
  test "a container still present after the run completes with 20 and reads nothing", %{
    req: req,
    config: config
  } do
    System.put_env("FAKE_DOCKER_CONTAINER_PRESENT", "1")

    assert {:ok, :done} = Job.run(req, claim(), config)

    params = complete_params()
    assert params["exit_code"] == "20"
    refute Map.has_key?(params, "result")
    refute Map.has_key?(params, "logs")
    refute_received {:portal_request, "PUT", _, _, _}
    refute_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"shas" => _}, _}
    refute File.exists?(Path.join(Config.path(config, :scratch), "rb-jason-1.4.4-1"))
  end

  test "a daemon that cannot be asked is not a container that is gone", %{
    req: req,
    config: config
  } do
    System.put_env("FAKE_DOCKER_DOWN", "1")

    assert {:ok, :done} = Job.run(req, claim(), config)

    params = complete_params()
    assert params["exit_code"] == "20"
    refute Map.has_key?(params, "result")
  end

  test "each slot has a Hex cache of its own", %{config: config} do
    assert Config.path(Map.put(config, :slot, 2), :hex_cache) ==
             Path.join([config.data_dir, "hex-cache", "slot-2"])

    assert Config.path(config, :hex_cache) == Path.join(config.data_dir, "hex-cache")
  end

  # Sizes are the container's doing; what is over the claim's caps is never
  # tarred (a sparse file would be written dense) nor sent for the portal
  # to refuse.
  test "a file over the claim's size caps is left behind", %{req: req, config: config} do
    claim = put_in(claim(), ["upload", "max_file_bytes"], 5)
    assert {:ok, :done} = Job.run(req, claim, config)
    assert complete_params()["exit_code"] == "0"
    refute_received {:portal_request, "PUT", _, _, _}
    refute_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"shas" => _}, _}

    claim = put_in(claim(), ["upload", "max_total_bytes"], 5)
    assert {:ok, :done} = Job.run(req, claim, config)
    refute_received {:portal_request, "PUT", _, _, _}
  end

  test "logs past the count cap are left out of logs.tar.gz", %{req: req, config: config} do
    Application.put_env(:ncc_agent, :caps, max_logs: 0)

    assert {:ok, :done} = Job.run(req, claim(), config)

    params = complete_params()
    assert params["exit_code"] == "0"
    refute Map.has_key?(params, "logs")
  end

  # A build mounts the Hex cache read-write and could leave a hex.config or
  # a registry snapshot for every later build to trust.
  test "the shared Hex cache is scrubbed of hex.config and cache.ets before a run", %{
    req: req,
    config: config
  } do
    hex = Config.path(config, :hex_cache)
    File.mkdir_p!(Path.join(hex, "packages/hexpm"))
    File.write!(Path.join(hex, "hex.config"), "planted")
    File.write!(Path.join(hex, "cache.ets"), "planted")
    File.write!(Path.join(hex, "packages/hexpm/jason-1.4.4.tar"), "kept")

    assert {:ok, :done} = Job.run(req, claim(), config)

    refute File.exists?(Path.join(hex, "hex.config"))
    refute File.exists?(Path.join(hex, "cache.ets"))
    assert File.exists?(Path.join(hex, "packages/hexpm/jason-1.4.4.tar"))
  end

  describe "Hex cache mount" do
    defp run_argv(req, config, argv_log) do
      assert {:ok, _} = Job.run(req, claim(), config)
      argv_log |> File.read!() |> String.split("\n", trim: true)
    end

    test "a seeded image gets the read-only mount", %{
      req: req,
      config: config,
      argv_log: argv_log
    } do
      hex = Config.path(config, :hex_cache)
      argv = run_argv(req, config, argv_log)

      assert "type=bind,source=#{hex},target=/hex-cache,readonly" in argv
      refute "NCC_HEX_CACHE_RW=1" in argv
    end

    # A lease keeps the image it was created with, so an updated agent can
    # be handed one from before the seeded HEX_HOME. Its worker writes
    # /hex-cache itself and would fail every deps.get on a read-only mount.
    test "an image without the label keeps the read-write mount and no env", %{
      req: req,
      config: config,
      argv_log: argv_log
    } do
      System.delete_env("FAKE_DOCKER_HEX_LABEL")
      hex = Config.path(config, :hex_cache)
      argv = run_argv(req, config, argv_log)

      assert "type=bind,source=#{hex},target=/hex-cache" in argv
      refute "type=bind,source=#{hex},target=/hex-cache,readonly" in argv
      refute "NCC_HEX_CACHE_RW=1" in argv
    end

    test "NCC_HEX_CACHE_RW=1 is the rollback here too", %{
      req: req,
      config: config,
      argv_log: argv_log
    } do
      hex = Config.path(config, :hex_cache)
      argv = run_argv(req, Map.put(config, :hex_cache_rw, true), argv_log)

      assert "type=bind,source=#{hex},target=/hex-cache" in argv
      assert "NCC_HEX_CACHE_RW=1" in argv
    end
  end

  # The cache is read-only in the container; after a done run the agent
  # promotes what it downloaded, checked against Hex.pm (`Compatibility.HexCache`).
  describe "Hex cache promotion" do
    setup do
      on_exit(fn -> Application.delete_env(:ncc_agent, NccAgent.HexCache) end)

      System.put_env("FAKE_DOCKER_HEX_TARBALL", "jason tarball")

      System.put_env(
        "FAKE_DOCKER_RESULT",
        ~s({"status":"pass","hex_cache":{"misses":[{"name":"jason","version":"1.4.4"}]}})
      )

      :ok
    end

    defp hex_sha, do: :crypto.hash(:sha256, "jason tarball") |> Base.encode16(case: :lower)

    test "a done run's verified download lands in the slot's cache", %{
      req: req,
      config: config
    } do
      Application.put_env(:ncc_agent, NccAgent.HexCache,
        release_checksum: fn "jason", "1.4.4" -> {:ok, hex_sha()} end
      )

      assert {:ok, :done} = Job.run(req, claim(), config)

      assert File.read!(
               Path.join(Config.path(config, :hex_cache), "packages/hexpm/jason-1.4.4.tar")
             ) == "jason tarball"
    end

    test "nothing is promoted that Hex.pm does not vouch for, or from a failed run", %{
      req: req,
      config: config
    } do
      tarball = Path.join(Config.path(config, :hex_cache), "packages/hexpm/jason-1.4.4.tar")

      Application.put_env(:ncc_agent, NccAgent.HexCache,
        release_checksum: fn _, _ -> {:ok, String.duplicate("0", 64)} end
      )

      assert {:ok, :done} = Job.run(req, claim(), config)
      refute File.exists?(tarball)

      Application.put_env(:ncc_agent, NccAgent.HexCache,
        release_checksum: fn _, _ -> {:ok, hex_sha()} end
      )

      System.put_env("FAKE_DOCKER_EXIT", "10")
      assert {:ok, _} = Job.run(req, claim(), config)
      refute File.exists?(tarball)
    end
  end

  test "a timeout completes the lease with exit code 20", %{req: req, config: config} do
    System.put_env("FAKE_DOCKER_SLEEP", "1")
    System.put_env("FAKE_DOCKER_IMAGE_PRESENT", "1")

    assert {:ok, :done} = Job.run(req, Map.put(claim(), "timeout_sec", 0), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "20"
  end

  test "a crash still completes with exit 20 and removes the scratch dir", %{
    req: req,
    config: config
  } do
    # No image map: building the image ref raises.
    claim = Map.delete(claim(), "image")

    assert {:ok, :done} = Job.run(req, claim, config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "20"
    refute File.exists?(Path.join(Config.path(config, :scratch), "rb-jason-1.4.4-1"))
  end

  test "symlinks and non-sha names in files/ are not uploaded", %{req: req, config: config} do
    System.put_env("FAKE_DOCKER_PLANT", "1")
    sha = :crypto.hash(:sha256, @content) |> Base.encode16(case: :lower)

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"shas" => shas}, _}
    assert shas == [sha]

    assert_received {:portal_request, "PUT", "/builder/v1/jobs/" <> _, %{"names" => [^sha]}, _}
  end

  test "a symlinked result.json is missing: the run completes with 20", %{
    req: req,
    config: config,
    dir: dir
  } do
    secret = Path.join(dir, "host-secret.json")
    File.write!(secret, ~s({"status":"pass"}))
    System.put_env("FAKE_DOCKER_RESULT_LINK", secret)

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "20"
    refute Map.has_key?(params, "result")
    refute_received {:portal_request, "PUT", _, _, _}
  end

  test "a result.json over the cap is not read: the run completes with 20", %{
    req: req,
    config: config
  } do
    Application.put_env(:ncc_agent, :caps, result_json_bytes: 10)

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "20"
    refute Map.has_key?(params, "result")
  end

  test "a log over the cap is left out of logs.tar.gz", %{req: req, config: config} do
    Application.put_env(:ncc_agent, :caps, log_bytes: 5)

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    assert params["exit_code"] == "0"
    assert {"result.json", _} = params["result"]
    refute Map.has_key?(params, "logs")
  end

  test "argv_spec/3 is the read-only post-isolation spec without a build cache", %{
    config: config
  } do
    dirs = %{work: "/s/work", out: "/s/out", files: "/s/files", tmp: "/s/tmp", cache: "/s/cache"}
    spec = Job.argv_spec(config, claim(), dirs)

    assert spec.image == "ghcr.io/x/ncc-worker@" <> @digest
    assert spec.container_name == "ncc-rb-jason-1.4.4-1"
    assert spec.user == "4242:4242"
    assert spec.nerves_cache_mode == :readonly
    assert spec.paths.build_cache == nil
    assert spec.paths.tmp == "/s/tmp"
    assert spec.paths.cache == "/s/cache"
    assert spec.paths.nerves_cache == Config.path(config, :nerves_cache)
    assert spec.paths.hex_cache == Config.path(config, :hex_cache)

    local = put_in(claim(), ["image", "name"], "ncc-worker:local")
    assert Job.argv_spec(config, local, dirs).image == "ncc-worker:local"
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp complete_params do
    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, _}
                    when is_map_key(params, "exit_code")

    params
  end

  defp puts do
    receive do
      {:portal_request, "PUT", _, _, _} -> 1 + puts()
    after
      0 -> 0
    end
  end

  # `Ingestion` skips an absent blob without a word: a pass whose files did
  # not all upload must not complete as one.
  test "a batch the portal never stores completes the run with 20", %{
    req: req,
    config: config,
    script: script
  } do
    Agent.update(script, &Map.put(&1, :upload_error, {503, %{error: "unavailable"}}))

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert complete_params()["exit_code"] == "20"
    assert puts() == 3
  end

  test "a batch that fails once is retried and the run passes", %{
    req: req,
    config: config,
    script: script
  } do
    Agent.update(script, &Map.put(&1, :upload_failures, 1))

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert complete_params()["exit_code"] == "0"
    assert puts() == 2
  end

  test "a batch refused as not held is not retried and completes with 20", %{
    req: req,
    config: config,
    script: script
  } do
    Agent.update(script, &Map.put(&1, :upload_error, {409, %{error: "lease_not_held"}}))

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert complete_params()["exit_code"] == "20"
    assert puts() == 1
  end

  # The portal reads only the last 1 MiB of it, and a whole 64 MiB log would
  # push `complete` past its multipart limit.
  test "a runner.log over the cap yields a runner_log part of at most 1 MiB, its tail", %{
    req: req,
    config: config
  } do
    System.put_env("FAKE_DOCKER_OUTPUT_BYTES", Integer.to_string(1536 * 1024))

    assert {:ok, :done} = Job.run(req, claim(), config)

    assert {"runner.log", runner_log} = complete_params()["runner_log"]
    assert byte_size(runner_log) <= 1024 * 1024
    assert String.ends_with?(runner_log, "fake build output\n")
  end

  test "a logs.tar.gz over its cap is left out of complete", %{req: req, config: config} do
    Application.put_env(:ncc_agent, :caps, logs_tarball_bytes: 10)

    assert {:ok, :done} = Job.run(req, claim(), config)

    params = complete_params()
    assert params["exit_code"] == "0"
    assert {"result.json", _} = params["result"]
    refute Map.has_key?(params, "logs")
  end
end
