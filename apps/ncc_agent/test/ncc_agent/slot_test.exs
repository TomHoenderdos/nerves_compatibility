defmodule NccAgent.SlotTest do
  use ExUnit.Case, async: false

  # Failed chowns are logged (not root here).
  @moduletag :capture_log

  alias NccAgent.{Config, Identity, Slot}
  alias NccAgent.Test.{CA, FakePortal}

  @fake Path.expand("../support/fake_docker.sh", __DIR__)
  @lease "5b0c8a8e-2222-4c2d-9e3f-0a1b2c3d4e5f"

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-slot-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))

    claim = %{
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

    %{url: url} = FakePortal.start(ca, self(), %{claims: [claim]})

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

    on_exit(fn ->
      System.delete_env("FAKE_DOCKER_IMAGE_PRESENT")
      File.rm_rf(dir)
    end)

    :ok
  end

  test "a slot claims, runs the job, completes it and claims again" do
    start_supervised!({Slot, 1})

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/claim", %{"egress" => "ok"}, _},
                   5_000

    assert_receive {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"exit_code" => "0"}, _},
                   10_000

    # The scripted claim is used up: the next claim gets a 204.
    assert_receive {:portal_request, "POST", "/builder/v1/jobs/claim", _, _}, 5_000
  end
end
