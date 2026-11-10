defmodule Portal.Reports.SummaryTest do
  use Portal.DataCase, async: true

  import Ecto.Query, only: [from: 2]
  import Portal.Test.ReportFixtures

  alias Portal.Reports.Summary
  alias Portal.Repo

  setup do
    miss = &line(&1, "1.0.0", "miss", "not_built_version", ["1.0.0"])

    a =
      record!(
        %{
          "lines" => [miss.("alpha"), miss.("beta")],
          "client" => "0.4.0",
          "target" => "rpi4",
          "otp" => 29
        },
        reporter_key: "r1"
      )

    b =
      record!(
        %{"lines" => [miss.("alpha")], "client" => "0.4.1", "target" => "host", "otp" => 28},
        reporter_key: "r2"
      )

    _c =
      record!(
        %{
          "lines" => [miss.("alpha")],
          "client" => "0.4.1",
          "target" => "host",
          "otp" => 28,
          "elixir" => "1.19.5"
        },
        reporter_key: "r2"
      )

    Repo.update_all(
      from(l in "precompiled_report_lines",
        where: l.report_id == type(^a, Ecto.UUID) and l.package == "alpha"
      ),
      set: [requeue: "queued"]
    )

    Repo.update_all(
      from(l in "precompiled_report_lines", where: l.report_id == type(^b, Ecto.UUID)),
      set: [requeue: "skipped:cap"]
    )

    :ok
  end

  test "by package: counts, distinct reports and reporters, requeue state" do
    [alpha, beta] = Summary.by_package()

    assert %{
             package: "alpha",
             version: "1.0.0",
             reason_code: "not_built_version",
             count: 3,
             reports: 3,
             reporters: 2
           } = alpha

    assert {alpha.queued, alpha.skipped, alpha.open} == {1, 1, 1}
    assert %{package: "beta", count: 1} = beta
    assert DateTime.compare(alpha.first_seen, alpha.last_seen) in [:lt, :eq]
  end

  test "by client version" do
    rows = Summary.by_client() |> Enum.map(&{&1.client, &1.count}) |> Enum.sort()
    assert rows == [{"0.4.0", 2}, {"0.4.1", 2}]
  end

  test "by target and OTP" do
    rows = Summary.by_target() |> Enum.map(&{&1.target, &1.otp, &1.count}) |> Enum.sort()
    assert rows == [{"host", 28, 2}, {"rpi4", 29, 2}]
  end

  test "a report without a reporter key counts no reporter" do
    record!(%{"lines" => [line("gamma", "1.0.0", "miss", "not_built_version", [])]})
    Repo.update_all("precompiled_reports", set: [reporter_key: nil])

    assert [%{package: "gamma", reports: 1, reporters: 0, open: 1}] =
             Enum.filter(Summary.by_package(), &(&1.package == "gamma"))
  end

  test "storage reports rows and bytes of both tables" do
    %{reports: reports, lines: lines} = Summary.storage()
    assert reports.rows == 3 and lines.rows == 4
    assert reports.bytes > 0 and lines.bytes > 0
  end

  test "since and limit narrow the result" do
    assert Summary.by_package(since: DateTime.add(DateTime.utc_now(), 60)) == []
    assert [_] = Summary.by_package(limit: 1)
  end
end
