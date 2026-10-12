defmodule Portal.BulkRebuild do
  @moduledoc """
  Rebuilds a chosen set of packages, typically after a worker or argus change.

  Each package becomes a `Portal.Workers.Backfill` job, staggered one per
  second for the same reason `Portal.CatalogSeed` staggers its jobs: every
  one asks hex.pm for the current version. The jobs carry `force` (the
  package was built before, at this image or another), a scope -- every
  target, a subset, or argus only (`Portal.Workers.Build.scope_args/3`) --
  and the sweep's id in `meta.sweep_id`, which is how `status/1` and
  `cancel/1` find them. Requests are not used for that: they belong to
  `Portal.Workers.RequestSync`, which deletes ours once they finish.

  Only packages whose latest run is a real build are selected: a registry-only
  assessment (`registry_deps`) stays one, and a package that never built has
  nothing to rebuild.
  """

  import Ecto.Query

  alias Portal.Catalog.BulkSweep
  alias Portal.Repo
  alias Portal.Workers.Backfill

  # The worker's default systems (`NccWorker.Systems` `@default`). The portal
  # does not depend on the worker app, so the list is repeated here; keep the
  # two in step.
  @targets ~w(nerves_system_bbb nerves_system_mangopi_mq_pro nerves_system_qemu_aarch64
              nerves_system_rpi0 nerves_system_rpi4 nerves_system_rpi5 nerves_system_trellis
              nerves_system_x86_64)

  # Oban states in which a job has not started yet, so cancelling it stops the
  # work rather than interrupting it.
  @waiting ~w(available scheduled retryable)

  # `Oban.insert_all/1` sends one statement per call; 500 jobs keeps each well
  # under Postgres' 65,535 bind-parameter limit.
  @chunk 500

  @type what :: :full | :argus_only | {:targets, [String.t()]}

  @type status :: %{
          intake: non_neg_integer(),
          queued: non_neg_integer(),
          building: non_neg_integer(),
          done: non_neg_integer(),
          failed: non_neg_integer(),
          cancelled: non_neg_integer()
        }

  @doc "The systems a full rebuild builds: the worker's default list."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @doc """
  Selects packages and queues one `Portal.Workers.Backfill` job for each.

  Options:

    * `:limit` (required) -- at most this many packages are selected
    * `:order` -- `:stalest` (default; oldest `last_run_at` first) or
      `:catalog` (the order packages were added)
    * `:status` -- `nil` (default), `:pass`, `:fail` or `:error`: only
      packages whose latest run has that overall status
    * `:names` -- rebuild exactly these packages instead of selecting
    * `:what` -- `:full` (default), `:argus_only` or `{:targets, systems}`
    * `:dry_run` -- count the selection, write and queue nothing
    * `:stagger_ms` -- gap between consecutive jobs (default 1000)
    * `:created_by` -- who started the sweep, kept on the `BulkSweep` row

  A dry run, or an empty selection, returns `sweep_id: nil`.
  """
  @spec run(keyword()) ::
          {:ok,
           %{sweep_id: String.t() | nil, selected: non_neg_integer(), enqueued: non_neg_integer()}}
          | {:error, term()}
  def run(opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, what, systems} <- what(Keyword.get(opts, :what, :full)) do
      names = Keyword.get(opts, :names) || selection(limit, opts)

      cond do
        Keyword.get(opts, :dry_run, false) ->
          {:ok, %{sweep_id: nil, selected: length(names), enqueued: 0}}

        names == [] ->
          {:ok, %{sweep_id: nil, selected: 0, enqueued: 0}}

        true ->
          enqueue(names, what, systems, opts)
      end
    end
  end

  defp what(:full), do: {:ok, "full", nil}
  defp what(:argus_only), do: {:ok, "argus_only", nil}

  defp what({:targets, [_ | _] = systems}) do
    case systems -- @targets do
      [] -> {:ok, "targets", systems}
      unknown -> {:error, {:unknown_systems, unknown}}
    end
  end

  defp what(other), do: {:error, {:invalid_what, other}}

  defp selection(limit, opts) do
    # The latest-run rule `Portal.Catalog` applies everywhere: newest
    # `finished_at`, then newest `inserted_at`, plain DESC.
    latest =
      from(r in "catalog_runs",
        distinct: r.package_id,
        order_by: [asc: r.package_id, desc: r.finished_at, desc: r.inserted_at],
        select: %{id: r.id, package_id: r.package_id, overall_status: r.overall_status}
      )

    from(p in "catalog_packages",
      join: l in subquery(latest),
      as: :latest,
      on: l.package_id == p.id,
      # `host` is in every real worker run, and in nothing else: registry
      # assessments, tooling skips and forced skips never compile.
      where:
        exists(
          from(s in "catalog_system_results",
            where: s.run_id == parent_as(:latest).id and s.system_pkg == "host",
            select: 1
          )
        ),
      limit: ^limit,
      select: p.name
    )
    |> filter_status(Keyword.get(opts, :status))
    |> order(Keyword.get(opts, :order, :stalest))
    |> Repo.all()
  end

  defp filter_status(query, nil), do: query

  # `catalog_runs.overall_status` is a text column.
  defp filter_status(query, status) when status in [:pass, :fail, :error],
    do: where(query, [_p, l], l.overall_status == ^Atom.to_string(status))

  # Stalest first: what was built longest ago, or never stamped, goes first.
  defp order(query, :stalest),
    do: order_by(query, [p], asc_nulls_first: p.last_run_at, asc: p.name)

  defp order(query, :catalog), do: order_by(query, [p], asc: p.inserted_at, asc: p.name)

  defp enqueue(names, what, systems, opts) do
    with {:ok, sweep} <-
           Ash.create(
             BulkSweep,
             %{
               what: what,
               systems: systems,
               options:
                 Map.new(Keyword.take(opts, [:limit, :order, :status, :names]), fn {k, v} ->
                   {k, inspect(v)}
                 end),
               selected: length(names),
               created_by: Keyword.get(opts, :created_by)
             },
             action: :create,
             domain: Portal.Catalog
           ) do
      stagger = Keyword.get(opts, :stagger_ms, 1000)
      now = DateTime.utc_now()

      inserted =
        names
        |> Enum.with_index()
        |> Enum.map(fn {name, i} -> job(name, i, what, systems, sweep.id, now, stagger) end)
        |> Enum.chunk_every(@chunk)
        |> Enum.flat_map(&Oban.insert_all/1)
        |> Enum.reject(& &1.conflict?)

      {:ok, %{sweep_id: sweep.id, selected: length(names), enqueued: length(inserted)}}
    end
  end

  defp job(name, index, what, systems, sweep_id, now, stagger) do
    %{
      "package" => name,
      "source" => "backfill",
      "force" => true,
      "scope" => what,
      "sweep_id" => sweep_id
    }
    |> then(&if(systems, do: Map.put(&1, "systems", systems), else: &1))
    |> Backfill.new(
      scheduled_at: DateTime.add(now, index * stagger, :millisecond),
      meta: %{sweep_id: sweep_id}
    )
  end

  @doc """
  The sweep's jobs counted by stage: Backfill jobs not yet finished are
  `intake`; Build jobs are `queued`, `building`, `done` or `failed`; either
  kind cancelled is `cancelled`. Counts come from Oban, so they shrink once
  Oban prunes finished jobs.
  """
  @spec status(String.t()) :: status()
  def status(sweep_id) do
    counts =
      Repo.all(
        from(j in "oban_jobs",
          where: fragment("? ->> 'sweep_id'", j.meta) == ^sweep_id,
          group_by: [j.worker, j.state],
          select: {j.worker, j.state, count()}
        )
      )

    empty = %{intake: 0, queued: 0, building: 0, done: 0, failed: 0, cancelled: 0}
    Enum.reduce(counts, empty, fn {worker, state, n}, acc -> tally(acc, worker, state, n) end)
  end

  defp tally(acc, _worker, "cancelled", n), do: add(acc, :cancelled, n)

  defp tally(acc, "Portal.Workers.Backfill", state, n)
       when state in @waiting or state == "executing",
       do: add(acc, :intake, n)

  defp tally(acc, "Portal.Workers.Build", state, n) when state in @waiting,
    do: add(acc, :queued, n)

  defp tally(acc, "Portal.Workers.Build", "executing", n), do: add(acc, :building, n)
  defp tally(acc, "Portal.Workers.Build", "completed", n), do: add(acc, :done, n)
  defp tally(acc, "Portal.Workers.Build", "discarded", n), do: add(acc, :failed, n)
  defp tally(acc, _worker, _state, _n), do: acc

  defp add(acc, key, n), do: Map.update!(acc, key, &(&1 + n))

  @doc """
  Cancels the sweep's Backfill and Build jobs that have not started, and
  stamps the sweep's `cancelled_at`. Jobs already executing finish. Returns
  how many jobs were cancelled.

  The scan requests those jobs opened are not touched here:
  `Portal.Workers.RequestSync` deletes a sweep's requests: a finished one a
  day later, and one left with no live Build job -- a cancelled one -- on its
  next pass.
  """
  @spec cancel(String.t()) :: {:ok, non_neg_integer()}
  def cancel(sweep_id) do
    {:ok, n} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where: fragment("? ->> 'sweep_id'", j.meta) == ^sweep_id,
          where: j.state in @waiting
        )
      )

    with {:ok, sweep} <- Ash.get(BulkSweep, sweep_id, domain: Portal.Catalog) do
      sweep |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update!(domain: Portal.Catalog)
    end

    {:ok, n}
  end

  @doc "The newest sweeps, newest first."
  @spec recent(pos_integer()) :: [BulkSweep.t()]
  def recent(limit \\ 10) do
    BulkSweep
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(domain: Portal.Catalog)
  end
end
