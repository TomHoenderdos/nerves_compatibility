defmodule Portal.Oban.OwnedAckEngine do
  @moduledoc """
  `Oban.Engines.Basic`, except that an attempt's ack (complete, error,
  discard, snooze, cancel) writes only while the job's row is still
  `executing` under that attempt: the same `attempt` number and the same
  `attempted_by` (`[node, producer uuid]`) its fetch stamped. Both are
  needed: Lifeline's rescue keeps `attempted_by`, so the same producer can
  fetch the row again with an identical one, and only the attempt number,
  which every fetch increments, tells the two attempts apart.

  Basic acks by id alone. A build whose `docker kill` hung returned fifteen
  hours late, after `Oban.Plugins.Lifeline` had rescued its row and a later
  attempt had discarded it, and its error ack made the discarded job
  retryable again (available at attempt 3/3, `discarded_at` set). Here such
  a late ack is dropped and logged; the row keeps what its owner recorded.

  The acks are only ever the executor's own, for the attempt it ran, so a
  row that is no longer executing under it is no longer its to write.
  """

  @behaviour Oban.Engine

  import Ecto.Query

  require Logger

  alias Oban.Engines.Basic
  alias Oban.{Job, Repo}

  @impl true
  defdelegate init(conf, opts), to: Basic
  @impl true
  defdelegate put_meta(conf, meta, key, value), to: Basic
  @impl true
  defdelegate check_meta(conf, meta, running), to: Basic
  @impl true
  defdelegate refresh(conf, meta), to: Basic
  @impl true
  defdelegate shutdown(conf, meta), to: Basic
  @impl true
  defdelegate insert_job(conf, changeset, opts), to: Basic
  @impl true
  defdelegate insert_all_jobs(conf, changesets, opts), to: Basic
  @impl true
  defdelegate fetch_jobs(conf, meta, running), to: Basic
  @impl true
  defdelegate stage_jobs(conf, queryable, opts), to: Basic
  @impl true
  defdelegate prune_jobs(conf, queryable, opts), to: Basic
  @impl true
  defdelegate rescue_jobs(conf, queryable, opts), to: Basic
  @impl true
  defdelegate check_available(conf), to: Basic
  @impl true
  defdelegate cancel_all_jobs(conf, queryable), to: Basic
  @impl true
  defdelegate delete_job(conf, job), to: Basic
  @impl true
  defdelegate delete_all_jobs(conf, queryable), to: Basic
  @impl true
  defdelegate retry_job(conf, job), to: Basic
  @impl true
  defdelegate retry_all_jobs(conf, queryable), to: Basic
  @impl true
  defdelegate update_job(conf, job, changes), to: Basic

  @impl true
  def complete_job(conf, job),
    do: owned(conf, job, :complete, fn -> Basic.complete_job(conf, job) end)

  @impl true
  def discard_job(conf, job),
    do: owned(conf, job, :discard, fn -> Basic.discard_job(conf, job) end)

  @impl true
  def error_job(conf, job, seconds),
    do: owned(conf, job, :error, fn -> Basic.error_job(conf, job, seconds) end)

  @impl true
  def snooze_job(conf, job, seconds),
    do: owned(conf, job, :snooze, fn -> Basic.snooze_job(conf, job, seconds) end)

  @impl true
  def cancel_job(conf, job), do: owned(conf, job, :cancel, fn -> Basic.cancel_job(conf, job) end)

  # The row is locked for the check and the write, so Lifeline cannot
  # rescue it in between. A job no producer fetched has no `attempted_by`
  # to own it by and is acked as Basic would.
  defp owned(_conf, %Job{attempted_by: nil}, _ack, write), do: write.()

  defp owned(conf, %Job{id: id, attempt: attempt, attempted_by: attempted_by} = job, ack, write) do
    {:ok, :ok} =
      Repo.transaction(conf, fn ->
        query =
          Job
          |> where([j], j.id == ^id and j.state == "executing")
          |> where([j], j.attempt == ^attempt and j.attempted_by == ^attempted_by)
          |> select([j], j.id)
          |> lock("FOR UPDATE")

        case Repo.one(conf, query) do
          nil -> stale(job, ack)
          _id -> write.()
        end
      end)

    :ok
  end

  defp stale(job, ack) do
    Logger.warning(
      "Dropped the #{ack} of job #{job.id} (#{job.worker}) attempt #{job.attempt}: " <>
        "its row is no longer executing under that attempt (rescued, retried or finished elsewhere)"
    )

    :ok
  end
end
