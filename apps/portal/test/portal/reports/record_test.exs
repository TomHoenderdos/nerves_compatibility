defmodule Portal.Reports.RecordTest do
  use Portal.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Portal.Test.ReportFixtures

  alias Portal.Reports
  alias Portal.Reports.Payload
  alias Portal.Repo

  defp payload(overrides \\ %{}) do
    {:ok, p} = Payload.validate(body(overrides))
    p
  end

  defp count(table), do: Repo.one(from(t in table, select: count()))

  test "a report stores only its MISS and FAIL lines and counts every status" do
    assert {:created, id} = Reports.record(payload(), "k1")

    [report] =
      Repo.all(
        from(r in "precompiled_reports",
          select: %{
            id: type(r.id, Ecto.UUID),
            hits: r.hit_count,
            misses: r.miss_count,
            fails: r.fail_count,
            seen: r.seen_count,
            key: r.reporter_key,
            lock: r.lock
          }
        )
      )

    assert report.id == id
    assert {report.hits, report.misses, report.fails, report.seen} == {1, 1, 1, 1}
    assert report.key == "k1"
    assert length(report.lock["entries"]) == 3

    statuses = Repo.all(from(l in "precompiled_report_lines", select: l.status)) |> Enum.sort()
    assert statuses == ["fail", "miss"]
  end

  test "a system ABI reason code is stored as itself, not as unknown" do
    l = line("circuits_gpio", "2.1.0", "miss", "needed_lib_missing", ["libssl.so.3"])
    assert {:created, _id} = Reports.record(payload(%{"lines" => [l]}), "k1")

    assert [{"needed_lib_missing", ["libssl.so.3"]}] =
             Repo.all(
               from(l in "precompiled_report_lines", select: {l.reason_code, l.reason_args})
             )
  end

  test "the same report within 24 hours is counted, not stored, and gets no id" do
    {:created, _id} = Reports.record(payload(), "k1")

    assert :duplicate =
             Reports.record(
               payload(%{"contact" => "@other", "built_at" => "2026-11-09T08:00:00Z"}),
               "k2"
             )

    assert count("precompiled_reports") == 1
    assert count("precompiled_report_lines") == 2
    assert Repo.one(from(r in "precompiled_reports", select: r.seen_count)) == 2
  end

  test "the same report with its lock in another order is a duplicate" do
    {:created, _id} = Reports.record(payload(), "k1")
    assert :duplicate = Reports.record(payload(%{"lock" => Enum.reverse(body()["lock"])}), "k1")
    assert count("precompiled_reports") == 1
  end

  test "a duplicate whose report was retracted meanwhile is stored anew" do
    {:created, id} = Reports.record(payload(), "k1")
    hash = Payload.hash(payload())
    now = DateTime.utc_now()

    # The row the duplicate check found is gone by the time it is counted.
    :ok = Reports.retract(id)

    assert {:created, new} = Reports.count_or_insert(payload(), hash, "k1", now, id)
    refute new == id
    assert count("precompiled_reports") == 1
    assert count("precompiled_report_lines") == 2
  end

  test "a different report within 24 hours is a new report" do
    {:created, id} = Reports.record(payload(), "k1")
    assert {:created, other} = Reports.record(payload(%{"target" => "rpi5"}), "k1")
    refute id == other
  end

  test "the same report after 24 hours is a new report" do
    then = DateTime.add(DateTime.utc_now(), -25 * 3600)
    {:created, old} = Reports.record(payload(), "k1", now: then)
    assert {:created, new} = Reports.record(payload(), "k1")
    refute old == new
  end

  test "a report without MISS or FAIL lines stores no line rows" do
    body = %{"lines" => [line("ash", "3.5.2", "hit", "hit", [])]}
    assert {:created, _id} = Reports.record(payload(body), nil)
    assert count("precompiled_report_lines") == 0
  end

  test "the fixture records a report and returns its id" do
    id = record!()
    assert Repo.one(from(r in "precompiled_reports", select: type(r.id, Ecto.UUID))) == id
  end

  test "retracting removes the report and its lines" do
    {:created, id} = Reports.record(payload(), "k1")
    assert :ok = Reports.retract(id)
    assert count("precompiled_reports") == 0
    assert count("precompiled_report_lines") == 0
  end

  test "retracting one report leaves the others" do
    {:created, id} = Reports.record(payload(), "k1")
    {:created, _other} = Reports.record(payload(%{"target" => "rpi5"}), "k1")
    assert :ok = Reports.retract(id)
    assert count("precompiled_reports") == 1
    assert count("precompiled_report_lines") == 2
  end

  test "an unknown or malformed id is not found" do
    assert :not_found = Reports.retract(Ecto.UUID.generate())
    assert :not_found = Reports.retract("not-a-uuid")
    assert :not_found = Reports.retract(nil)
    assert :not_found = Reports.retract(123)
  end

  test "the reporter key is a keyed hash of the address, not the address" do
    secret = String.duplicate("s", 64)
    key = Reports.reporter_key({203, 0, 113, 7}, secret)

    assert key =~ ~r/\A[0-9a-f]{32}\z/
    assert key == Reports.reporter_key({203, 0, 113, 7}, secret)
    refute key == Reports.reporter_key({203, 0, 113, 8}, secret)
    refute key == Reports.reporter_key({203, 0, 113, 7}, String.duplicate("t", 64))
    refute key =~ "203"
  end

  test "the reporter key takes an IPv6 /64" do
    secret = String.duplicate("s", 64)
    key = Reports.reporter_key({0x2001, 0xDB8, 0, 1, 0, 0, 0, 0}, secret)

    assert key =~ ~r/\A[0-9a-f]{32}\z/
    refute key == Reports.reporter_key({0x2001, 0xDB8, 0, 2, 0, 0, 0, 0}, secret)
  end
end
