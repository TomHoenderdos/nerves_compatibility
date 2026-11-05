defmodule Portal.OrphanRescue do
  @moduledoc """
  At boot, before Oban starts, take back the short cron jobs this node was
  running when it last went down.

  A job's row stays `executing` when its node dies under it, deploy restarts
  included: nothing on a dead node is left to finish it, fail it or time it
  out (a `timeout/1` is enforced by the executor process, which died with the
  node). `Oban.Plugins.Lifeline` rescues such rows, but only by age, and its
  `rescue_after` has to clear the slowest build (see `config/config.exs`). For
  a worker whose uniqueness covers `:executing`, that means hours in which
  every cron insert is skipped: an orphaned `Portal.Workers.PrecompiledBatch`
  stops new signed batches for three hours, and clients refuse a batch older
  than a day.

  The job is certainly orphaned when its `attempted_by` names this node and
  this node's Oban has not started yet: no producer here can be running it,
  and no other node's producer stamps this node's name. So the same
  transition Lifeline makes runs here at once, for those rows only: back to
  `available` while attempts remain, `discarded` once they are spent (an
  `available` row past `max_attempts` is never fetched and would block the
  cron forever). Discarding still unblocks the next cron insert. A
  concurrent Lifeline on another node would make the same transition; the
  `state = 'executing'` guard makes either one a no-op for the other.

  This is a direct update on `Oban.Job` because Oban has no public API for it:
  `Oban.retry_job/2` skips `executing` rows, and `Oban.cancel_job/2` needs a
  running instance and would only wait for the next tick.

  Only the workers in `workers/0`, and only on a node that runs their queue.
  Each is a cron job, unique over `:incomplete` (so an orphan blocks its own
  schedule), short, and safe to run again from the start:

    * `Portal.Workers.PrecompiledBatch` computes its sequence at run time and
      the unique sequence index settles a race; an unchanged render reuses
      its memo.
    * `Portal.Workers.LeaseReaper` moves lease rows by age; a second pass
      finds nothing left to move.
    * `Portal.Workers.LogRetention` deletes against a budget it recomputes
      from the table each run.
    * `Portal.Workers.UpdateCheck` is stateless; every build it offers is
      unique.

  Builds, ingests and warms are left to Lifeline: their container or scratch
  work can outlive the BEAM, which is why `rescue_after` is what it is.
  `Portal.Workers.ToolchainSweep` is left out too, since a second pass would
  queue a second `max_per_run` of builds.
  """

  import Ecto.Query

  require Logger

  alias Portal.Repo

  @workers [
    Portal.Workers.PrecompiledBatch,
    Portal.Workers.LeaseReaper,
    Portal.Workers.LogRetention,
    Portal.Workers.UpdateCheck
  ]

  @doc "The workers whose orphans are rescued at boot."
  def workers, do: @workers

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, restart: :temporary}
  end

  @doc """
  Runs the rescue for this node, read from the Oban options (`:oban`, default
  the `:portal` app's), and returns `:ignore`. Skipped while Oban runs in a
  testing mode. A failure is logged and never stops the boot: Lifeline is
  still there behind it.
  """
  def start_link(opts \\ []) do
    oban = Keyword.get_lazy(opts, :oban, fn -> Application.fetch_env!(:portal, Oban) end)

    if Keyword.get(oban, :testing, :disabled) == :disabled do
      try do
        node = Oban.Config.new(oban).node
        _ = rescue_orphans(node, Keyword.keys(Keyword.get(oban, :queues) || []))
      rescue
        e -> Logger.error("Orphaned job rescue failed: " <> Exception.message(e))
      end
    end

    :ignore
  end

  @doc """
  Moves the `executing` jobs of `workers/0` on `queues` attempted by `node`
  to `available`, or `discarded` once out of attempts. Only call it before
  `node`'s Oban starts.
  """
  def rescue_orphans(node, queues) when is_binary(node) and is_list(queues) do
    queues = Enum.map(queues, &to_string/1)

    workers =
      for worker <- @workers,
          to_string(worker.__opts__()[:queue]) in queues,
          do: Oban.Worker.to_string(worker)

    base =
      from(j in Oban.Job,
        where: j.state == "executing",
        where: j.worker in ^workers,
        where: fragment("?[1] = ?", j.attempted_by, ^node),
        select: j.id
      )

    {_, rescued} =
      Repo.update_all(where(base, [j], j.attempt < j.max_attempts), set: [state: "available"])

    {_, discarded} =
      Repo.update_all(where(base, [j], j.attempt >= j.max_attempts),
        set: [state: "discarded", discarded_at: DateTime.utc_now()]
      )

    if rescued != [] or discarded != [] do
      Logger.warning(
        "Rescued jobs orphaned by this node's restart: available #{inspect(rescued)}, " <>
          "discarded #{inspect(discarded)}"
      )
    end

    %{rescued: rescued, discarded: discarded}
  end
end
