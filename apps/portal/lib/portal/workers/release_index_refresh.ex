defmodule Portal.Workers.ReleaseIndexRefresh do
  @moduledoc """
  Runs the module index per release (`Portal.Catalog.ReleaseIndex.refresh/1`,
  queue `:intake`), S10 round 5.

    * `%{"incremental" => true}`: the releases the registry lists that the
      index has not tried; `Portal.Workers.UpdateCheck` queues it hourly
      when there are any (`Portal.Catalog.ReleaseIndex.queue_incremental/1`).
    * `%{}` (daily cron, and the first run, started by hand once a release
      with this worker is deployed, after a dry run): the same, and the
      releases that failed before are tried again.

  At most one of each waiting (`unique` over available and scheduled jobs,
  not an executing one, so a run a deploy killed can be inserted again at
  once), and one running (re-review R5-1): a run that starts while another
  refresh has executed for less than the job timeout does not read, since
  it would start where the running one is and read the same releases. An
  incremental one is cancelled (the running run, or the next hourly one,
  reads what it would), a daily one waits 15 minutes and looks again. A
  run a deploy killed stays `executing` until `Oban.Plugins.Lifeline`
  rescues it; after the timeout it no longer counts. A stopped run keeps
  what it stored; the next one reads the rest.
  The first run reads every release of every Hex package (184,566 on
  2026-11-26); its measurement is in the S10 report (§13).
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 1,
    unique: [period: :infinity, states: [:available, :scheduled]]

  import Ecto.Query, only: [from: 2]

  @timeout_minutes 150

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    cond do
      another_running?(job) and args["incremental"] == true ->
        {:cancel, :another_refresh_running}

      another_running?(job) ->
        {:snooze, 15 * 60}

      true ->
        opts = if is_integer(args["limit"]), do: [limit: args["limit"]], else: []
        opts = if args["incremental"] == true, do: opts, else: [{:retry_failed, true} | opts]
        _counts = Portal.Catalog.ReleaseIndex.refresh(opts)
        :ok
    end
  end

  # Another refresh of either kind that started within the job timeout.
  defp another_running?(%Oban.Job{id: id}) do
    since = DateTime.add(DateTime.utc_now(), -@timeout_minutes, :minute)
    worker = Oban.Worker.to_string(__MODULE__)

    query =
      from(j in Oban.Job,
        where: j.worker == ^worker and j.state == "executing" and j.attempted_at > ^since
      )

    query = if is_integer(id), do: from(j in query, where: j.id != ^id), else: query
    Portal.Repo.exists?(query)
  end

  @impl Oban.Worker
  # Under `Oban.Plugins.Lifeline`'s 3 h `rescue_after`; a first run that
  # needs longer is resumed by inserting the job again.
  def timeout(_job), do: :timer.minutes(@timeout_minutes)
end
