defmodule Portal.Catalog.ArgusExportTest do
  use Portal.DataCase, async: false

  import Portal.Test.ArgusFixtures

  alias Portal.Catalog

  defp export(opts \\ []), do: opts |> Catalog.argus_export() |> Enum.to_list()

  test "latest scope gives one line per package: its newest ok argus run" do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("1.1.0", ok([finding(), finding(%{"detail" => "new in 1.1"})]), 2)
    ingest("1.2.0", %{"status" => "skipped"}, 3)
    ingest("2.0.0", ok([]), 1, "otherpkg")

    lines = export()

    assert Enum.map(lines, &{&1["package"], &1["package_version"]}) ==
             [{"otherpkg", "2.0.0"}, {"tripkg", "1.1.0"}]

    [_, tripkg] = lines
    assert tripkg["argus"]["status"] == "ok"
    assert tripkg["argus"]["version"] == "0.20.1"
    assert length(tripkg["findings"]) == 2
    assert is_binary(tripkg["run_id"])
    assert is_binary(tripkg["finished_at"])
    refute Map.has_key?(tripkg["argus"], "findings")
  end

  test "a run without finished_at never counts as the latest" do
    ingest("1.0.0", ok([finding(%{"detail" => "from the unfinished run"})]), :unfinished)
    ingest("1.1.0", ok([finding()]), 2)

    assert [%{"package_version" => "1.1.0"}] = export()
    assert [%{stale?: false, triage: %{last_seen_version: "1.1.0"}}] = Catalog.triage_list(%{})
  end

  test "all scope includes every run with argus, failures too" do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("1.1.0", %{"status" => "error", "findings" => [], "error" => "timeout after 300s"}, 2)
    ingest("1.2.0", %{"status" => "skipped"}, 3)
    ingest("1.3.0", :absent, 4)

    lines = export(scope: :all)

    assert Enum.map(lines, &{&1["package_version"], &1["argus"]["status"]}) ==
             [{"1.0.0", "ok"}, {"1.1.0", "error"}, {"1.2.0", "skipped"}]

    assert Enum.at(lines, 1)["argus"]["error"] == "timeout after 300s"
  end

  test "findings carry their fingerprint and the admin's triage" do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Catalog.triage_list(%{})
    Catalog.triage!(row.id, %{status: "false_positive", note: "deliberate"}, %{username: "alice"})

    [%{"findings" => [f]}] = export()

    assert f["title"] == "Catch-all rescue swallows exceptions"
    assert f["fingerprint"] == row.fingerprint

    assert f["triage"] == %{
             "status" => "false_positive",
             "note" => "deliberate",
             "updated_by" => "alice"
           }
  end

  test "since keeps runs finished on or after that moment" do
    ingest("1.0.0", ok([finding()]), 1)
    ingest("1.1.0", ok([finding()]), 30)

    since = DateTime.add(~U[2026-10-01 10:00:00Z], 10, :hour)
    assert [%{"package_version" => "1.1.0"}] = export(scope: :all, since: since)
  end

  test "streams in batches without losing or repeating runs" do
    for n <- 1..7, do: ingest("1.0.#{n}", ok([finding()]), n)

    assert export(scope: :all, batch_size: 3) |> Enum.map(& &1["package_version"]) ==
             for(n <- 1..7, do: "1.0.#{n}")
  end
end
