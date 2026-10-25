defmodule NccAgent.JobTest do
  use ExUnit.Case, async: false

  # Failed chowns (not root here), timeouts, crashes and refused updates are logged.
  @moduletag :capture_log

  alias NccAgent.{Config, Identity, Job}
  alias NccAgent.Test.{CA, FakePortal}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @env ~w(FAKE_DOCKER_EXIT FAKE_DOCKER_RESULT FAKE_DOCKER_ARGV_LOG FAKE_DOCKER_FILE_CONTENT
          FAKE_DOCKER_IMAGE_PRESENT FAKE_DOCKER_SLEEP FAKE_DOCKER_PLANT FAKE_DOCKER_RESULT_LINK)
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
    System.put_env("FAKE_DOCKER_RESULT", ~s({"status":"pass","nerves_cache":{"misses":[]}}))

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      Application.delete_env(:ncc_agent, :caps)
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
      },
      "warm_allowlist" => []
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

    assert "NERVES_ARTIFACTS_DIR=/work/nerves/artifacts" in argv
    assert "NERVES_DL_DIR=/work/nerves/dl" in argv
    assert List.last(argv) == "ghcr.io/x/ncc-worker@" <> @digest

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

  test "the worker sees input.json with the Nerves paths", %{req: req, config: config, dir: dir} do
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
    assert input["package"]["name"] == "jason"
    assert input["paths"]["nerves_artifacts_dir"] == "/work/nerves/artifacts"
    assert input["paths"]["nerves_dl_dir"] == "/work/nerves/dl"
    assert input["paths"]["work_dir"] == "/work"
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

  test "argv_spec/4 is the read-only, hardened spec without a build cache", %{config: config} do
    dirs = %{work: "/s/work", out: "/s/out", files: "/s/files", tmp: "/s/tmp", cache: "/s/cache"}
    env = [{"NERVES_DL_DIR", "/work/nerves/dl"}]
    spec = Job.argv_spec(config, claim(), dirs, env)

    assert spec.image == "ghcr.io/x/ncc-worker@" <> @digest
    assert spec.nerves_cache_mode == :readonly
    assert spec.hardening == true
    assert spec.build_cache == nil
    assert spec.extra_env == env
    assert spec.tmp_dir == "/s/tmp"
    assert spec.cache_dir == "/s/cache"

    local = put_in(claim(), ["image", "name"], "ncc-worker:local")
    assert Job.argv_spec(config, local, dirs, env).image == "ncc-worker:local"
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
