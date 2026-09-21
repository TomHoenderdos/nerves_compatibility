defmodule Portal.ScanRequests.QueuePlaceholdersTest do
  use Portal.DataCase, async: false

  import Portal.PackageListingFixtures

  alias Portal.ScanRequests

  test "limits sorted names, counts distinct packages, and links to the oldest request" do
    now = DateTime.utc_now()
    request_fixture("zebra", %{status: :queued})
    request_fixture("alpha", %{inserted_at: now})
    oldest = request_fixture("alpha", %{inserted_at: DateTime.add(now, -60)})
    request_fixture("catalogued")
    request_fixture("unapproved", %{status: :pending})
    request_fixture("finished", %{status: :built})

    assert %{entries: [%{id: id, package_name: "alpha"}], count: 2} =
             ScanRequests.queue_placeholders("", ["catalogued"], 1)

    assert id == oldest.id
  end

  test "search treats SQL wildcard characters as literal text" do
    request_fixture("has_under")
    request_fixture("hasXunder")
    request_fixture("has%percent")
    request_fixture("hasXpercent")

    assert %{entries: [%{package_name: "has_under"}], count: 1} =
             ScanRequests.queue_placeholders("_", [], 60)

    assert %{entries: [%{package_name: "has%percent"}], count: 1} =
             ScanRequests.queue_placeholders("%", [], 60)

    assert %{entries: [], count: 0} = ScanRequests.queue_placeholders("absent", [], 60)
  end
end
