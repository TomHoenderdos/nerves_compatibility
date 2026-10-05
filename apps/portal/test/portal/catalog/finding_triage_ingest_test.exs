defmodule Portal.Catalog.FindingTriageIngestTest do
  use Portal.DataCase, async: false

  import Portal.Test.ArgusFixtures

  alias Portal.Catalog.FindingTriage

  defp rows, do: Ash.read!(FindingTriage, domain: Portal.Catalog)

  test "an ok run creates one new row per finding" do
    run = ingest("1.0.0", ok([finding(), finding(%{"detail" => "P.A.other/1"})]), 1)

    assert [_, _] = rows = rows()
    assert Enum.all?(rows, &(&1.status == :new and &1.package_name == "tripkg"))
    assert Enum.all?(rows, &(&1.first_seen_version == "1.0.0" and &1.last_seen_run_id == run.id))
  end

  test "a later run moves last_seen and keeps the admin's status" do
    ingest("1.0.0", ok([finding()]), 1)
    [row] = rows()

    row
    |> Ash.Changeset.for_update(:triage, %{status: :confirmed, note: "real", updated_by: "tom"})
    |> Ash.update!(domain: Portal.Catalog)

    run2 = ingest("1.1.0", ok([finding(%{"line" => 42})]), 2)

    assert [row] = rows()
    assert row.status == :confirmed
    assert row.note == "real"
    assert row.updated_by == "tom"
    assert row.first_seen_version == "1.0.0"
    assert row.last_seen_version == "1.1.0"
    assert row.last_seen_run_id == run2.id
    assert row.line == 42
  end

  test "the same finding twice in one run is one row" do
    ingest("1.0.0", ok([finding(), finding(%{"line" => 99})]), 1)
    assert [_] = rows()
  end

  test "all sightings of a run are written in one statement" do
    ref = :telemetry_test.attach_event_handlers(self(), [[:portal, :repo, :query]])

    ingest("1.0.0", ok(for(i <- 1..5, do: finding(%{"detail" => "d#{i}"}))), 1)

    inserts =
      Stream.repeatedly(fn ->
        receive do
          {[:portal, :repo, :query], ^ref, _measurements, %{query: query}} -> query
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
      |> Enum.count(&String.contains?(&1, ~s(INSERT INTO "catalog_finding_triage")))

    assert inserts == 1
    assert length(rows()) == 5
  end

  test "error, skipped and absent argus record nothing" do
    ingest("1.0.0", %{"status" => "error", "findings" => [], "error" => "x"}, 1)
    ingest("1.0.1", %{"status" => "skipped"}, 2)
    ingest("1.0.2", :absent, 3)
    assert rows() == []
  end

  test "malformed findings are skipped and the run still ingests" do
    bad = [
      "not a map",
      finding(%{"title" => %{"x" => 1}}),
      finding(%{"severity" => nil}),
      Map.delete(finding(), "analysis")
    ]

    assert %{id: _} = ingest("1.0.0", ok([finding() | bad]), 1)
    assert [_] = rows()
  end
end
