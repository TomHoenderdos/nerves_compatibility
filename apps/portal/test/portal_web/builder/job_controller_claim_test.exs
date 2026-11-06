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
    refute Map.has_key?(body, "warm_allowlist")
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

  @amd "sha256:" <> String.duplicate("1", 64)
  @arm "sha256:" <> String.duplicate("2", 64)

  defp images!(platforms) do
    path = Path.join(System.tmp_dir!(), "images-#{System.unique_integer([:positive])}.json")
    previous = Application.get_env(:portal, Portal.Builders.Images, [])

    File.write!(
      path,
      Jason.encode!(%{
        "commit" => "c",
        "images" => %{
          "ncc-worker" => %{
            "name" => "ghcr.io/x/ncc-worker",
            "digest" => @amd,
            "platforms" => platforms
          }
        }
      })
    )

    Application.put_env(:portal, Portal.Builders.Images, Keyword.put(previous, :path, path))

    on_exit(fn ->
      Application.put_env(:portal, Portal.Builders.Images, previous)
      File.rm(path)
    end)
  end

  defp queued_multiarch!(platforms) do
    {:ok, lease} =
      Leases.enqueue(%{
        package: "jason",
        version: "1.4.4",
        image_name: "ghcr.io/x/ncc-worker",
        image_digest: @amd,
        args: %{"image_platforms" => platforms},
        scan_request_id: nil,
        priority: 5
      })

    lease
  end

  test "an arm64 agent gets the arm64 platform digest, in the image and the input",
       %{conn: conn} do
    images!(%{"x86_64" => @amd, "aarch64" => @arm})
    %{builder: builder, cert_der: der} = enrolled_builder!("arm1")
    lease = queued_multiarch!(%{"x86_64" => @amd, "aarch64" => @arm})

    body =
      conn
      |> with_cert(der)
      |> post("/builder/v1/jobs/claim", Map.put(@claim, "arch", "aarch64"))
      |> json_response(200)

    assert body["lease_id"] == lease.id
    assert body["image"] == %{"name" => "ghcr.io/x/ncc-worker", "digest" => @arm}
    assert body["input"]["image"]["digest"] == @arm
    assert Ash.get!(Lease, lease.id, domain: Portal.Builders).image_digest == @arm

    {:ok, b} = Portal.Builders.get_builder(builder.id)
    assert b.arch == "aarch64"
  end

  test "an agent whose architecture has no image claims nothing and is told why",
       %{conn: conn} do
    images!(%{"x86_64" => @amd})
    %{builder: builder, cert_der: der} = enrolled_builder!("arm2")
    queued_multiarch!(%{"x86_64" => @amd})

    assert conn
           |> with_cert(der)
           |> post("/builder/v1/jobs/claim", Map.put(@claim, "arch", "aarch64"))
           |> json_response(409) == %{"error" => "no_image_for_arch", "arch" => "aarch64"}

    assert [%Lease{state: :queued}] = Ash.read!(Lease, domain: Portal.Builders)
    {:ok, b} = Portal.Builders.get_builder(builder.id)
    assert b.arch == "aarch64"
  end

  # Every agent from before multi-arch images runs on x86_64 and says nothing.
  test "an agent that names no architecture is x86_64", %{conn: conn} do
    images!(%{"x86_64" => @amd, "aarch64" => @arm})
    %{builder: builder, cert_der: der} = enrolled_builder!("old1")
    queued_multiarch!(%{"x86_64" => @amd, "aarch64" => @arm})

    body = conn |> with_cert(der) |> post("/builder/v1/jobs/claim", @claim) |> json_response(200)
    assert body["image"]["digest"] == @amd

    {:ok, b} = Portal.Builders.get_builder(builder.id)
    assert b.arch == "x86_64"
  end

  test "a malformed architecture is refused", %{conn: conn} do
    %{cert_der: der} = enrolled_builder!("bad1")
    queued!()

    for arch <- ["../x", String.duplicate("a", 40), 7, ""] do
      assert conn
             |> with_cert(der)
             |> post("/builder/v1/jobs/claim", Map.put(@claim, "arch", arch))
             |> json_response(400) == %{"error" => "bad_arch"}
    end

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
