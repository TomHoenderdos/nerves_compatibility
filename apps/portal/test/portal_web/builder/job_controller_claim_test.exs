defmodule PortalWeb.Builder.JobControllerClaimTest do
  use PortalWeb.BuilderConnCase, async: false

  alias Portal.Builders.{Lease, Leases}

  defp queued!(package \\ "jason") do
    {:ok, lease} =
      Leases.enqueue(%{
        package: package,
        version: "1.4.4",
        image_name: "ghcr.io/x/ncc-worker",
        image_digest: "sha256:#{String.duplicate("b", 64)}",
        args: %{"mode" => nil, "systems_filter" => nil, "argus" => nil},
        scan_request_id: nil,
        priority: 5
      })

    lease
  end

  @claim %{"agent_version" => "1.a", "free_slots" => 1, "egress" => "ok"}

  test "claim hands out the lease with the worker input and caps", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c1")
    lease = queued!()
    body = conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> json_response(200)
    assert body["lease_id"] == lease.id
    assert body["run_id"] =~ ~r/^rb-jason-1\.4\.4-\d+$/

    assert body["image"] == %{
             "name" => "ghcr.io/x/ncc-worker",
             "digest" => "sha256:" <> String.duplicate("b", 64)
           }

    assert body["input"]["package"] == %{
             "name" => "jason",
             "version" => "1.4.4",
             "source" => "hex"
           }

    assert body["input"]["run_id"] == body["run_id"]
    assert body["input"]["paths"]["files_dir"] == "/files"
    assert body["timeout_sec"] == 7200
    assert body["upload"]["max_files"] == 20_000
    assert body["egress_required"] == true
    assert is_list(body["warm_allowlist"])
  end

  test "nothing to do is 204 and a short poll returns quickly", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c2")
    Application.put_env(:portal, Portal.Builders.Leases, long_poll_ms: 50)
    on_exit(fn -> Application.delete_env(:portal, Portal.Builders.Leases) end)
    assert conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> response(204)
  end

  test "a missing egress ruleset is refused and recorded", %{conn: conn} do
    %{builder: builder, cert_der: der} = enrolled_builder!("c3")
    queued!()

    assert conn
           |> with_cert(der)
           |> post("/builder/v1/jobs/claim", %{@claim | "egress" => "missing"})
           |> json_response(409) == %{"error" => "egress_missing"}

    {:ok, b} = Portal.Builders.get_builder(builder.id)
    assert b.egress_status == "missing"
    assert [%Lease{state: :queued}] = Ash.read!(Lease, domain: Portal.Builders)
  end

  test "heartbeat updates the lease and refuses another builder", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("c4")
    %{cert_der: other} = enrolled_builder!("c5")
    queued!()

    %{"lease_id" => id} =
      conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> json_response(200)

    assert conn
           |> with_cert(der)
           |> post("/builder/v1/jobs/#{id}/heartbeat", %{
             "phase" => "building",
             "log_tail" => "compiling"
           })
           |> json_response(200) == %{"ok" => true}

    assert Ash.get!(Lease, id, domain: Portal.Builders).log_tail == "compiling"

    assert conn
           |> with_cert(other)
           |> post("/builder/v1/jobs/#{id}/heartbeat", %{"phase" => "building"})
           |> json_response(409) == %{"error" => "lease_not_held"}
  end
end
