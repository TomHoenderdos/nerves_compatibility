defmodule Portal.Builders.Routing do
  @moduledoc """
  Decides, at enqueue time, whether a build job runs on the local `:builds`
  queue or becomes a remote lease through the `:remote` queue. A job already
  on `:builds` is never moved.

  Local wins whenever remote could not do the job or should not: toolchain
  and warm jobs (they write host caches), jobs pinned local (a revoked
  builder's rebuilds), no builder seen lately, no registry image to name,
  or a local backlog still under the threshold.

  Every enqueuer of `Portal.Workers.Build` goes through `build_job/2`.
  """
  import Ecto.Query, only: [from: 2]
  require Ash.Query

  alias Portal.Builders.{Builder, Images}
  alias Portal.Repo
  alias Portal.Workers.{Build, RemoteBuild}

  # `:auto` turns remote on once an enrolled builder was seen within the first
  # window and off once none was seen within the second; in between it holds
  # the stored `remote_auto_on`, so a builder's brief silence does not flap it.
  @seen_on_seconds 5 * 60
  @seen_off_seconds 15 * 60
  @local_modes ["toolchain", "warm_nerves"]
  @waiting_states ["available", "scheduled", "retryable"]

  @doc """
  `:remote` or `:builds` for a job with `args` (atom or string keys) and the
  `opts` it would be built with (`:meta` may carry `pin_local`).
  """
  @spec queue_for(map(), keyword()) :: :builds | :remote
  def queue_for(args, opts \\ []) do
    cond do
      mode(args) in @local_modes -> :builds
      pinned?(opts) -> :builds
      not remote_enabled?() -> :builds
      is_nil(Images.worker_image()) -> :builds
      local_backlog() > threshold() -> :remote
      true -> :builds
    end
  end

  @doc """
  The job changeset for `args`: `Portal.Workers.RemoteBuild.new/2` or
  `Portal.Workers.Build.new/2` per `queue_for/2`, with `opts` passed through.
  """
  @spec build_job(map(), keyword()) :: Ecto.Changeset.t()
  def build_job(args, opts \\ []) do
    case queue_for(stringify(args), opts) do
      :remote -> RemoteBuild.new(args, opts)
      :builds -> Build.new(args, opts)
    end
  end

  @doc "Whether remote building is on: forced by `remote_mode`, or decided by `:auto`."
  @spec remote_enabled?() :: boolean()
  def remote_enabled? do
    settings = Portal.Settings.get()

    case settings.remote_mode do
      :on -> true
      :off -> false
      :auto -> auto_enabled?(settings)
    end
  end

  defp auto_enabled?(settings) do
    now = DateTime.utc_now()
    latest = latest_seen()

    decision =
      cond do
        latest && DateTime.diff(now, latest, :second) <= @seen_on_seconds -> true
        is_nil(latest) or DateTime.diff(now, latest, :second) > @seen_off_seconds -> false
        true -> settings.remote_auto_on
      end

    # Best effort: the stored flag only matters for the hold window, and an
    # enqueue must not fail over it.
    if decision != settings.remote_auto_on,
      do: _ = Portal.Settings.set_remote_auto_on(decision)

    decision
  end

  defp latest_seen do
    Builder
    |> Ash.Query.filter(status == :enrolled and not is_nil(last_seen_at))
    |> Ash.Query.sort(last_seen_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Portal.Builders)
    |> case do
      [%Builder{last_seen_at: seen}] -> seen
      [] -> nil
    end
  end

  @doc "The local backlog above which builds go remote (`remote_backlog_threshold`)."
  @spec threshold() :: non_neg_integer()
  def threshold, do: Portal.Settings.get().remote_backlog_threshold

  @doc "Local `Portal.Workers.Build` jobs waiting on the `:builds` queue."
  @spec local_backlog() :: non_neg_integer()
  def local_backlog do
    Repo.one(
      from(j in "oban_jobs",
        where:
          j.worker == "Portal.Workers.Build" and j.queue == "builds" and
            j.state in @waiting_states,
        select: count()
      )
    )
  end

  defp mode(args), do: Map.get(args, "mode") || Map.get(args, :mode)

  defp pinned?(opts) do
    meta = Keyword.get(opts, :meta) || %{}
    Map.get(meta, :pin_local) == true or Map.get(meta, "pin_local") == true
  end

  defp stringify(args), do: Map.new(args, fn {k, v} -> {to_string(k), v} end)
end
