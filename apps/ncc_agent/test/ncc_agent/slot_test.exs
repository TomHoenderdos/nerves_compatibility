defmodule NccAgent.SlotTest do
  use ExUnit.Case, async: false

  # Failed chowns (not root here) and hand-backs are logged.
  @moduletag :capture_log

  alias NccAgent.{Config, Identity, Slot, Updater}
  alias NccAgent.Test.{CA, FakePortal, Release}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @lease "5b0c8a8e-2222-4c2d-9e3f-0a1b2c3d4e5f"
  @env ~w(FAKE_DOCKER_IMAGE_PRESENT FAKE_DOCKER_SLEEP FAKE_DOCKER_KILL_LOG FAKE_DOCKER_ARGV_LOG)

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-slot-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))
    {tarball, sha} = Release.tarball(dir)

    %{url: url, script: script} =
      FakePortal.start(ca, self(), %{releases: %{"agent-x.tar.gz" => tarball}})

    config = %{
      Config.defaults()
      | portal_url: url,
        data_dir: Path.join(dir, "data"),
        enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}",
        docker_bin: @fake
    }

    Config.put(config)
    {:ok, _req} = Identity.ensure()
    System.put_env("FAKE_DOCKER_IMAGE_PRESENT", "1")
    System.put_env("FAKE_DOCKER_ARGV_LOG", Path.join(dir, "argv.log"))
    System.put_env("FAKE_DOCKER_KILL_LOG", Path.join(dir, "kills.log"))

    on_exit(fn ->
      Enum.each(@env, &System.delete_env/1)
      Application.delete_env(:ncc_agent, :updater_opts)
      Updater.clear_updating()
      File.rm_rf(dir)
    end)

    flush()
    %{dir: dir, url: url, sha: sha, ca: ca, script: script}
  end

  defp claim do
    %{
      "lease_id" => @lease,
      "run_id" => "rb-jason-1.4.4-2",
      "image" => %{
        "name" => "ncc-worker:local",
        "digest" => "sha256:" <> String.duplicate("b", 64)
      },
      "input" => %{"run_id" => "rb-jason-1.4.4-2", "paths" => %{}},
      "timeout_sec" => 60,
      "upload" => %{"max_batch_bytes" => 1_000_000, "max_files" => 10},
      "warm_allowlist" => []
    }
  end

  defp script_claim(script, claim), do: Agent.update(script, &Map.put(&1, :claims, [claim]))

  test "a slot claims, runs the job, completes it and claims again", %{script: script} do
    script_claim(script, claim())
    start_supervised!({Slot, 1})

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/claim", %{"egress" => "ok"}, _},
                   5_000

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"exit_code" => "0"}, _},
                   10_000

    # The scripted claim is used up: the next claim gets a 204.
    assert_receive {:portal_request, "POST", "/builder/v1/jobs/claim", _, _}, 5_000
  end

  test "stopping a slot mid-job kills the container and hands the lease back", %{
    script: script,
    dir: dir
  } do
    System.put_env("FAKE_DOCKER_SLEEP", "1")
    script_claim(script, claim())
    start_supervised!({Slot, 1})

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"phase" => "building"},
                    _},
                   5_000

    # Give the fake its moment to start the "container".
    Process.sleep(200)
    :ok = stop_supervised({Slot, 1})

    assert File.read!(Path.join(dir, "kills.log")) == "ncc-rb-jason-1.4.4-2\n"

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"exit_code" => "20"}, _}
  end

  test "a claim that brings an update is handed back and no slot claims again", %{
    script: script,
    url: url,
    sha: sha,
    ca: ca,
    dir: dir
  } do
    test_pid = self()

    Application.put_env(:ncc_agent, :updater_opts,
      current: "1700000000.abc",
      stop_fun: fn -> send(test_pid, :stopped) end,
      stop_delay_ms: 0,
      req_options: [connect_options: [transport_opts: [cacertfile: Path.join(ca.dir, "ca.pem")]]]
    )

    release = %{"url" => url <> "/releases/agent-x.tar.gz", "sha256" => sha}

    claim =
      Map.merge(claim(), %{
        "min_agent_version" => "1800000000.def",
        "agent_releases" => %{Release.arch() => release}
      })

    script_claim(script, claim)
    start_supervised!({Slot, 1})

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/claim", _, _}, 5_000

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"exit_code" => "20"}, _},
                   5_000

    assert_receive :stopped, 1_000
    refute File.exists?(Path.join(dir, "argv.log"))
    refute_receive {:portal_request, "POST", "/builder/v1/jobs/claim", _, _}, 300
  end

  test "while an update is pending a slot does not claim" do
    :persistent_term.put({Updater, :updating}, "1800000000.def")
    start_supervised!({Slot, 1})
    refute_receive {:portal_request, "POST", "/builder/v1/jobs/claim", _, _}, 300
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
