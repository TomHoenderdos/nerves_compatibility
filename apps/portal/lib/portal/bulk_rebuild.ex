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

  alias Portal.AdminEvents
  alias Portal.Catalog.BulkSweep
  alias Portal.Repo
  alias Portal.Workers.Backfill

  # The worker's default systems (`NccWorker.Systems` `@default`). The portal
  # does not depend on the worker app, so the list is repeated here; keep the
  # two in step.
  @targets ~w(nerves_system_bbb nerves_system_mangopi_mq_pro nerves_system_qemu_aarch64
              nerves_system_rpi0 nerves_system_rpi0_2 nerves_system_rpi4 nerves_system_rpi5
              nerves_system_trellis nerves_system_x86_64)

  # Oban states in which a job has not started yet, so cancelling it stops the
  # work rather than interrupting it.
  @waiting ~w(available scheduled retryable)

  # A sweep's build job is local or remote per `Portal.Builders.Routing`; both
  # count the same.
  @build_workers ~w(Portal.Workers.Build Portal.Workers.RemoteBuild)

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
          cancelled: non_neg_integer(),
          remaining: non_neg_integer()
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
    * `:pin_local` -- build on this host only, never on a remote builder
      (`Portal.Builders.revoke/1` sets it); carried as `"pin_local"` in the
      Backfill job args

  A dry run, or an empty selection, returns `sweep_id: nil`.
  """
  @spec run(keyword()) ::
          {:ok,
           %{sweep_id: String.t() | nil, selected: non_neg_integer(), enqueued: non_neg_integer()}}
          | {:error, term()}
  def run(opts) do
    limit = Keyword.fetch!(opts, :limit)

    with {:ok, what, systems} <- what(Keyword.get(opts, :what, :full)) do
      # `Oban.insert_all/1` does not check `unique`, so a name given twice
      # would be two jobs.
      names = Enum.uniq(Keyword.get(opts, :names) || selection(limit, opts))

      cond do
        Keyword.get(opts, :dry_run, false) ->
          {:ok, %{sweep_id: nil, selected: length(names), enqueued: 0}}

        names == [] ->
          {:ok, %{sweep_id: nil, selected: 0, enqueued: 0}}

        true ->
          names |> enqueue(what, systems, opts) |> announce_sweep_started()
      end
    end
  end

  # A dry run and an empty selection both return before `enqueue/4`, so they
  # never reach here; only a sweep that actually queued jobs tells the
  # Maintenance page to refresh. `Ash.create/3` failing inside `enqueue/4`
  # means nothing was queued either, so only `{:ok, _}` announces.
  defp announce_sweep_started({:ok, _result} = result) do
    AdminEvents.broadcast(:sweeps)
    result
  end

  defp announce_sweep_started(result), do: result

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
      as: :package,
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
      # A package still waiting on an open request -- often from an earlier
      # sweep that has not reached it -- is left to that request, so a second
      # stalest-first sweep picks the next packages instead of the same ones.
      where:
        not exists(
          from(r in "portal_scan_requests",
            where:
              r.package_name == parent_as(:package).name and
                r.status in ["pending", "accepted", "queued"],
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
                 opts
                 |> Keyword.take([:limit, :order, :status, :names, :pin_local])
                 |> Map.new(fn {k, v} -> {k, inspect(v)} end),
               selected: length(names),
               created_by: Keyword.get(opts, :created_by)
             },
             action: :create,
             domain: Portal.Catalog
           ) do
      stagger = Keyword.get(opts, :stagger_ms, 1000)
      pin_local = Keyword.get(opts, :pin_local, false) == true
      now = DateTime.utc_now()

      inserted =
        names
        |> Enum.with_index()
        |> Enum.map(fn {name, i} ->
          job(name, i, {what, systems, pin_local}, sweep.id, now, stagger)
        end)
        |> Enum.chunk_every(@chunk)
        |> Enum.flat_map(&Oban.insert_all/1)
        |> Enum.reject(& &1.conflict?)

      {:ok, %{sweep_id: sweep.id, selected: length(names), enqueued: length(inserted)}}
    end
  end

  defp job(name, index, {what, systems, pin_local}, sweep_id, now, stagger) do
    %{
      "package" => name,
      "source" => "backfill",
      "force" => true,
      "scope" => what,
      "sweep_id" => sweep_id
    }
    |> then(&if(systems, do: Map.put(&1, "systems", systems), else: &1))
    |> then(&if(pin_local, do: Map.put(&1, "pin_local", true), else: &1))
    |> Backfill.new(
      scheduled_at: DateTime.add(now, index * stagger, :millisecond),
      meta: %{sweep_id: sweep_id}
    )
  end

  @doc """
  The sweep's jobs counted by stage: Backfill jobs not yet finished are
  `intake`; Build jobs are `queued`, `building` or `done`; any kind
  discarded is `failed` and any kind cancelled is `cancelled`.
  `remaining` is intake + queued + building.

  A `Portal.Workers.RemoteBuild` job counts like a Build job until it
  completes, which it does as soon as it has written its lease. A completed
  one counts by the state of its request's newest lease instead: `queued` is
  `queued`, `leased` or `uploading` is `building`, `done` is `done` and
  `failed` is `failed`. One with no lease deduped against an existing run and
  is `done`.

  Counts come from Oban, whose Pruner deletes finished jobs (completed,
  discarded, cancelled) once they are older than its `max_age`
  (`config/config.exs`). `done`, `failed` and `cancelled` shrink when that
  happens; `remaining` does not, because unfinished jobs are never pruned.
  """
  @spec status(String.t()) :: status()
  def status(sweep_id) do
    counts =
      Repo.all(
        from(j in "oban_jobs",
          where: ^sweep_jobs(sweep_id),
          group_by: [j.worker, j.state],
          select: {j.worker, j.state, count()}
        )
      )

    empty = %{intake: 0, queued: 0, building: 0, done: 0, failed: 0, cancelled: 0}

    counts
    |> Enum.reduce(empty, fn {worker, state, n}, acc -> tally(acc, worker, state, n) end)
    |> then(
      &Enum.reduce(remote_lease_counts(sweep_id), &1, fn {state, n}, acc ->
        tally_lease(acc, state, n)
      end)
    )
    |> then(&Map.put(&1, :remaining, &1.intake + &1.queued + &1.building))
  end

  # JSONB containment rather than `meta ->> 'sweep_id'`: Oban's GIN index on
  # `meta` (`oban_jobs_meta_index`) serves `@>`, not a text extraction.
  defp sweep_jobs(sweep_id),
    do: dynamic([j], fragment("? @> ?", j.meta, type(^%{"sweep_id" => sweep_id}, :map)))

  defp tally(acc, _worker, "cancelled", n), do: add(acc, :cancelled, n)

  # A Backfill job discarded after its retries -- hex.pm unreachable, a
  # request it could not open -- never became a build, but it is a failure.
  defp tally(acc, _worker, "discarded", n), do: add(acc, :failed, n)

  defp tally(acc, "Portal.Workers.Backfill", state, n)
       when state in @waiting or state == "executing",
       do: add(acc, :intake, n)

  defp tally(acc, worker, state, n) when worker in @build_workers and state in @waiting,
    do: add(acc, :queued, n)

  defp tally(acc, worker, "executing", n) when worker in @build_workers,
    do: add(acc, :building, n)

  # Counted by its lease instead; see `remote_lease_counts/1`.
  defp tally(acc, "Portal.Workers.RemoteBuild", "completed", _n), do: acc
  defp tally(acc, worker, "completed", n) when worker in @build_workers, do: add(acc, :done, n)
  defp tally(acc, _worker, _state, _n), do: acc

  # The sweep's completed RemoteBuild jobs, grouped by the state of the newest
  # lease for each job's scan request (nil when it wrote none).
  defp remote_lease_counts(sweep_id) do
    Repo.all(
      from(j in "oban_jobs",
        where: ^sweep_jobs(sweep_id),
        where: j.worker == "Portal.Workers.RemoteBuild" and j.state == "completed",
        left_lateral_join:
          l in fragment(
            """
            SELECT state FROM builder_leases
            WHERE scan_request_id::text = (? ->> 'scan_request_id')
            ORDER BY inserted_at DESC
            LIMIT 1
            """,
            j.args
          ),
        on: true,
        group_by: l.state,
        select: {l.state, count()}
      )
    )
  end

  defp tally_lease(acc, "queued", n), do: add(acc, :queued, n)

  defp tally_lease(acc, state, n) when state in ["leased", "uploading"],
    do: add(acc, :building, n)

  defp tally_lease(acc, "failed", n), do: add(acc, :failed, n)
  defp tally_lease(acc, _done_or_none, n), do: add(acc, :done, n)

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
    n = cancel_waiting(sweep_id)

    # Only when something was actually waiting to be stopped: a cancel of a
    # sweep that already finished moves nothing the Maintenance page shows.
    if n > 0, do: AdminEvents.broadcast(:sweeps)

    {:ok, n}
  end

  @doc """
  `cancel/1` for every sweep `query` selects: the Maintenance page's bulk
  action, which Cinder calls with a query filtered to the ticked rows.
  Returns the total of jobs cancelled across them as `ok`, in the
  `%{ok: _, failed: _}` shape the admin bulk actions share; cancelling
  cannot refuse a sweep, so `failed` is always empty.

  Announces once for the lot rather than once per sweep, and only when
  something was waiting.
  """
  @spec bulk_cancel(Ash.Query.t(), keyword()) ::
          {:ok, %{ok: non_neg_integer(), failed: []}} | {:error, term()}
  def bulk_cancel(query, opts) do
    with {:ok, sweeps} <-
           Ash.read(query, Keyword.take(opts, [:actor]) ++ [domain: Portal.Catalog]) do
      total = sweeps |> Enum.map(&cancel_waiting(&1.id)) |> Enum.sum()
      if total > 0, do: AdminEvents.broadcast(:sweeps)
      {:ok, %{ok: total, failed: []}}
    end
  end

  defp cancel_waiting(sweep_id) do
    {:ok, n} =
      Oban.cancel_all_jobs(
        from(j in Oban.Job,
          where: ^sweep_jobs(sweep_id),
          where: j.state in @waiting
        )
      )

    with {:ok, sweep} <- Ash.get(BulkSweep, sweep_id, domain: Portal.Catalog) do
      sweep |> Ash.Changeset.for_update(:cancel, %{}) |> Ash.update!(domain: Portal.Catalog)
    end

    n
  end

  @doc """
  Turns the Maintenance page's bulk rebuild form into `run/1` options.

  Every field falls back to its default when missing or not one of the
  values the form offers, since a forged submit may carry anything: the
  limit to 100 (outside 1..20,000 too), the order to `:stalest`, the
  result filter to none and the scope to `:full`. Only known targets are
  kept, and `"targets"` with none of them left is `what: :no_targets`, which
  `run/1` does not accept; the caller refuses it with its own message.
  """
  @spec opts_from_params(map(), String.t() | nil) :: keyword()
  def opts_from_params(params, created_by) do
    # The controller read `limit` with `Integer.parse/1` straight away, which
    # raises on a forged non-string value; it falls back like any other here.
    limit =
      with value when is_binary(value) <- Map.get(params, "limit", "100"),
           {n, _} when n in 1..20_000 <- Integer.parse(value) do
        n
      else
        _ -> 100
      end

    systems = Enum.filter(List.wrap(params["systems"]), &(&1 in @targets))

    what =
      case {params["what"], systems} do
        {"argus_only", _} -> :argus_only
        {"targets", []} -> :no_targets
        {"targets", systems} -> {:targets, systems}
        _ -> :full
      end

    [
      limit: limit,
      order: if(params["order"] == "catalog", do: :catalog, else: :stalest),
      status: Map.get(%{"pass" => :pass, "fail" => :fail, "error" => :error}, params["status"]),
      what: what,
      dry_run: params["mode"] == "dry_run",
      created_by: created_by
    ]
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
