defmodule Portal.ScanRequests.AdminPagesTest do
  use Portal.DataCase, async: false

  import Portal.PackageListingFixtures

  alias Portal.ScanRequests

  describe "admin pages" do
    test "queue pages have stable ordering when submission timestamps tie" do
      now = DateTime.utc_now()
      accepted = for i <- 1..50, do: request_fixture("accepted_#{i}", %{inserted_at: now})
      queued = request_fixture("queued", %{status: :queued, inserted_at: now})
      request_fixture("pending", %{status: :pending})
      request_fixture("built", %{status: :built})
      request_fixture("rejected", %{status: :rejected})

      first = ScanRequests.queue_page()
      second = ScanRequests.queue_page("2")

      assert first.total == 51
      assert length(first.entries) == 50
      assert length(second.entries) == 1

      expected_ids = accepted |> Enum.map(& &1.id) |> Enum.concat([queued.id]) |> Enum.sort()
      assert Enum.map(first.entries ++ second.entries, & &1.id) == expected_ids
    end

    test "review pages only include pending anonymous manual submissions" do
      pending = request_fixture("pending", %{status: :pending})
      request_fixture("accepted")
      request_fixture("other_source", %{source: :hex_owner, status: :pending})

      assert %{entries: [entry], total: 1, page: 1, total_pages: 1} =
               ScanRequests.pending_anonymous_page(999)

      assert entry.id == pending.id
    end

    test "empty lists have an empty first page even for stale page URLs" do
      assert %{entries: [], total: 0, page: 1, total_pages: 1} = ScanRequests.queue_page(2)

      assert %{entries: [], total: 0, page: 1, total_pages: 1} =
               ScanRequests.pending_anonymous_page("invalid")
    end
  end
end
