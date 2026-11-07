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
  (`withdrawing_prefixes/0`): a host read, a host read in `mix.exs`, a write
  outside `ebin`, a tracing or system flag, or a baked build path. Those say
  the package's own compile observed the host.

  R3 closure taint (`closure dependency observed the host: `), a call into a
  natively built dependency, the rebar3 rules, "portability could not be
  judged" and rule 1's reasons never withdraw (controller ruling m4): they
  speak of a dependency, of the trace's own coverage or of what P0 already
  judged. `held/1` lists the trace refusals left alone, for a hand check.

  Withdrawing a version sets `unpublished_at` on **every** `pure_elixir`
  system result of it that still has files: the newest run's, every older
  run's (or it would move up into the manifest) and every carried copy
  (`carried_from_run_id`), which the one withheld predicate in
  `Portal.Catalog` then hides everywhere. Firmware results of the same runs
  are never touched. One `UPDATE` per version, which re-checks the refusal
  as it runs, so a version is withdrawn whole or not at all.

  ## Safety

    * `withdraw/1` counts unless given `dry_run: false`;
    * one call withdraws at most `limit:` versions (default 50);
    * it is idempotent: a withdrawn row is no longer a candidate, and rows
      already withdrawn some other way keep their own `unpublished_at`;
    * every row one call withdraws carries the same `unpublished_at`
      (`withdrawn_at` in the result, listed by `withdrawals/0`), and
      `undo/1` sets exactly those back to `nil`.

  Run it only once both hosts run a release with `unpublished_at`: an older
  release's partial-run ingest copies a carried result without it (a
  later call withdraws such a copy too).

  ## Operator commands (web host)

      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdraw() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.held() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdraw(dry_run: false, limit: 50) |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.withdrawals() |> IO.inspect(limit: :infinity)'
      bin/portal rpc 'Portal.Precompiled.PureElixirWithdrawal.undo(~U[2026-11-07 12:00:00.000000Z]) |> IO.inspect()'

  Repeat the third until it returns `{:withdrawn, 0, []}`.
  """

  require Logger

  alias Compatibility.Portability
  alias Portal.Repo

  @toolchain "1.20/29"
  @default_limit 50

  # R1 (the trace's events, R4's `mix.exs` slice included) and R2 (build
  # root). Every one is also in `Portability.refusal_prefixes/0`.
  @withdrawing_prefixes [
    "compile-time host read: ",
    "compile-time host read in mix.exs: ",
    "compile-time write outside ebin: ",
    "compile-time tracing or system flag: ",
    "bakes the build path: "
  ]

  # `$1` toolchain, `$2` builder_version, `$3` the prefixes, `$4` the
  # package name and `$5` the version, or nulls for every version. `s` is
  # any pure_elixir result of a run of the version, carried copies included,
  # that still has files and is not withdrawn.
  @rows """
  FROM catalog_toolchain_builds t
  JOIN catalog_packages p ON p.id = t.package_id
  JOIN catalog_runs r ON r.package_id = t.package_id AND r.version_tested = t.version
  JOIN catalog_system_results s ON s.run_id = r.id
  WHERE t.toolchain = $1
    AND t.builder_version = $2
    AND t.variant = 'with'
    AND t.status = 'skipped'
    AND t.revoked_at IS NULL
    AND t.compile_observations IS NOT NULL
    AND EXISTS (SELECT 1 FROM unnest($3::text[]) AS pre(prefix)
                WHERE starts_with(t.reason, pre.prefix))
    AND ($4::text IS NULL OR (p.name = $4 AND t.version = $5))
    AND s.system_pkg = 'pure_elixir'
    AND s.unpublished_at IS NULL
    AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = s.id)
  """

  @candidates_sql """
  SELECT p.name, t.version, t.reason, t.id, array_agg(s.id ORDER BY s.inserted_at, s.id)
  #{@rows}
  GROUP BY p.name, t.version, t.reason, t.id
  ORDER BY p.name, t.version
  """

  @withdraw_sql """
  UPDATE catalog_system_results
  SET unpublished_at = $6, updated_at = $6
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

  @type candidate :: %{
          package: String.t(),
          version: String.t(),
          reason: String.t(),
          toolchain_build_id: String.t(),
          result_ids: [String.t()]
        }

  @doc "The refusal prefixes that withdraw a publication: R1 and R2 only."
  @spec withdrawing_prefixes() :: [String.t()]
  def withdrawing_prefixes, do: @withdrawing_prefixes

  @doc """
  The versions `withdraw/1` would withdraw on `toolchain`, oldest package
  by package and version, each with every result id it would withdraw. Read-only.
  """
  @spec candidates(String.t()) :: [candidate()]
  def candidates(toolchain \\ @toolchain), do: select(toolchain, @withdrawing_prefixes)

  @doc """
  The published versions whose toolchain build the trace refused for a
  reason that does not withdraw (R3 taint, a native call, the rebar3
  rules), for a hand check. Read-only; nothing ever acts on it.
  """
  @spec held(String.t()) :: [candidate()]
  def held(toolchain \\ @toolchain),
    do: select(toolchain, Portability.refusal_prefixes() -- @withdrawing_prefixes)

  @doc """
  Counts (the default) or withdraws the candidates.

  Options: `dry_run:` (`true`), `limit:` (#{@default_limit}, the most
  versions one call withdraws), `toolchain:` (`"#{@toolchain}"`).

  Returns `{:dry_run, candidates}` (all of them), or `{:withdrawn, rows,
  withdrawn}` where `rows` counts the system results changed and each
  withdrawn candidate carries `withdrawn_at`, the value `undo/1` takes.
  """
  @spec withdraw(keyword()) ::
          {:dry_run, [candidate()]} | {:withdrawn, non_neg_integer(), [candidate()]}
  def withdraw(opts \\ []) do
    toolchain = Keyword.get(opts, :toolchain, @toolchain)
    limit = Keyword.get(opts, :limit, @default_limit)

    unless is_integer(limit) and limit > 0,
      do: raise(ArgumentError, "limit must be a positive integer, got: #{inspect(limit)}")

    found = candidates(toolchain)

    if Keyword.get(opts, :dry_run, true) do
      {:dry_run, found}
    else
      act(Enum.take(found, limit), toolchain)
    end
  end

  @doc """
  Every `pure_elixir` withdrawal on record, grouped by its `unpublished_at`:
  `%{withdrawn_at, results, versions}`, oldest first.
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
  Puts back the `pure_elixir` results one withdrawal took out: those whose
  `unpublished_at` is exactly `withdrawn_at`. Returns how many.
  """
  @spec undo(DateTime.t() | NaiveDateTime.t()) :: {:restored, non_neg_integer()}
  def undo(%DateTime{} = withdrawn_at),
    do: withdrawn_at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive() |> undo()

  def undo(%NaiveDateTime{} = withdrawn_at) do
    %{num_rows: count} = Repo.query!(@undo_sql, [withdrawn_at])
    Logger.warning("restored #{count} pure_elixir publications withdrawn at #{withdrawn_at}")
    {:restored, count}
  end

  defp select(toolchain, prefixes) do
    %{rows: rows} =
      Repo.query!(@candidates_sql, [toolchain, builder_version(), prefixes, nil, nil])

    Enum.map(rows, fn [name, version, reason, tb_id, ids] ->
      %{
        package: name,
        version: version,
        reason: reason,
        toolchain_build_id: Ecto.UUID.load!(tb_id),
        result_ids: Enum.map(ids, &Ecto.UUID.load!/1)
      }
    end)
  end

  # One statement per version, so each is withdrawn whole or not at all and
  # the refusal is re-checked as it runs; one `unpublished_at` per call.
  defp act(found, toolchain) do
    at = NaiveDateTime.utc_now()
    params = [toolchain, builder_version(), @withdrawing_prefixes]

    {rows, done} =
      Enum.reduce(found, {0, []}, fn candidate, {rows, done} ->
        %{num_rows: n} =
          Repo.query!(@withdraw_sql, params ++ [candidate.package, candidate.version, at])

        Logger.warning(
          "withdrew #{n} pure_elixir publications of #{candidate.package} " <>
            "#{candidate.version} at #{at}: #{candidate.reason}"
        )

        if n > 0,
          do: {rows + n, [Map.put(candidate, :withdrawn_at, to_utc(at)) | done]},
          else: {rows, done}
      end)

    {:withdrawn, rows, Enum.reverse(done)}
  end

  defp builder_version, do: Portal.Toolchains.builder_version()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
