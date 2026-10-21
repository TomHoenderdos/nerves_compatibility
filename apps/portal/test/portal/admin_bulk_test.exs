defmodule Portal.AdminBulkTest do
  use Portal.DataCase, async: false
  require Ash.Query

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "1.0.0"}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)

    {:ok, admin} = Portal.Accounts.seed_admin_user("bulk_admin", "correct horse battery staple")
    %{admin: admin}
  end

  defp pending(name) do
    {:ok, r} =
      Portal.ScanRequests.create_once(%{
        package_name: name,
        source: :anonymous_manual,
        status: :pending,
        subject: "anonymous",
        verification_provider: "manual_review"
      })

    r
  end

  defp selected(ids), do: Portal.ScanRequests.ScanRequest |> Ash.Query.filter(id in ^ids)

  defp priority(request), do: Portal.Admin.queue_positions([request.id])[request.id].priority

  test "bulk reject processes every request and reports the ones it could not", %{admin: admin} do
    a = pending("bulk_a")
    b = pending("bulk_b")
    {:ok, _} = Portal.ScanRequests.reject_anonymous_request(b.id, admin)

    assert {:ok, %{ok: 1, failed: [{id, :not_pending_anonymous}]}} =
             Portal.Admin.bulk_reject(selected([a.id, b.id]), actor: admin)

    assert id == b.id
    assert {:ok, %{status: :rejected}} = Portal.ScanRequests.get_request(a.id)
  end

  test "bulk approve queues each pending request through the single-request path",
       %{admin: admin} do
    a = pending("bulk_ok_a")
    b = pending("bulk_ok_b")

    assert {:ok, %{ok: 2, failed: []}} =
             Portal.Admin.bulk_approve(selected([a.id, b.id]), actor: admin)

    for r <- [a, b] do
      assert {:ok, %{status: :queued}} = Portal.ScanRequests.get_request(r.id)
      # The build job each approval makes is what gives the row a position.
      assert %{priority: 3} = Portal.Admin.queue_positions([r.id])[r.id]
    end
  end

  test "a refusal in the middle does not stop the requests after it", %{admin: admin} do
    {:ok, a} = Portal.Admin.queue_package("bulk_move_a", admin)
    {:ok, b} = Portal.Admin.queue_package("bulk_move_b", admin)

    # Both start at priority 0, the top: moving up refuses both, moving down
    # moves both.
    assert {:ok, %{ok: 0, failed: failed}} =
             Portal.Admin.bulk_move_up(selected([a.id, b.id]), actor: admin)

    assert Enum.sort(failed) == Enum.sort([{a.id, :already_at_limit}, {b.id, :already_at_limit}])

    assert {:ok, %{ok: 2, failed: []}} =
             Portal.Admin.bulk_move_down(selected([a.id, b.id]), actor: admin)

    assert priority(a) == 1 and priority(b) == 1

    assert {:ok, %{ok: 2, failed: []}} =
             Portal.Admin.bulk_move_up(selected([a.id, b.id]), actor: admin)

    assert priority(a) == 0 and priority(b) == 0
  end

  test "a request with no build job is reported, not raised", %{admin: admin} do
    a = pending("bulk_no_job")

    assert {:ok, %{ok: 0, failed: [{id, :no_job}]}} =
             Portal.Admin.bulk_move_down(selected([a.id]), actor: admin)

    assert id == a.id
  end

  describe "queue_position calculation" do
    test "equals Portal.Admin.queue_positions/1", %{admin: admin} do
      {:ok, a} = Portal.Admin.queue_package("calc_a", admin)
      {:ok, b} = Portal.Admin.queue_package("calc_b", admin)
      {:ok, 1} = Portal.Admin.reprioritise(b.id, :down)
      waiting = pending("calc_pending")

      loaded =
        selected([a.id, b.id, waiting.id])
        |> Ash.Query.load(:queue_position)
        |> Ash.read!(domain: Portal.ScanRequests)
        |> Map.new(&{&1.id, &1.queue_position})

      expected = Portal.Admin.queue_positions([a.id, b.id, waiting.id])

      assert loaded[a.id] == expected[a.id]
      assert loaded[b.id] == expected[b.id]
      assert %{priority: 1, adjustable?: true} = loaded[b.id]
      # No build job, no position: the same absence the map has.
      assert loaded[waiting.id] == nil
      refute Map.has_key?(expected, waiting.id)
    end
  end
end
