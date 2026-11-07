defmodule Portal.Precompiled.PureElixirWithdrawal do
  @moduledoc """
  Counts, then withdraws, the `pure_elixir` publications of full runs that
  the compile-time trace has since refused (precompiled portability spec,
  section 7 and open question 3: "count first, act second"). Nothing runs
  this on its own: no job and no schedule calls it. The operator counts,
  reads the list, and acts.

  ## What is withdrawn

  A version of a package is a candidate when its toolchain build on the full
  run's toolchain (`"1.20/29"`), at the current `Portal.Toolchains`
  `builder_version` and in the `:with` variant (the one a full run's
  optional-dependency pass matches), is unrevoked, traced
  (`compile_observations` set) and `skipped` for an R1 or R2 reason
  (`Compatibility.Portability.withdrawing_prefixes/0`): a host read, a host read in `mix.exs`, a write
  outside `ebin`, a tracing or system flag, an Elixir patch dependence, or a
  baked build path. Those say the package's own compile observed the host
  (or read the Elixir version in a way that differs between patches).

  R3 closure taint (`closure dependency observed the host: `), a call into a
  natively built dependency, the rebar3 rules, "portability could not be
  judged" and rule 1's reasons never withdraw: they speak of a dependency, of
  the trace's own coverage or of what P0 already judged, not of the
  package's own compile. `held/1` lists the trace refusals left alone, for a hand check.

  Withdrawing a version sets `unpublished_at` on **every** `pure_elixir`
  system result of it that still has files: the newest run's, every older
  run's (or it would move up into the manifest) and every carried copy
  (`carried_from_run_id`), which the one withheld predicate in
  `Portal.Catalog` then hides everywhere. Firmware results of the same runs
  are never touched. One `UPDATE` per version, which re-checks the refusal
  as it runs, so a version is withdrawn whole or not at all.

  Only results built without the trace are withdrawn: acting takes a
  `before:` cutoff and touches a result only when the run that built it (for
  a carried copy, the run it was carried from) was inserted before it. A
  full run built on a traced worker image published its `pure_elixir` files
  only because its own traced compile passed, a verdict the portal does not
  store, so the toolchain build's refusal is not evidence against it.

  Choose `before:` only once every build made on the untraced image has been
  ingested, and take a time after the last of them: a build host's job that
  started before the deploy, and above all a remote builder's lease queued
  before it (it names the old image digest, and a builder may run it well
  after the deploy) still publish untraced results that are inserted after
  the deploy time. Wait until no `Portal.Builders.Lease` with the old
  `image_digest` is queued or running and no `Portal.Workers.Build` job from
  before the deploy is left; a cutoff earlier than the last such run leaves
  those untraced publications in place.

  ## Safety

    * `withdraw/1` counts unless given `dry_run: false`, and acting without
      `before:` returns `{:error, :before_required}` and writes nothing;
    * one call withdraws at most `limit:` versions (default 50);
    * it is idempotent: a withdrawn row is no longer a candidate, and rows
      already withdrawn some other way keep their own `unpublished_at`;
    * every row one call withdraws carries the same `unpublished_at`
      (`withdrawn_at` in the result, listed by `withdrawals/0`), and
      `undo/1` sets the `pure_elixir` rows with that timestamp back to
      `nil`. The match is by timestamp alone: a `pure_elixir` result
      withdrawn through `SystemResult`'s `:withdraw_publication` action in
      the very same microsecond would be listed and put back with it.

  Run it only once both hosts run a release with `unpublished_at`: an older
  release's partial-run ingest copies a carried result without it (a
  later call withdraws such a copy too).

  ## Operator commands (web host)

      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdraw() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.held() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdraw(before: ~U[2026-11-08 09:00:00Z]) |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdraw(dry_run: false, before: ~U[2026-11-08 09:00:00Z], limit: 50) |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdrawals() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.undo(~U[2026-11-07 12:00:00.000000Z]) |> IO.inspect()'

  The first lists every candidate with each result's `built_at`, so the
  split at the cutoff shows; the third lists what that cutoff would
  withdraw. `~U[2026-11-08 09:00:00Z]` stands for the cutoff chosen as
  above.
  Repeat the fourth until it returns `{:withdrawn, 0, []}`.
  """

  require Logger

  alias Compatibility.Portability
  alias Portal.Repo

  @toolchain "1.20/29"
  @default_limit 50

  # `$1` toolchain, `$2` builder_version, `$3` the prefixes, `$4` the
  # package name and `$5` the version (nulls: every version), `$6` the
  # cutoff (null: none). `s` is any pure_elixir result of a run of the
  # version, carried copies included, that still has files and is not
  # withdrawn; `b` is the run it was carried from, so `coalesce(b, r)` is
  # the run that built it, which the cutoff applies to.
  @rows """
  FROM catalog_toolchain_builds t
  JOIN catalog_packages p ON p.id = t.package_id
  JOIN catalog_runs r ON r.package_id = t.package_id AND r.version_tested = t.version
  JOIN catalog_system_results s ON s.run_id = r.id
  LEFT JOIN catalog_runs b ON b.id = s.carried_from_run_id
  WHERE t.toolchain = $1
    AND t.builder_version = $2
    AND t.variant = 'with'
    AND t.status = 'skipped'
    AND t.revoked_at IS NULL
    AND t.compile_observations IS NOT NULL
    AND EXISTS (SELECT 1 FROM unnest($3::text[]) AS pre(prefix)
                WHERE starts_with(t.reason, pre.prefix))
    AND ($4::text IS NULL OR (p.name = $4 AND t.version = $5))
    AND ($6::timestamp IS NULL OR coalesce(b.inserted_at, r.inserted_at) < $6::timestamp)
    AND s.system_pkg = 'pure_elixir'
    AND s.unpublished_at IS NULL
    AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = s.id)
  """

  @candidates_sql """
  SELECT p.name, t.version, t.reason, t.id,
         array_agg(s.id ORDER BY coalesce(b.inserted_at, r.inserted_at), s.id),
         array_agg(coalesce(b.inserted_at, r.inserted_at)
                   ORDER BY coalesce(b.inserted_at, r.inserted_at), s.id)
  #{@rows}
  GROUP BY p.name, t.version, t.reason, t.id
  ORDER BY p.name, t.version
  """

  @withdraw_sql """
  UPDATE catalog_system_results
  SET unpublished_at = $7, updated_at = $7
  WHERE id IN (SELECT s.id #{@rows})
  """

  @withdrawals_sql """
  SELECT s.unpublished_at, count(*), array_agg(DISTINCT p.name || ' ' || r.version_tested)
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  JOIN catalog_packages p ON p.id = r.package_id
  WHERE s.system_pkg = 'pure_elixir' AND s.unpublished_at IS NOT NULL
  GROUP BY s.unpublished_at
  ORDER BY s.unpublished_at
  """

  @undo_sql """
  UPDATE catalog_system_results
  SET unpublished_at = NULL, updated_at = now() AT TIME ZONE 'utc'
  WHERE system_pkg = 'pure_elixir' AND unpublished_at = $1
  """

  @type result :: %{id: String.t(), built_at: DateTime.t()}
  @type candidate :: %{
          package: String.t(),
          version: String.t(),
          reason: String.t(),
          toolchain_build_id: String.t(),
          results: [result()]
        }

  @doc """
  The versions `withdraw/1` would act on for `toolchain`, by package and
  version, each with every result it would withdraw and `built_at`, when
  the run that built that result was inserted (no cutoff applied).
  Read-only.
  """
  @spec candidates(String.t()) :: [candidate()]
  def candidates(toolchain \\ @toolchain),
    do: select(toolchain, Portability.withdrawing_prefixes(), nil)

  @doc """
  The published versions whose toolchain build the trace refused for a
  reason that does not withdraw (R3 taint, a native call, the rebar3
  rules), for a hand check. Read-only; nothing ever acts on it.
  """
  @spec held(String.t()) :: [candidate()]
  def held(toolchain \\ @toolchain),
    do:
      select(toolchain, Portability.refusal_prefixes() -- Portability.withdrawing_prefixes(), nil)

  @doc """
  Counts (the default) or withdraws the candidates.

  Options: `dry_run:` (`true`), `before:` (a `DateTime`, required to act:
  only results built by runs inserted before it are withdrawn), `limit:`
  (#{@default_limit}, the most versions one call withdraws), `toolchain:`
  (`"#{@toolchain}"`).

  Returns `{:dry_run, candidates}` (every one, or with `before:` only what
  that cutoff would withdraw), `{:error, :before_required}` for an act
  without `before:` (nothing written), or `{:withdrawn, rows, withdrawn}`
  where `rows` counts the system results changed and each withdrawn
  candidate carries `withdrawn_at`, the value `undo/1` takes.
  """
  @spec withdraw(keyword()) ::
          {:dry_run, [candidate()]}
          | {:withdrawn, non_neg_integer(), [candidate()]}
          | {:error, :before_required}
  def withdraw(opts \\ []) do
    toolchain = Keyword.get(opts, :toolchain, @toolchain)
    limit = Keyword.get(opts, :limit, @default_limit)
    before = opts |> Keyword.get(:before) |> cutoff()

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "limit must be a positive integer, got: #{inspect(limit)}")

    cond do
      Keyword.get(opts, :dry_run, true) ->
        {:dry_run, select(toolchain, Portability.withdrawing_prefixes(), before)}

      is_nil(before) ->
        {:error, :before_required}

      true ->
        toolchain
        |> select(Portability.withdrawing_prefixes(), before)
        |> Enum.take(limit)
        |> act(toolchain, before)
    end
  end

  @doc """
  Every `pure_elixir` withdrawal on record, grouped by its `unpublished_at`:
  `%{withdrawn_at, results, versions}`, oldest first. The grouping is by
  timestamp alone: a result withdrawn through `SystemResult`'s
  `:withdraw_publication` action in the very same microsecond would be
  listed with this module's call.
  """
  @spec withdrawals() :: [
          %{withdrawn_at: DateTime.t(), results: pos_integer(), versions: [String.t()]}
        ]
  def withdrawals do
    %{rows: rows} = Repo.query!(@withdrawals_sql, [])

    Enum.map(rows, fn [at, count, versions] ->
      %{withdrawn_at: to_utc(at), results: count, versions: Enum.sort(versions)}
    end)
  end

  @doc """
  Puts back the `pure_elixir` results whose `unpublished_at` equals
  `withdrawn_at`, which is the rows one `withdraw/1` call took out. The
  match is by timestamp alone: a `pure_elixir` result withdrawn through
  `:withdraw_publication` in the very same microsecond would be put back
  too. Returns how many.
  """
  @spec undo(DateTime.t() | NaiveDateTime.t()) :: {:restored, non_neg_integer()}
  def undo(%DateTime{} = withdrawn_at), do: withdrawn_at |> naive_utc() |> undo()

  def undo(%NaiveDateTime{} = withdrawn_at) do
    %{num_rows: count} = Repo.query!(@undo_sql, [withdrawn_at])
    Logger.warning("restored #{count} pure_elixir publications withdrawn at #{withdrawn_at}")
    {:restored, count}
  end

  defp cutoff(nil), do: nil
  defp cutoff(%DateTime{} = before), do: naive_utc(before)

  defp cutoff(other),
    do: raise(ArgumentError, "before: must be a DateTime, got: #{inspect(other)}")

  defp select(toolchain, prefixes, before) do
    %{rows: rows} =
      Repo.query!(@candidates_sql, [toolchain, builder_version(), prefixes, nil, nil, before])

    Enum.map(rows, fn [name, version, reason, tb_id, ids, built] ->
      %{
        package: name,
        version: version,
        reason: reason,
        toolchain_build_id: Ecto.UUID.load!(tb_id),
        results: Enum.zip_with(ids, built, &%{id: Ecto.UUID.load!(&1), built_at: to_utc(&2)})
      }
    end)
  end

  # One statement per version, so each is withdrawn whole or not at all and
  # the refusal and the cutoff are re-checked as it runs; one
  # `unpublished_at` per call.
  defp act(found, toolchain, before) do
    at = NaiveDateTime.utc_now()
    params = [toolchain, builder_version(), Portability.withdrawing_prefixes()]

    {rows, done} =
      Enum.reduce(found, {0, []}, fn candidate, {rows, done} ->
        %{num_rows: n} =
          Repo.query!(
            @withdraw_sql,
            params ++ [candidate.package, candidate.version, before, at]
          )

        if n > 0 do
          Logger.warning(
            "withdrew #{n} pure_elixir publications of #{candidate.package} " <>
              "#{candidate.version} at #{at}: #{candidate.reason}"
          )

          {rows + n, [Map.put(candidate, :withdrawn_at, to_utc(at)) | done]}
        else
          {rows, done}
        end
      end)

    {:withdrawn, rows, Enum.reverse(done)}
  end

  defp builder_version, do: Portal.Toolchains.builder_version()

  defp naive_utc(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
