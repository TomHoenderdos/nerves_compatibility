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
  # The build's own 2 h wall clock plus 30 minutes of slack.
  @lease_ceiling_minutes 150
  @log_tail_bytes 4096
  @phases ~w(pulling building uploading)
  @default_long_poll_ms 25_000

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
  Take the next queued lease (lowest `priority`, then oldest) for `builder`,
  in one statement. `SKIP LOCKED` keeps two claimants off the same row; the
  slot check sits in the same `WHERE`, so a full builder takes nothing.
  """
  @spec claim(Builder.t()) :: {:ok, Lease.t()} | :none
  def claim(%Builder{id: builder_id, slots: slots}) do
    ms = System.system_time(:millisecond)

    sql = """
    UPDATE builder_leases
    SET state = 'leased', builder_id = $1, leased_at = now(), heartbeat_at = now(),
        attempt = attempt + 1, phase = NULL,
        run_id = 'rb-' || package || '-' || version || '-' || $3::text,
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

    case Repo.query!(sql, [Ecto.UUID.dump!(builder_id), slots, Integer.to_string(ms)]) do
      %{rows: [[id]]} ->
        lease = Ash.get!(Lease, Ecto.UUID.load!(id), domain: @domain)
        Portal.AdminEvents.broadcast(:builders)
        {:ok, lease}

      %{rows: []} ->
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

    result =
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

    Phoenix.PubSub.unsubscribe(Portal.PubSub, @topic)
    drain()
    result
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
         when state in [:leased, :uploading] <- Ash.get(Lease, id, domain: @domain) do
      {:ok, lease}
    else
      _ -> {:error, :not_held}
    end
  end

  @doc """
  Record that the builder is alive: `heartbeat_at`, the phase (an unknown one
  is stored as `"building"`) and the last 4096 bytes of its log. Phase
  `"uploading"` moves the lease to `:uploading`, which has the longer silence
  allowance.
  """
  @spec heartbeat(term(), String.t(), term(), term()) :: {:ok, Lease.t()} | {:error, :not_held}
  def heartbeat(lease_id, builder_id, phase, log_tail) do
    with {:ok, lease} <- held(lease_id, builder_id) do
      phase = if phase in @phases, do: phase, else: "building"
      state = if phase == "uploading", do: :uploading, else: lease.state

      attrs = %{
        heartbeat_at: DateTime.utc_now(),
        phase: phase,
        log_tail: tail(log_tail, lease.log_tail),
        state: state
      }

      case update(lease, attrs) do
        {:ok, lease} ->
          Progress.broadcast(lease.scan_request_id, :building, %{remote: true, phase: phase})
          {:ok, lease}

        {:error, reason} ->
          Logger.error("heartbeat could not update lease #{lease.id}: #{inspect(reason)}")
          {:error, :not_held}
      end
    end
  end

  # A heartbeat without a log keeps the last one. A tail cut mid-character
  # loses the partial bytes, so the column only ever holds valid UTF-8.
  defp tail(log, _previous) when is_binary(log) do
    size = byte_size(log)

    log
    |> binary_part(max(size - @log_tail_bytes, 0), min(size, @log_tail_bytes))
    |> drop_continuation_bytes()
    |> String.replace_invalid("")
  end

  defp tail(_log, previous), do: previous

  defp drop_continuation_bytes(<<0b10::2, _::6, rest::binary>>),
    do: drop_continuation_bytes(rest)

  defp drop_continuation_bytes(bin), do: bin

  @doc """
  The end of an attempt: exit 0 is `:done`, 11 (non-Hex dependency) fails
  the lease for good and rejects the request, anything else requeues it
  until `max_attempts` and then fails it.
  """
  @spec complete(Lease.t(), integer()) ::
          {:ok, :done | :requeued | :failed | :rejected, Lease.t()} | {:error, term()}
  def complete(%Lease{} = lease, 0) do
    with {:ok, lease} <- update(lease, %{state: :done, phase: nil}), do: {:ok, :done, lease}
  end

  def complete(%Lease{} = lease, 11) do
    with {:ok, lease} <- update(lease, %{state: :failed, error: "non-Hex dep"}) do
      Progress.mark(lease.scan_request_id, :rejected, error_reason: "non-Hex dep")
      Progress.broadcast(lease.scan_request_id, :rejected, %{reason: "non-Hex dep"})
      {:ok, :rejected, lease}
    end
  end

  def complete(%Lease{} = lease, exit_code),
    do: retry_or_fail(lease, "worker/runner exit #{exit_code}")

  # `attempt` is kept: the claim incremented it.
  defp retry_or_fail(%Lease{attempt: attempt, max_attempts: max} = lease, reason)
       when attempt < max do
    with {:ok, lease} <-
           update(lease, %{
             state: :queued,
             builder_id: nil,
             leased_at: nil,
             heartbeat_at: nil,
             phase: nil,
             error: reason
           }) do
      notify_queued(lease)
      {:ok, :requeued, lease}
    end
  end

  defp retry_or_fail(lease, reason) do
    with {:ok, lease} <- update(lease, %{state: :failed, error: reason}) do
      Progress.mark(lease.scan_request_id, :error,
        error_reason: reason,
        error_log: lease.log_tail
      )

      Progress.broadcast(lease.scan_request_id, :error, %{reason: reason})
      {:ok, :failed, lease}
    end
  end

  @doc "Admin retry: a lease back to `:queued` with a fresh attempt budget."
  @spec requeue(Lease.t()) :: {:ok, Lease.t()} | {:error, term()}
  def requeue(%Lease{} = lease) do
    with {:ok, lease} <-
           update(lease, %{
             state: :queued,
             builder_id: nil,
             leased_at: nil,
             heartbeat_at: nil,
             phase: nil,
             attempt: 0,
             error: nil
           }) do
      notify_queued(lease)
      {:ok, lease}
    end
  end

  @spec add_bytes(Lease.t(), non_neg_integer()) :: {:ok, Lease.t()} | {:error, term()}
  def add_bytes(%Lease{} = lease, n),
    do: update(lease, %{bytes_uploaded: lease.bytes_uploaded + n})

  @doc """
  Take leases back from builders that went silent: `:leased` without a
  heartbeat for 10 minutes or held past 2 h 30 min, `:uploading` without a
  heartbeat for 60 minutes. Each is requeued, or failed once its attempts
  are spent.
  """
  @spec reap(DateTime.t()) :: %{requeued: non_neg_integer(), failed: non_neg_integer()}
  def reap(now \\ DateTime.utc_now()) do
    leased_cutoff = DateTime.add(now, -@leased_silence_minutes, :minute)
    ceiling = DateTime.add(now, -@lease_ceiling_minutes, :minute)
    uploading_cutoff = DateTime.add(now, -@uploading_silence_minutes, :minute)

    Lease
    |> Ash.Query.filter(
      (state == :leased and (heartbeat_at < ^leased_cutoff or leased_at < ^ceiling)) or
        (state == :uploading and heartbeat_at < ^uploading_cutoff)
    )
    |> Ash.read!(domain: @domain)
    |> Enum.reduce(%{requeued: 0, failed: 0}, fn lease, acc ->
      case retry_or_fail(lease, "builder went silent") do
        {:ok, :requeued, _} ->
          Map.update!(acc, :requeued, &(&1 + 1))

        {:ok, :failed, _} ->
          Map.update!(acc, :failed, &(&1 + 1))

        {:error, reason} ->
          Logger.error("reaper could not update lease #{lease.id}: #{inspect(reason)}")
          acc
      end
    end)
  end

  @spec counts() :: %{
          queued: non_neg_integer(),
          leased: non_neg_integer(),
          uploading: non_neg_integer(),
          done: non_neg_integer(),
          failed: non_neg_integer()
        }
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

  defp update(lease, attrs) do
    with {:ok, lease} <-
           lease |> Ash.Changeset.for_update(:update, attrs) |> Ash.update(domain: @domain) do
      Portal.AdminEvents.broadcast(:builders)
      {:ok, lease}
    end
  end
end
