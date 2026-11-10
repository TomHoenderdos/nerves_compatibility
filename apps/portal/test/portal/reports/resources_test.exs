defmodule Portal.Reports.ResourcesTest do
  use Portal.DataCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Portal.Reports.{Line, Report}
  alias Portal.Repo

  defp report!(attrs \\ %{}) do
    Report
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          payload_hash: String.duplicate("a", 64),
          format: 1,
          client: "0.4.0",
          elixir: "1.20.3",
          otp: 29,
          os_family: "unix",
          os_arch: "aarch64-apple-darwin",
          target: "host",
          lock: %{"entries" => []},
          hit_count: 1,
          miss_count: 1,
          fail_count: 0
        },
        attrs
      )
    )
    |> Ash.create!(domain: Portal.Reports)
  end

  defp line!(report, attrs \\ %{}) do
    Line
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          report_id: report.id,
          package: "jason",
          version: "1.4.5",
          status: :miss,
          reason_code: "not_built_version",
          reason_args: ["1.4.5"],
          reason: "not built for 1.4.5"
        },
        attrs
      )
    )
    |> Ash.create!(domain: Portal.Reports)
  end

  test "a report starts seen once, received now" do
    report = report!()
    assert report.seen_count == 1
    assert DateTime.diff(DateTime.utc_now(), report.received_at, :second) < 5
  end

  test "deleting a report deletes its lines" do
    report = report!()
    line!(report)
    line!(report, %{package: "telemetry", version: "1.3.0"})

    Ash.destroy!(report, domain: Portal.Reports)

    assert Repo.one(from(l in "precompiled_report_lines", select: count())) == 0
  end

  test "a line is only miss or fail" do
    report = report!()
    assert_raise Ash.Error.Invalid, fn -> line!(report, %{status: :hit}) end
  end

  test "the indexes the analysis and dedup queries use exist" do
    names =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename LIKE 'precompiled_report%'").rows
      |> List.flatten()

    assert "precompiled_report_lines_package_version_reason_code_index" in names
    assert "precompiled_reports_received_at_index" in names
    assert "precompiled_reports_payload_hash_received_at_index" in names
    assert "precompiled_report_lines_report_id_index" in names
    assert "precompiled_report_quotas_unique_key_day_index" in names
  end
end
