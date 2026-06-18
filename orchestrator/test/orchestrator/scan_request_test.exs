defmodule Orchestrator.ScanRequestTest do
  use ExUnit.Case, async: false

  alias Orchestrator.{Queue, ScanRequest}

  setup do
    Application.stop(:orchestrator)

    queue_file = Path.join(System.tmp_dir!(), "test_scan_queue_#{:rand.uniform(100_000)}.dets")

    checked_file =
      Path.join(System.tmp_dir!(), "test_scan_checked_#{:rand.uniform(100_000)}.dets")

    Application.put_env(:orchestrator, :queue_file, queue_file)
    Application.put_env(:orchestrator, :checked_file, checked_file)

    {:ok, pid} = Queue.start_link([])

    on_exit(fn ->
      if Process.alive?(pid), do: GenServer.stop(pid)
      File.rm_rf(queue_file)
      File.rm_rf(checked_file)
    end)

    :ok
  end

  test "accepts an anonymous request with a Turnstile human check" do
    assert {:ok, request} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :anonymous_turnstile,
               verified?: true,
               verification_provider: "cloudflare_turnstile"
             })

    assert request.source == :anonymous_turnstile
    assert [{_, %{priority: :anonymous, source: :anonymous_turnstile}}] = Queue.list_entries()
  end

  test "rejects anonymous requests without a human check" do
    assert {:error, :human_check_required} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :anonymous_turnstile
             })

    assert Queue.list() == []
  end

  test "rejects client-asserted Turnstile checks without server verification" do
    assert {:error, :human_check_required} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :anonymous_turnstile,
               human_check: :turnstile
             })

    assert Queue.list() == []
  end

  test "rejects unverified Hex owner requests" do
    assert {:error, :not_verified} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :hex_owner
             })

    assert Queue.list() == []
  end

  test "verified Hex owner requests get highest priority" do
    assert {:ok, _request} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :hex_owner,
               verified?: true,
               subject: "owner"
             })

    assert [{_, %{priority: :hex_owner, source: :hex_owner}}] = Queue.list_entries()
  end

  test "verified GitHub requests get GitHub priority" do
    assert {:ok, _request} =
             ScanRequest.submit(%{
               package: "jason",
               version: "1.4.4",
               source: :github_repo,
               verified?: true,
               subject: "maintainer"
             })

    assert [{_, %{priority: :github_repo, source: :github_repo}}] = Queue.list_entries()
  end
end
