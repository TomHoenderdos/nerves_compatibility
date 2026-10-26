defmodule Portal.Builders.Leases do
  @moduledoc """
  The remote job queue: `builder_leases` rows and their state machine.

  `queued → leased → uploading → done`, with `queued` re-entered on a failed
  attempt and `failed` after `max_attempts`. Claim is one `UPDATE ... FOR
  UPDATE SKIP LOCKED`, so two builders never hold the same lease and a
  builder never exceeds its `slots`. The claim long-poll wakes on the
  `builders:leases` broadcast `enqueue/1` sends, not on a database poll.
  """
  require Ash.Query
  require Logger
  import Ecto.Query, only: [from: 2]

  alias Portal.Builders.{Builder, Lease}
  alias Portal.Repo
  alias Portal.Workers.Progress

  @topic "builders:leases"
  @domain Portal.Builders
  @leased_silence_minutes 10
  @uploading_silence_minutes 60
  # The build's own 2 h wall clock, the agent's 30 minutes for `docker pull`
  # (`NccAgent.Docker`) and 30 minutes of slack: a lease held longer than
  # this while still `leased` is a hung attempt however it heartbeats.
  @lease_ceiling_minutes 180
  @log_tail_bytes 4096
  @phases ~w(pulling building uploading)
  @held [:leased, :uploading]
  @default_long_poll_ms 25_000
  @requeued_locally "requeued locally"

  @spec topic() :: String.t()
  def topic, do: @topic

  @spec subscribe() :: :ok | {:error, term()}
  def subscribe, do: Phoenix.PubSub.subscribe(Portal.PubSub, @topic)

  @doc "How long a claim waits for work before answering 204."
  @spec long_poll_ms() :: non_neg_integer()
  def long_poll_ms do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:long_poll_ms, @default_long_poll_ms)
  end

  @doc "The upload limits a claim hands the agent (`Portal.Builders.Upload` config)."
  @spec upload_caps() :: %{
          max_file_bytes: pos_integer(),
          max_total_bytes: pos_integer(),
          max_batch_bytes: pos_integer(),
          max_files: pos_integer()
        }
  def upload_caps do
    config = Application.get_env(:portal, Portal.Builders.Upload, [])

    %{
      max_file_bytes: Keyword.get(config, :max_file_bytes, 268_435_456),
      max_total_bytes: Keyword.get(config, :max_total_bytes, 2_147_483_648),
      max_batch_bytes: Keyword.get(config, :max_batch_bytes, 536_870_912),
      max_files: Keyword.get(config, :max_files, 20_000)
    }
  end

  @doc "Queue a lease and wake every waiting claim."
  @spec enqueue(map()) :: {:ok, Lease.t()} | {:error, term()}
  def enqueue(attrs) do
    with {:ok, lease} <-
           Lease
           |> Ash.Changeset.for_create(:create, Map.put(attrs, :state, :queued))
           |> Ash.create(domain: @domain) do
      notify_queued(lease)
      Portal.AdminEvents.broadcast(:builders)
      {:ok, lease}
    end
  end

  @doc """
  Take the next queued lease (lowest `priority`, then oldest) for `builder`.
  `SKIP LOCKED` keeps two claimants off the same row. The slot check sits in
  the claim's `WHERE`, and a per-builder advisory lock taken first, in its own
  statement, serialises one builder's claims: without it two concurrent
  claims from the same builder would both count the same held leases in
  their snapshot and both take one. The claim is still one `UPDATE`, and it
  starts the attempt clean (log tail and error of the last one gone).
  `bytes_uploaded` is kept: a requeued lease keeps its upload dir and what
  landed there counts against the lease's total across attempts, so the cap
  is per lease, not per attempt; `fail/2` and `requeue/1` zero it with the dir.
  """
  @spec claim(Builder.t()) :: {:ok, Lease.t()} | :none
  # `sql` is a literal; every value is a bound parameter.
  # sobelow_skip ["SQL.Query"]
  def claim(%Builder{id: builder_id, slots: slots}) do
    ms = System.system_time(:millisecond)

    sql = """
    UPDATE builder_leases
    SET state = 'leased', builder_id = $1, leased_at = now(), heartbeat_at = now(),
        attempt = attempt + 1, phase = NULL, log_tail = NULL,
        error = NULL, run_id = 'rb-' || package || '-' || version || '-' || $3::text,
        updated_at = now()
    WHERE id = (
      SELECT id FROM builder_leases
      WHERE state = 'queued'
      ORDER BY priority ASC, inserted_at ASC
      LIMIT 1
      FOR UPDATE SKIP LOCKED)
    AND (SELECT count(*) FROM builder_leases
         WHERE builder_id = $1 AND state IN ('leased', 'uploading')) < $2
    RETURNING id
    """

    {:ok, rows} =
      Repo.transaction(fn ->
        Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [builder_id])

        Repo.query!(sql, [Ecto.UUID.dump!(builder_id), slots, Integer.to_string(ms)]).rows
      end)

    case rows do
      [[id]] ->
        lease = Ash.get!(Lease, Ecto.UUID.load!(id), domain: @domain)
        Portal.AdminEvents.broadcast(:builders)
        {:ok, lease}

      [] ->
        :none
    end
  end

  @doc """
  `claim/1`, and when nothing is queued wait up to `timeout_ms` for one
  `enqueue/1` broadcast and claim once more. Wake-ups left in the mailbox are
  drained before returning, so a long-lived caller does not accumulate them.
  """
  @spec claim_or_wait(Builder.t(), non_neg_integer()) :: {:ok, Lease.t()} | :none
  def claim_or_wait(builder, timeout_ms) do
    # Subscribed before the first claim, so a lease queued between the two is
    # either claimed outright or wakes the wait.
    subscribe()

    try do
      case claim(builder) do
        {:ok, lease} ->
          {:ok, lease}

        :none ->
          receive do
            {:lease_queued, _id} -> claim(builder)
          after
            timeout_ms -> :none
          end
      end
    after
      Phoenix.PubSub.unsubscribe(Portal.PubSub, @topic)
      drain()
    end
  end

  defp drain do
    receive do
      {:lease_queued, _} -> drain()
    after
      0 -> :ok
    end
  end

  @doc "The lease, if `builder_id` holds it and it is still `:leased` or `:uploading`."
  @spec held(term(), String.t()) :: {:ok, Lease.t()} | {:error, :not_held}
  def held(lease_id, builder_id) do
    with {:ok, id} <- Ecto.UUID.cast(lease_id),
         {:ok, %Lease{builder_id: ^builder_id, state: state} = lease}
         when state in @held <- Ash.get(Lease, id, domain: @domain) do
      {:ok, lease}
    else
      _ -> {:error, :not_held}
    end
  end

  @doc """
  Record that the builder is alive: `heartbeat_at`, the phase (an unknown one
  is stored as `"building"`) and the last 4096 bytes of its log (a heartbeat
  without one keeps the last). Phase `"uploading"` moves the lease to
  `:uploading`, which has the longer silence allowance. One guarded update:
  a lease the builder no longer holds is left alone and answers `:not_held`.
  """
  @spec heartbeat(term(), String.t(), term(), term()) ::
          {:ok, Lease.t()} | {:error, :not_held | :update_failed}
  def heartbeat(lease_id, builder_id, phase, log_tail) do
    phase = if phase in @phases, do: phase, else: "building"

    set =
      [heartbeat_at: DateTime.utc_now(), phase: phase]
      |> then(&if(phase == "uploading", do: [{:state, "uploading"} | &1], else: &1))
      |> then(&if(is_binary(log_tail), do: [{:log_tail, tail(log_tail)} | &1], else: &1))

    with {:ok, id} <- cast_id(lease_id),
         {:ok, lease} <- transition(id, [states: @held, builder_id: builder_id], set: set) do
      Progress.broadcast(lease.scan_request_id, :building, %{remote: true, phase: phase})
      {:ok, lease}
    else
      {:error, :stale} -> {:error, :not_held}
      {:error, :not_held} -> {:error, :not_held}
      {:error, {:db, reason}} -> db_failed("heartbeat", lease_id, reason)
    end
  end

  defp cast_id(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, :not_held}
    end
  end

  defp db_failed(what, id, reason) do
    Logger.error("#{what} could not update lease #{inspect(id)}: #{inspect(reason)}")
    {:error, :update_failed}
  end

  # A tail cut mid-character loses the partial bytes, so the column only ever
  # holds valid UTF-8.
  defp tail(log) do
    size = byte_size(log)

    log
    |> binary_part(max(size - @log_tail_bytes, 0), min(size, @log_tail_bytes))
    |> drop_continuation_bytes()
    |> String.replace_invalid("")
  end

  defp drop_continuation_bytes(<<0b10::2, _::6, rest::binary>>),
    do: drop_continuation_bytes(rest)

  defp drop_continuation_bytes(bin), do: bin

  @doc """
  The end of an attempt: exit 0 is `:done`, 11 (non-Hex dependency) fails
  the lease for good and rejects the request, anything else requeues it
  until `max_attempts` and then fails it. Applies only while `lease` is
  still the attempt it names (held, same builder, same `run_id`); a lease the
  reaper or an admin has moved on answers `{:error, :not_held}`.
  """
  @spec complete(Lease.t(), integer(), keyword()) ::
          {:ok, :done | :requeued | :failed | :rejected, Lease.t()}
          | {:error, :not_held | :update_failed}
  def complete(lease, exit_code, opts \\ [])

  def complete(%Lease{} = lease, 0, _opts) do
    with {:ok, lease} <- end_attempt(lease, state: "done", phase: nil), do: {:ok, :done, lease}
  end

  def complete(%Lease{} = lease, 11, _opts) do
    with {:ok, lease} <- end_attempt(lease, state: "failed", error: "non-Hex dep") do
      Progress.mark(lease.scan_request_id, :rejected, error_reason: "non-Hex dep")
      Progress.broadcast(lease.scan_request_id, :rejected, %{reason: "non-Hex dep"})
      {:ok, :rejected, lease}
    end
  end

  # `opts[:error_log]`: the tail of the runner log the agent sent with a
  # failing exit, stored on the request when the lease fails; the heartbeat's
  # 4 KiB `log_tail` otherwise.
  def complete(%Lease{attempt: attempt, max_attempts: max} = lease, exit_code, opts) do
    reason = "worker/runner exit #{exit_code}"

    if attempt < max do
      # `attempt` is kept: the claim incremented it.
      with {:ok, lease} <- end_attempt(lease, requeue_set(reason)) do
        notify_queued(lease)
        {:ok, :requeued, lease}
      end
    else
      with {:ok, lease} <- end_attempt(lease, state: "failed", error: reason) do
        fail_request(lease, reason, Keyword.get(opts, :error_log))
        {:ok, :failed, lease}
      end
    end
  end

  defp end_attempt(lease, set) do
    guard = [states: @held, builder_id: lease.builder_id, run_id: lease.run_id]

    case transition(lease.id, guard, set: set) do
      {:ok, lease} -> {:ok, lease}
      {:error, :stale} -> {:error, :not_held}
      {:error, {:db, reason}} -> db_failed("complete", lease.id, reason)
    end
  end

  defp requeue_set(reason) do
    [
      state: "queued",
      builder_id: nil,
      leased_at: nil,
      heartbeat_at: nil,
      phase: nil,
      error: reason
    ]
  end

  defp fail_request(lease, reason, error_log \\ nil) do
    Progress.mark(lease.scan_request_id, :error,
      error_reason: reason,
      error_log: error_log || lease.log_tail
    )

    Progress.broadcast(lease.scan_request_id, :error, %{reason: reason})
  end

  @doc """
  Fail the lease `lease_id` names for good, from `:leased`, `:uploading` or
  `:done`, with `error: reason`: its request is errored and its upload dir
  removed. For an attempt that ended but whose upload cannot be ingested
  (`Portal.Workers.Ingest` finding no `result.json`), where `complete/2`'s
  exit-code semantics do not apply. A lease already moved on answers
  `{:error, :stale}`.
  """
  @spec fail_by_id(term(), String.t()) ::
          {:ok, Lease.t()} | {:error, :not_found | :stale | :update_failed}
  def fail_by_id(lease_id, reason) do
    with {:ok, id} <- Ecto.UUID.cast(lease_id),
         {:ok, %Lease{} = lease} <- Ash.get(Lease, id, domain: @domain) do
      fail(lease, reason)
    else
      _ -> {:error, :not_found}
    end
  end

  @doc "`fail_by_id/2` for a lease already read."
  @spec fail(Lease.t(), String.t()) :: {:ok, Lease.t()} | {:error, :stale | :update_failed}
  def fail(%Lease{} = lease, reason) do
    case transition(lease.id, [states: [:leased, :uploading, :done]],
           set: [state: "failed", error: reason, bytes_uploaded: 0]
         ) do
      {:ok, lease} ->
        fail_request(lease, reason)
        Portal.Builders.Upload.cleanup(lease.id)
        {:ok, lease}

      {:error, :stale} ->
        {:error, :stale}

      {:error, {:db, reason}} ->
        db_failed("fail", lease.id, reason)
    end
  end

  @doc """
  Admin retry: a `:failed` lease back to `:queued` with a fresh attempt
  budget. A lease already handed to a local build (`mark_requeued_locally/1`)
  answers `{:error, :requeued_locally}`, so a stale page cannot build it twice.
  """
  @spec requeue(Lease.t()) ::
          {:ok, Lease.t()} | {:error, :not_failed | :requeued_locally | :update_failed}
  def requeue(%Lease{} = lease) do
    set = Keyword.merge(requeue_set(nil), attempt: 0, bytes_uploaded: 0)

    case transition(lease.id, [states: [:failed], not_error: @requeued_locally], set: set) do
      {:ok, lease} ->
        notify_queued(lease)
        {:ok, lease}

      {:error, :stale} ->
        if requeued_locally?(lease.id),
          do: {:error, :requeued_locally},
          else: {:error, :not_failed}

      {:error, {:db, reason}} ->
        db_failed("requeue", lease.id, reason)
    end
  end

  @doc "The `error` a `:failed` lease handed to a local build carries."
  @spec requeued_locally() :: String.t()
  def requeued_locally, do: @requeued_locally

  @doc """
  Note that a `:failed` or still-`:queued` lease was handed to a local build:
  it becomes (or stays) `:failed` with `error: "requeued locally"`, so the
  request it holds is released to the local job. A `:queued` lease is the
  way out when no builder will come back for it (none enrolled, or all
  silent): the reaper never touches `:queued`. Only once: a lease already
  noted, or held by a builder, answers `{:error, :not_failed}`.
  """
  @spec mark_requeued_locally(Lease.t()) ::
          {:ok, Lease.t()} | {:error, :not_failed | :update_failed}
  def mark_requeued_locally(%Lease{} = lease) do
    {count, _} =
      Repo.update_all(
        from(l in "builder_leases",
          where:
            l.id == type(^lease.id, Ecto.UUID) and l.state in ["failed", "queued"] and
              (is_nil(l.error) or l.error != @requeued_locally)
        ),
        set: [state: "failed", error: @requeued_locally, phase: nil, updated_at: now()]
      )

    case count do
      1 ->
        Portal.AdminEvents.broadcast(:builders)
        {:ok, Ash.get!(Lease, lease.id, domain: @domain)}

      0 ->
        {:error, :not_failed}
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] ->
      db_failed("requeue locally", lease.id, e)
  end

  defp requeued_locally?(id) do
    match?(
      {:ok, %Lease{state: :failed, error: @requeued_locally}},
      Ash.get(Lease, id, domain: @domain)
    )
  end

  @doc "Count `n` uploaded bytes against the attempt `lease` names, atomically."
  @spec add_bytes(Lease.t(), non_neg_integer()) ::
          {:ok, Lease.t()} | {:error, :not_held | :update_failed}
  def add_bytes(%Lease{} = lease, n) do
    guard = [states: @held, builder_id: lease.builder_id, run_id: lease.run_id]

    case transition(lease.id, guard, inc: [bytes_uploaded: n]) do
      {:ok, lease} -> {:ok, lease}
      {:error, :stale} -> {:error, :not_held}
      {:error, {:db, reason}} -> db_failed("add_bytes", lease.id, reason)
    end
  end

  @doc """
  Take leases back from builders that went silent: `:leased` without a
  heartbeat for 10 minutes or held past 2 h 30 min, `:uploading` without a
  heartbeat for 60 minutes. Each is requeued, or failed once its attempts
  are spent. Both are single updates whose `WHERE` is the silence rule
  itself, so a heartbeat or completion that lands first keeps its lease.
  `failed_ids` names the failed ones, whose upload dirs nothing will read.
  """
  @spec reap(DateTime.t()) :: %{
          requeued: non_neg_integer(),
          failed: non_neg_integer(),
          failed_ids: [Ecto.UUID.t()]
        }
  def reap(now \\ DateTime.utc_now()) do
    reason = "builder went silent"

    {_, failed} =
      Repo.update_all(
        from(l in silent(now), where: l.attempt >= l.max_attempts),
        set: [state: "failed", error: reason, updated_at: DateTime.utc_now()]
      )

    {_, requeued} =
      Repo.update_all(
        from(l in silent(now), where: l.attempt < l.max_attempts),
        set: Keyword.put(requeue_set(reason), :updated_at, DateTime.utc_now())
      )

    for {id, scan_request_id, log_tail} <- failed do
      Progress.mark(scan_request_id, :error, error_reason: reason, error_log: log_tail)
      Progress.broadcast(scan_request_id, :error, %{reason: reason})
      Logger.warning("reaper failed lease #{id}: #{reason}")
    end

    for {id, _, _} <- requeued do
      Phoenix.PubSub.broadcast(Portal.PubSub, @topic, {:lease_queued, id})
    end

    if failed != [] or requeued != [], do: Portal.AdminEvents.broadcast(:builders)

    %{
      requeued: length(requeued),
      failed: length(failed),
      failed_ids: Enum.map(failed, fn {id, _, _} -> id end)
    }
  end

  defp silent(now) do
    leased_cutoff = DateTime.add(now, -@leased_silence_minutes, :minute)
    ceiling = DateTime.add(now, -@lease_ceiling_minutes, :minute)
    uploading_cutoff = DateTime.add(now, -@uploading_silence_minutes, :minute)

    from(l in "builder_leases",
      where:
        (l.state == "leased" and
           (l.heartbeat_at < type(^leased_cutoff, :utc_datetime_usec) or
              l.leased_at < type(^ceiling, :utc_datetime_usec))) or
          (l.state == "uploading" and
             l.heartbeat_at < type(^uploading_cutoff, :utc_datetime_usec)),
      select: {type(l.id, Ecto.UUID), type(l.scan_request_id, Ecto.UUID), l.log_tail}
    )
  end

  def counts do
    from(l in "builder_leases", group_by: l.state, select: {l.state, count()})
    |> Repo.all()
    |> Map.new(fn {state, n} -> {String.to_existing_atom(state), n} end)
    |> then(&Map.merge(%{queued: 0, leased: 0, uploading: 0, done: 0, failed: 0}, &1))
  end

  @spec recent(pos_integer()) :: [Lease.t()]
  def recent(limit \\ 50) do
    Lease
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(domain: @domain)
  end

  @spec open() :: [Lease.t()]
  def open do
    Lease
    |> Ash.Query.filter(state in [:queued, :leased, :uploading])
    |> Ash.Query.sort(priority: :asc, inserted_at: :asc)
    |> Ash.read!(domain: @domain)
  end

  @spec failed() :: [Lease.t()]
  def failed do
    Lease
    |> Ash.Query.filter(state == :failed)
    |> Ash.Query.sort(updated_at: :desc)
    |> Ash.read!(domain: @domain)
  end

  defp notify_queued(lease),
    do: Phoenix.PubSub.broadcast(Portal.PubSub, @topic, {:lease_queued, lease.id})

  # Every state change after the claim: one `UPDATE ... WHERE id AND <the
  # state the caller saw>`, so a transition never lands on a lease that has
  # moved on since it was read. `{:error, :stale}` when nothing matched.
  defp transition(id, guard, updates) do
    query =
      Enum.reduce(guard, from(l in "builder_leases", where: l.id == type(^id, Ecto.UUID)), fn
        {:states, states}, q ->
          from(l in q, where: l.state in ^Enum.map(states, &Atom.to_string/1))

        {:builder_id, builder_id}, q ->
          from(l in q, where: l.builder_id == type(^builder_id, Ecto.UUID))

        {:run_id, run_id}, q ->
          from(l in q, where: l.run_id == ^run_id)

        {:not_error, error}, q ->
          from(l in q, where: is_nil(l.error) or l.error != ^error)
      end)

    updates = Keyword.update(updates, :set, [updated_at: now()], &[{:updated_at, now()} | &1])

    case Repo.update_all(from(l in query, select: l.id), updates) do
      {1, _} ->
        Portal.AdminEvents.broadcast(:builders)
        {:ok, Ash.get!(Lease, id, domain: @domain)}

      {0, _} ->
        {:error, :stale}
    end
  rescue
    e in [Postgrex.Error, DBConnection.ConnectionError] -> {:error, {:db, e}}
  end

  defp now, do: DateTime.utc_now()
end
