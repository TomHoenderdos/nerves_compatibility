defmodule Portal.Reports.Summary do
  @moduledoc """
  Miss reports grouped for analysis, until an admin page shows them. Call it
  on the serving release:

      ops/portal-rpc.sh 'Portal.Reports.Summary.by_package() |> IO.inspect(limit: :infinity)'
      ops/portal-rpc.sh 'Portal.Reports.Summary.by_client(since: ~U[2026-11-01 00:00:00Z]) |> IO.inspect()'
      ops/portal-rpc.sh 'Portal.Reports.Summary.by_target(limit: 20) |> IO.inspect()'
      ops/portal-rpc.sh 'Portal.Reports.Summary.storage() |> IO.inspect()'

  Each row carries its group (`package, version, reason_code`,
  `client, reason_code` or `target, otp, reason_code`), `count` (lines),
  `reports` and `reporters` (distinct; a report whose reporter key retention
  cleared counts no reporter), `first_seen` and `last_seen` (when the reports
  arrived), and the requeue state of its lines: `queued`, `skipped` (any
  `skipped:*`) and `open` (undecided, or never a requeue candidate). Rows come
  most lines first, then most recently seen. Options: `:since` (a
  `DateTime`, reports received from then on; default 30 days back) and
  `:limit` (default 100 rows).

  `storage/0` is the size check. `lock` dominates a report row (up to 1000
  entries of about 100 bytes, so about 100 KiB at worst). The global intake
  limits (300 accepted reports an hour, 2000 a day) bound the growth, and
  deleting reports after 365 days (`Portal.Workers.LogRetention`) bounds the
  total.
  """

  import Ecto.Query

  alias Portal.Repo

  @default_days 30
  @default_limit 100

  @doc "Rows and on-disk bytes (indexes and TOAST included) of the report tables."
  @spec storage() :: %{
          reports: %{rows: non_neg_integer(), bytes: non_neg_integer()},
          lines: %{rows: non_neg_integer(), bytes: non_neg_integer()}
        }
  def storage do
    %{rows: [[reports, report_bytes, lines, line_bytes]]} =
      Repo.query!("""
      SELECT (SELECT count(*) FROM precompiled_reports),
             pg_total_relation_size('precompiled_reports'),
             (SELECT count(*) FROM precompiled_report_lines),
             pg_total_relation_size('precompiled_report_lines')
      """)

    %{
      reports: %{rows: reports, bytes: report_bytes},
      lines: %{rows: lines, bytes: line_bytes}
    }
  end

  @doc "Grouped by package, version and reason code."
  @spec by_package(keyword()) :: [map()]
  def by_package(opts \\ []) do
    opts
    |> base()
    |> group_by([line: l], [l.package, l.version, l.reason_code])
    |> select([line: l], %{package: l.package, version: l.version, reason_code: l.reason_code})
    |> stats()
  end

  @doc "Grouped by client version and reason code: does a class go away after a release?"
  @spec by_client(keyword()) :: [map()]
  def by_client(opts \\ []) do
    opts
    |> base()
    |> group_by([report: r, line: l], [r.client, l.reason_code])
    |> select([report: r, line: l], %{client: r.client, reason_code: l.reason_code})
    |> stats()
  end

  @doc "Grouped by Mix target, OTP major and reason code."
  @spec by_target(keyword()) :: [map()]
  def by_target(opts \\ []) do
    opts
    |> base()
    |> group_by([report: r, line: l], [r.target, r.otp, l.reason_code])
    |> select([report: r, line: l], %{target: r.target, otp: r.otp, reason_code: l.reason_code})
    |> stats()
  end

  defp base(opts) do
    since =
      Keyword.get_lazy(opts, :since, fn ->
        DateTime.add(DateTime.utc_now(), -@default_days * 86_400, :second)
      end)

    from(l in "precompiled_report_lines",
      as: :line,
      join: r in "precompiled_reports",
      as: :report,
      on: r.id == l.report_id,
      where: r.received_at >= ^since,
      limit: ^Keyword.get(opts, :limit, @default_limit)
    )
  end

  defp stats(query) do
    query
    |> select_merge([line: l, report: r], %{
      count: count(l.id),
      reports: count(r.id, :distinct),
      reporters: count(r.reporter_key, :distinct),
      first_seen: type(min(r.received_at), :utc_datetime_usec),
      last_seen: type(max(r.received_at), :utc_datetime_usec),
      queued: filter(count(l.id), l.requeue == "queued"),
      skipped: filter(count(l.id), like(l.requeue, "skipped:%")),
      open: filter(count(l.id), is_nil(l.requeue))
    })
    |> order_by([line: l, report: r], desc: count(l.id), desc: max(r.received_at))
    |> Repo.all()
  end
end
