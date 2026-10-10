defmodule Portal.Catalog.TriageQueriesTest do
  use Portal.DataCase, async: false

  import Portal.Test.ArgusFixtures

  alias Portal.Catalog

  test "defaults list new and confirmed, errors first" do
    ingest("1.0.0", ok([finding(), finding(%{"severity" => "error", "detail" => "e"})]), 1)

    assert [%{triage: %{severity: "error"}}, %{triage: %{severity: "warning"}}] =
             Catalog.triage_list(%{})
  end

  test "status, severity, analysis and package filters" do
    info = finding(%{"severity" => "info", "analysis" => "mailbox", "detail" => "i"})
    ingest("1.0.0", ok([finding(), info]), 1)
    [%{triage: info_row}] = Catalog.triage_list(%{severity: ["info"]})
    Catalog.triage!(info_row.id, %{status: "false_positive", note: nil}, %{username: "alice"})

    assert [] = Catalog.triage_list(%{severity: ["info"]})
    assert [_] = Catalog.triage_list(%{status: [:false_positive]})
    assert [_] = Catalog.triage_list(%{analysis: "failure"})
    assert [_, _] = Catalog.triage_list(%{status: [:new, :false_positive], package: "ripk"})
    assert [] = Catalog.triage_list(%{package: "nope"})
  end

  test "a finding absent from the latest run is stale and hidden by default" do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "gone later"})]), 1)
    ingest("1.1.0", ok([finding()]), 2)

    assert [%{stale?: false}] = Catalog.triage_list(%{})
    assert [_, _] = all = Catalog.triage_list(%{include_stale: true})
    assert Enum.count(all, & &1.stale?) == 1
  end

  test "a newer run where argus did not run leaves findings current" do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("1.1.0", %{"status" => "skipped"}, 2)
    ingest("1.2.0", %{"status" => "error", "findings" => [], "error" => "timeout"}, 3)
    ingest("1.3.0", :absent, 4)

    assert [%{stale?: false}] = Catalog.triage_list(%{})
    assert Catalog.triage_counts().new == 1
  end

  test "the list is capped and reports the total" do
    ingest("1.0.0", ok(for(i <- 1..3, do: finding(%{"detail" => "d#{i}"}))), 1)
    assert {[_, _], 3} = Catalog.triage_page(%{}, 2)
  end

  test "counts ignore stale rows" do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "gone later"})]), 1)
    ingest("1.1.0", ok([finding()]), 2)

    assert Catalog.triage_counts() == %{
             new: 1,
             confirmed: 0,
             false_positive: 0,
             reported: 0,
             ignored: 0
           }
  end

  test "triage! records status, note and the admin" do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Catalog.triage_list(%{})

    updated =
      Catalog.triage!(row.id, %{status: "reported", note: "issue #12"}, %{username: "alice"})

    assert {updated.status, updated.note, updated.updated_by} == {:reported, "issue #12", "alice"}
  end
end
