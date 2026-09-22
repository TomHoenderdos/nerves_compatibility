defmodule Portal.Admin do
  @moduledoc """
  Operations available to an admin from `/admin`, kept out of the controller so
  they can be tested without a connection.

  Everything here assumes the caller has already been through
  `PortalWeb.Plugs.RequireAdmin`. Nothing in this module re-checks that, so do
  not call it from a route that is not admin-gated.

  ## Why it talks to Oban directly

  Queue position is not a property of a `ScanRequest` -- it lives on the
  `Oban.Job` the request produced, and only while that job is still waiting.
  Mirroring it onto the request row would give us two copies that drift the
  moment Oban starts the job, so the job row stays the single source of truth
  and this module reads it.
  """

  import Ecto.Query, only: [from: 2]

  alias Portal.Repo
  alias Portal.ScanRequests
  alias Portal.ScanRequests.ScanRequest
  alias Portal.Workers.UpdateCheck

  @build_worker "Portal.Workers.Build"
  @update_check_worker "Portal.Workers.UpdateCheck"

  # States in which a priority change still means something. An `executing` job
  # has already been handed to a worker and Oban will never look at its priority
  # again, so silently "succeeding" on one would be a lie told to somebody
  # watching the queue not move.
  @adjustable_states ~w(available scheduled retryable)

  # Oban's range. 0 runs first.
  @min_priority 0
  @max_priority 9

  # Permissive on purpose. The authority on whether a package exists is hex.pm,
  # which the enqueue path already asks and which already closes the request out
  # as rejected when the answer is no. This only stops a stray paste -- a URL, a
  # sentence, an empty box -- from becoming a request row and an HTTP call.
  @package_name ~r/\A[A-Za-z0-9][A-Za-z0-9_.-]{0,63}\z/

  @typedoc "A package name as typed into the admin form."
  @type package_name :: String.t()

  @doc """
  Queue a scan for `package_name` on behalf of `admin_user`.

  Skips the approval step that an anonymous submission goes through -- an admin
  submitting the form *is* the approval -- and enters the queue at priority 0.

  With `force: true` the build runs even when a result already exists for the
  version that is current. Without it, `Portal.Workers.Build` deduplicates on
  (package, version, image digest) and a package that is already up to date
  produces a job that does nothing, which from the admin page looks identical
  to a package that was queued and built instantly.

  Returns `{:error, {:already_open, request}}` rather than quietly folding into
  an existing request, so the page can say which one and what state it is in.
  """
  @spec queue_package(package_name(), struct(), keyword()) ::
          {:ok, ScanRequest.t()} | {:error, term()}
  def queue_package(package_name, admin_user, opts \\ []) do
    name = package_name |> to_string() |> String.trim()
    force = Keyword.get(opts, :force, false)

    cond do
      name == "" ->
        {:error, :blank_package_name}

      not Regex.match?(@package_name, name) ->
        {:error, :invalid_package_name}

      true ->
        case {force, ScanRequests.open_request_for_package(name)} do
          # A request already on its way. Forcing is the caller saying they know
          # and want another build anyway, which the enqueue path honours.
          {false, %ScanRequest{status: status} = request} when status in [:accepted, :queued] ->
            {:error, {:already_open, request}}

          _ ->
            ScanRequests.create_once(%{
              package_name: name,
              source: :admin_manual,
              status: :queued,
              subject: "requested_by:#{admin_user.username}",
              verification_provider: "admin",
              force: force
            })
        end
    end
  end

  @doc """
  Move the build job for `scan_request_id` one step up or down the queue.

  One step, not a jump to the front: the queue holds hundreds of jobs at a
  handful of distinct priorities, so a single step is already the difference
  between "next" and "after everything else at this level".

  Returns `{:ok, new_priority}`, or `{:error, :already_at_limit}` at either end.
  """
  @spec reprioritise(String.t(), :up | :down) :: {:ok, non_neg_integer()} | {:error, term()}
  def reprioritise(scan_request_id, direction) when direction in [:up, :down] do
    # Lower number, sooner. "Up the queue" is therefore priority - 1, which is
    # backwards from how the number reads and is exactly why it is named once
    # here instead of at each call site.
    delta = if direction == :up, do: -1, else: 1

    case build_job(scan_request_id) do
      nil ->
        {:error, :no_job}

      %Oban.Job{state: state} when state not in @adjustable_states ->
        {:error, {:not_adjustable, state}}

      %Oban.Job{id: id, priority: priority} ->
        wanted = priority + delta

        if wanted < @min_priority or wanted > @max_priority do
          {:error, :already_at_limit}
        else
          {1, _} =
            Repo.update_all(from(j in Oban.Job, where: j.id == ^id), set: [priority: wanted])

          {:ok, wanted}
        end
    end
  end

  @doc """
  Queue position for each of `scan_request_ids`, as a map keyed by request id.

  One query for the whole page rather than one per row. A request with no
  waiting job is simply absent from the map -- it has been built, cancelled, or
  is running right now, and none of those has a position.
  """
  @spec queue_positions([String.t()]) :: %{optional(String.t()) => map()}
  def queue_positions([]), do: %{}

  def queue_positions(scan_request_ids) do
    from(j in Oban.Job,
      where: j.worker == @build_worker,
      where: fragment("? ->> 'scan_request_id' = ANY(?)", j.args, ^scan_request_ids),
      order_by: [asc: j.id],
      select: %{
        request_id: fragment("? ->> 'scan_request_id'", j.args),
        priority: j.priority,
        state: j.state,
        attempt: j.attempt
      }
    )
    |> Repo.all()
    # Ascending id then `Map.put` leaves the newest job per request standing,
    # which is the one a rebuild just inserted rather than the one it replaced.
    |> Enum.reduce(%{}, fn row, acc ->
      Map.put(acc, row.request_id, Map.put(row, :adjustable?, row.state in @adjustable_states))
    end)
  end

  @doc """
  What the admin page shows about the hex.pm update check: whether the schedule
  is on, the numbers from the last run that produced any, and
  whether another run is already waiting.
  """
  @spec update_check_status() :: map()
  def update_check_status do
    %{
      enabled?: UpdateCheck.enabled?(),
      last_run: last_update_check_run(),
      pending?: update_check_pending?()
    }
  end

  @doc """
  Ask for an update check now.

  Marked `manual` so the run happens even while the schedule is switched off --
  see `Portal.Workers.UpdateCheck.perform/1`. With `dry_run: true` it reports
  what it would have queued and queues nothing, which is the safe way to find
  out how far behind the catalogue is.

  `{:error, :already_queued}` means Oban deduplicated against a run that has not
  started yet; the answer is to wait for it, not to ask again.
  """
  @spec request_update_check(keyword()) :: {:ok, Oban.Job.t()} | {:error, term()}
  def request_update_check(opts \\ []) do
    args = %{manual: true}
    args = if Keyword.get(opts, :dry_run, false), do: Map.put(args, :dry_run, true), else: args

    case args |> UpdateCheck.new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :already_queued}
      {:ok, job} -> {:ok, job}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_job(scan_request_id) do
    from(j in Oban.Job,
      where: j.worker == @build_worker,
      where: fragment("? ->> 'scan_request_id' = ?", j.args, ^scan_request_id),
      order_by: [desc: j.id],
      limit: 1
    )
    |> Repo.one()
  end

  # The most recent run that actually recorded numbers. A run that was skipped
  # because the check is switched off completes just like any other and would
  # otherwise present itself as the last result, showing nothing.
  defp last_update_check_run do
    from(j in Oban.Job,
      where: j.worker == @update_check_worker,
      where: fragment("? ->> 'seen' IS NOT NULL", j.meta),
      order_by: [desc: j.id],
      limit: 1
    )
    |> Repo.one()
  end

  defp update_check_pending? do
    from(j in Oban.Job,
      where: j.worker == @update_check_worker,
      where: j.state in ~w(available scheduled executing retryable),
      limit: 1
    )
    |> Repo.exists?()
  end
end
