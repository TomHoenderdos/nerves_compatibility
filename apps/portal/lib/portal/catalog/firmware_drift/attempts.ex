defmodule Portal.Catalog.FirmwareDrift.Attempts do
  @moduledoc """
  The firmware drift rebuilds `Portal.Workers.ClosureDrift` queued, each by
  the run it would replace and the fingerprint of its inputs
  (`fingerprint/3`), in `firmware_drift_attempts`.

  A rebuild that lands a run makes that run the package's latest, so the
  next drift run judges the new one: a target that failed in it is no
  longer a passing target and is not rebuilt. A rebuild that lands no run
  (its job discarded or cancelled after its attempts, its lease failed)
  leaves the old run the latest, still drifted, and it would be queued
  again every day, a failing build taking a place under the cap each time.
  So an attempt on the run that is still the latest, with the same
  fingerprint, and no build of the package on the way, means the rebuild
  landed no run, and it waits (`failed?/2`) until its fingerprint changes:

    * a newer release of a dependency or of the system: the changes it
      names move (`to`), or another one joins them;
    * other targets;
    * a judge that changed: `Portal.Catalog.FirmwareDrift`'s own
      (`@revision` there) or the workers' (the newest `judge_revision` a
      toolchain build reported);
    * a week passing (`@retry_after_days`), for a failure that was the
      host's (a builder gone silent, a full disk) and for a worker fix that
      left the judge alone. A new worker image is no signal of its own: the
      registry digest changes with every commit (the `ncc.commit` label),
      and so does the one builds record.
  """

  import Ecto.Query, only: [from: 2]

  alias Portal.Repo

  @retry_after_days 7

  @doc """
  The fingerprint of a rebuild's inputs: the targets, every change
  (`%{"dep", "from", "to"}`), the judge's own revision and `worker_revision`
  (`worker_revision/0`).
  """
  @spec fingerprint([String.t()], [map()], term()) :: String.t()
  def fingerprint(systems, changes, worker_revision) do
    [
      Portal.Catalog.FirmwareDrift.revision(),
      worker_revision,
      Enum.sort(systems),
      changes |> Enum.map(&[&1["dep"], &1["from"], &1["to"]]) |> Enum.sort()
    ]
    |> Jason.encode!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  The newest worker judge revision a toolchain build of the default
  `config_variant` reported (nil: none yet): the workers' judge, which every
  build of theirs runs, whatever its config.
  """
  @spec worker_revision() :: integer() | nil
  def worker_revision do
    Repo.one(
      from(t in "catalog_toolchain_builds",
        where: t.config_variant == "default",
        select: max(t.judge_revision)
      )
    )
  end

  @doc """
  Whether a rebuild of `run_id` with `fingerprint` was queued within the
  retry window. The caller has checked that no build of the package is on
  the way and that `run_id` is still the package's latest, so it landed no
  run.
  """
  @spec failed?(Ecto.UUID.t(), String.t()) :: boolean()
  def failed?(run_id, fingerprint) do
    since = NaiveDateTime.add(NaiveDateTime.utc_now(), -@retry_after_days, :day)

    Repo.exists?(
      from(a in "firmware_drift_attempts",
        where:
          a.run_id == type(^run_id, Ecto.UUID) and a.fingerprint == ^fingerprint and
            a.inserted_at >= ^since
      )
    )
  end

  @doc """
  The rebuilds queued before `before` (naive UTC) whose remote lease is
  still waiting or building: a lease of the same package and version, at
  `priority` with a systems filter, written at or after the attempt. Their
  `Portal.Workers.RemoteBuild` jobs finished once the lease was written and
  Oban prunes those after 12 hours, while a lease can wait for days.
  """
  @spec waiting_leases(NaiveDateTime.t(), integer()) :: non_neg_integer()
  def waiting_leases(before, priority) do
    %{rows: [[count]]} =
      Repo.query!(
        """
        SELECT count(DISTINCT a.id)
        FROM firmware_drift_attempts a
        JOIN builder_leases l
          ON l.package = a.package AND l.version = a.version AND l.inserted_at >= a.inserted_at
        WHERE a.inserted_at < $1
          AND l.state IN ('queued', 'leased', 'uploading')
          AND l.priority = $2
          AND jsonb_typeof(l.args->'systems_filter') = 'array'
        """,
        [before, priority]
      )

    count
  end

  @doc "Records that a rebuild of `run` with `fingerprint` was queued now."
  @spec record(map(), [String.t()], String.t()) :: :ok
  def record(run, systems, fingerprint) do
    Repo.query!(
      """
      INSERT INTO firmware_drift_attempts (run_id, package, version, fingerprint, systems)
      VALUES ($1, $2, $3, $4, $5)
      ON CONFLICT (run_id, fingerprint) DO UPDATE SET inserted_at = EXCLUDED.inserted_at
      """,
      [Ecto.UUID.dump!(run.run_id), run.package, run.version, fingerprint, systems]
    )

    :ok
  end
end
