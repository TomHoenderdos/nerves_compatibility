defmodule Portal.Reports do
  @moduledoc """
  Miss reports from the `precompiled` client: what a tester's build hit, missed
  and failed, sent with `mix precompiled.report` to
  `POST /api/precompiled/reports` (`PortalWeb.PrecompiledReportController`).

  A report is anonymous. The only trace of who sent it is `reporter_key`, an
  HMAC of the client's address (`reporter_key/2`), kept 90 days for the
  per-reporter requeue cap. Only MISS and FAIL lines are stored as rows; HIT
  lines only raise `hit_count`.
  """

  use Ash.Domain

  resources do
    resource(Portal.Reports.Report)
    resource(Portal.Reports.Line)
    resource(Portal.Reports.Quota)
  end

  import Ecto.Query, only: [from: 2]

  alias Portal.Reports.{Line, Payload, Report, Requeue}
  alias Portal.Repo
  alias Portal.Workers.ReportRequeue

  @dedup_seconds 24 * 3600

  @doc """
  Stores a validated report, or counts it again.

  The same report (`Payload.hash/1`) received within 24 hours is not stored
  twice: its `seen_count` goes up and the answer is `:duplicate`, without the
  id. The id is the capability to retract a report, so it goes only to the
  sender who created it, never to someone who sent the same report later.
  A transaction-scoped advisory lock on the hash makes two identical reports
  arriving at once agree on one row. `reporter_key` is `reporter_key/2`'s
  digest; the address itself is never stored. `:now` stands in for the clock.
  """
  @spec record(Payload.normalized(), String.t() | nil, keyword()) ::
          {:created, Ecto.UUID.t()} | :duplicate
  def record(payload, reporter_key, opts \\ []) do
    now = Keyword.get_lazy(opts, :now, &DateTime.utc_now/0)
    hash = Payload.hash(payload)

    {:ok, result} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtextextended($1, 0))", [hash])

        count_or_insert(payload, hash, reporter_key, now, duplicate_of(hash, now))
      end)

    result
  end

  # `retract/1` does not take the advisory lock, so the row `duplicate_of/2`
  # found may be gone when it is counted; the report is then stored anew.
  @doc false
  def count_or_insert(payload, hash, reporter_key, now, nil),
    do: {:created, insert(payload, hash, reporter_key, now)}

  def count_or_insert(payload, hash, reporter_key, now, id) do
    case Repo.update_all(
           from(r in "precompiled_reports", where: r.id == type(^id, Ecto.UUID)),
           inc: [seen_count: 1]
         ) do
      {1, _} -> :duplicate
      {0, _} -> count_or_insert(payload, hash, reporter_key, now, nil)
    end
  end

  defp duplicate_of(hash, now) do
    since = DateTime.add(now, -@dedup_seconds, :second)

    Repo.one(
      from(r in "precompiled_reports",
        where: r.payload_hash == ^hash and r.received_at > ^since and r.received_at <= ^now,
        order_by: [desc: r.received_at],
        limit: 1,
        select: type(r.id, Ecto.UUID)
      )
    )
  end

  defp insert(payload, hash, reporter_key, now) do
    count = fn status -> Enum.count(payload.lines, &(&1.status == status)) end

    report =
      Report
      |> Ash.Changeset.for_create(:create, %{
        received_at: now,
        built_at: payload.built_at,
        payload_hash: hash,
        format: payload.format,
        client: payload.client,
        elixir: payload.elixir,
        otp: payload.otp,
        os_family: payload.os.family,
        os_arch: payload.os.arch,
        target: payload.target,
        system: payload.system,
        system_version: payload.system_version,
        contact: payload.contact,
        reporter_key: reporter_key,
        lock: %{"entries" => payload.lock},
        hit_count: count.(:hit),
        miss_count: count.(:miss),
        fail_count: count.(:fail)
      })
      |> Ash.create!(domain: __MODULE__)

    rows =
      for l <- payload.lines, l.status in [:miss, :fail] do
        %{
          report_id: report.id,
          package: l.name,
          version: l.version,
          status: l.status,
          reason_code: l.reason_code,
          reason_args: l.reason_args,
          reason: l.reason
        }
      end

    if rows != [] do
      %Ash.BulkResult{status: :success} =
        Ash.bulk_create(rows, Line, :create,
          domain: __MODULE__,
          return_errors?: true,
          stop_on_error?: true
        )
    end

    # In the report's own transaction: a report stored with a not-built miss
    # always has its requeue job, and a rolled-back one never does.
    if Enum.any?(rows, &(&1.status == :miss and &1.reason_code in Requeue.codes())) do
      {:ok, _job} = Oban.insert(ReportRequeue.new(%{report_id: report.id}))
    end

    report.id
  end

  @doc """
  Deletes a report and, by cascade, its lines. The id is the capability: who
  holds it may retract it. An unknown or malformed id runs the same delete
  against a random id, so both answers take the same work.
  """
  @spec retract(term()) :: :ok | :not_found
  def retract(id) do
    uuid =
      case is_binary(id) && Ecto.UUID.cast(id) do
        {:ok, uuid} -> uuid
        _ -> Ecto.UUID.generate()
      end

    case Repo.delete_all(from(r in "precompiled_reports", where: r.id == type(^uuid, Ecto.UUID))) do
      {1, _} -> :ok
      {0, _} -> :not_found
    end
  end

  @doc """
  What a reporter is counted by for the requeue cap: an HMAC-SHA256 of the
  client's address (an IPv4 address, or an IPv6 /64 as
  `PortalWeb.Plugs.RateLimit.client_key/1` gives it) under a key derived from
  `secret_key_base`, truncated to 16 bytes, in hex. Not reversible without the
  secret.
  """
  @spec reporter_key(:inet.ip_address(), binary()) :: String.t()
  def reporter_key(ip, secret_key_base) do
    key =
      Plug.Crypto.KeyGenerator.generate(secret_key_base, "precompiled report reporter",
        length: 32
      )

    :hmac
    |> :crypto.mac(:sha256, key, ip |> :inet.ntoa() |> to_string())
    |> binary_part(0, 16)
    |> Base.encode16(case: :lower)
  end
end
