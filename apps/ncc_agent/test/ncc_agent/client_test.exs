defmodule NccAgent.ClientTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Client, Config, Identity}
  alias NccAgent.Test.{CA, FakePortal}

  @lease "5b0c8a8e-1111-4c2d-9e3f-0a1b2c3d4e5f"

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-client-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))

    script = %{claims: [%{"lease_id" => @lease, "run_id" => "r1"}], missing: ["aa", "cc"]}
    %{url: url, script: agent} = FakePortal.start(ca, self(), script)

    config = %{
      Config.defaults()
      | portal_url: url,
        data_dir: Path.join(dir, "data"),
        enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}"
    }

    Config.put(config)
    {:ok, req} = Identity.ensure()
    on_exit(fn -> File.rm_rf(dir) end)

    # Drop the enrolment's messages so each test sees only its own requests.
    flush()
    %{req: req, dir: dir, script: agent, config: config}
  end

  test "claim returns the scripted claim, then :none on 204", %{req: req} do
    assert {:ok, %{"lease_id" => @lease}} = Client.claim(req, 1, "ok")

    assert_received {:portal_request, "POST", "/builder/v1/jobs/claim",
                     %{"free_slots" => 1, "egress" => "ok", "agent_version" => _}, fp}
                    when is_binary(fp)

    assert :none = Client.claim(req, 1, "ok")
  end

  test "claim maps 409 egress_missing", %{req: req, script: script} do
    Agent.update(script, &Map.put(&1, :claim_error, {409, %{error: "egress_missing"}}))
    assert {:error, :egress_missing} = Client.claim(req, 1, "missing")
  end

  test "missing returns the scripted list", %{req: req} do
    assert {:ok, ["aa", "cc"]} = Client.missing(req, @lease, ["aa", "bb", "cc"])

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _,
                     %{"shas" => ["aa", "bb", "cc"]}, fp}
                    when is_binary(fp)
  end

  test "heartbeat and status succeed", %{req: req} do
    assert :ok = Client.heartbeat(req, @lease, "building", "line\n")

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _,
                     %{"phase" => "building", "log_tail" => "line\n"}, _}

    assert :ok = Client.status(req, "ok", 2)

    assert_received {:portal_request, "POST", "/builder/v1/status",
                     %{"egress" => "ok", "free_slots" => 2}, _}
  end

  test "upload streams a tar and reports what was stored", %{req: req, dir: dir, script: script} do
    tar = Path.join(dir, "batch.tar")

    :ok =
      :erl_tar.create(String.to_charlist(tar), [
        {~c"aaaa", String.duplicate("a", 300_000)},
        {~c"bbbb", "b"}
      ])

    assert {:ok, %{"stored" => ["aaaa", "bbbb"], "bad" => []}} = Client.upload(req, @lease, tar)

    assert_received {:portal_request, "PUT", "/builder/v1/jobs/" <> _,
                     %{"names" => ["aaaa", "bbbb"], "content_type" => "application/x-tar"}, fp}
                    when is_binary(fp)

    Agent.update(script, &Map.put(&1, :upload_bad, ["bbbb"]))
    assert {:error, {:bad_entries, ["bbbb"]}} = Client.upload(req, @lease, tar)
  end

  test "complete sends the exit code and the parts it has", %{req: req, dir: dir} do
    result = Path.join(dir, "result.json")
    File.write!(result, ~s({"status":"pass"}))

    assert {:ok, %{"accepted" => true}} = Client.complete(req, @lease, 0, %{result: result})

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, params, fp}
                    when is_binary(fp)

    assert params["exit_code"] == "0"
    assert params["result"] == {"result.json", ~s({"status":"pass"})}
    refute Map.has_key?(params, "logs")
    refute Map.has_key?(params, "runner_log")
  end

  test "every request carries the client certificate and the agent version", %{req: req} do
    {:ok, _} = Client.claim(req, 1, "ok")
    {:ok, _} = Client.missing(req, @lease, ["aa"])
    expected = NccAgent.Version.current()
    assert_received {:portal_agent_version, "POST", "/builder/v1/jobs/claim", ^expected}
    assert_received {:portal_agent_version, "POST", "/builder/v1/jobs/" <> _, ^expected}
  end

  test "enrolment and the CA fetch carry the agent version too", %{config: config, dir: dir} do
    # A fresh data dir enrols again.
    Config.put(%{config | data_dir: Path.join(dir, "data2")})
    {:ok, _} = Identity.ensure()
    expected = NccAgent.Version.current()
    assert_received {:portal_agent_version, "GET", "/builder/v1/ca.pem", ^expected}
    assert_received {:portal_agent_version, "POST", "/builder/v1/enroll", ^expected}
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end
end
