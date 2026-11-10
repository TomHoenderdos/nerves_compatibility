defmodule Portal.Workers.LogRetentionReportsTest do
  use Portal.DataCase, async: false

  import Ecto.Query, only: [from: 2]
  import Portal.Test.ReportFixtures

  alias Portal.Repo
  alias Portal.Workers.LogRetention

  defp days_ago(n), do: DateTime.add(DateTime.utc_now(), -n * 86_400)

  defp report_at(days, target) do
    record!(%{"contact" => "@someone", "target" => target},
      now: days_ago(days),
      reporter_key: "key-#{target}"
    )
  end

  defp row(id) do
    Repo.one(
      from(r in "precompiled_reports",
        where: r.id == type(^id, Ecto.UUID),
        select: %{contact: r.contact, key: r.reporter_key}
      )
    )
  end

  test "contact and reporter key go after 90 days, the report after 365" do
    fresh = report_at(10, "fresh")
    aged = report_at(91, "aged")
    old = report_at(366, "old")

    report = LogRetention.run()

    assert row(fresh) == %{contact: "@someone", key: "key-fresh"}
    assert row(aged) == %{contact: nil, key: nil}
    assert row(old) == nil
    # `old` is past both windows: it is nulled by the anonymise rule (it still
    # has a contact and key at that point) and then deleted by the retention
    # rule, so it counts in both tallies.
    assert report.report_contacts.count == 2
    assert report.reports.count == 1

    lines =
      Repo.one(
        from(l in "precompiled_report_lines",
          where: l.report_id == type(^old, Ecto.UUID),
          select: count()
        )
      )

    assert lines == 0
  end

  test "both windows are configurable, and a dry run changes nothing" do
    aged = report_at(31, "aged")

    report = LogRetention.run(report_anonymise_days: 30, report_retention_days: 60, dry_run: true)
    assert report.report_contacts.count == 1
    assert row(aged).contact == "@someone"

    LogRetention.run(report_anonymise_days: 30, report_retention_days: 30)
    assert row(aged) == nil
  end
end
