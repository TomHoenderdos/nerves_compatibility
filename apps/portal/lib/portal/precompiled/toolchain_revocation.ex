defmodule Portal.Precompiled.ToolchainRevocation do
  @moduledoc """
  Revokes what rule 2 alone published (precompiled portability spec,
  section 10 "Rollback and revocation"): publications whose verdict was the
  static rules and the compile-time trace (`portability_rule` 2) and that
  the verdict before it, rule 1 (`portable?/4`), would have refused. Nothing
  runs this on its own.

  ## What is revoked

    * **Toolchain builds**: a passing build at the current `builder_version`
      with `portability_rule` 2 and a `rule1_reason` (rule 1's refusal,
      recorded beside the verdict). A build rule 1 also passed has no
      `rule1_reason` and is never touched. It gets `revoked_at` and
      `revoked_reason` `"rule 2 revoked"`: it is not served (manifests, the
      package list and `files/{sha256}`), the next signed batch drops it, and
      the backlog never rebuilds it at this `builder_version`.
    * **Full runs' `pure_elixir` results** with `portability_rule` 2 that
      still have files. The portal does not store what rule 1 said about a
      full run, so the result's own toolchain build stands in for it: the
      build of the same package and version on the full run's toolchain
      (`"1.20/29"`), at the current `builder_version`, in the `:with`
      variant (the one a full run's optional-dependency pass matches) and
      the default config, judged by rule 2 with a `rule1_reason`. Its
      status does not matter (rule 1 ran either way), and the row's
      `rule1_reason` is that build's. A result whose build rule 1 passed, or
      that has no such build yet, is not revoked; a later call reaches it
      once that build exists (or `everything: true` does now). Every
      `pure_elixir` row of the version is a candidate, carried copies
      included, though `limit:` may split one version's rows across calls.
      It gets `unpublished_at` (the one withheld predicate in
      `Portal.Catalog`) and `unpublished_reason` `"rule 2 revoked"`;
      firmware results are never touched. The revocation sticks: a carried
      copy keeps both, and ingest stores a later rule-2 `pure_elixir` result
      of the same version withdrawn with the same reason and timestamp.

  ## What a revocation does not cover

  A revocation sticks per identity and version, never per package. A
  revoked toolchain build keeps only its own identity (package, version,
  toolchain, `builder_version`, optional-dependency variant and config
  variant) from being rebuilt, and a revoked `pure_elixir` result only later
  results of its own package and version. Anything new still publishes
  under rule 2: the same version on the other toolchain, a `:without` build
  made after the call, a config variant, a later version. To stop those,
  repeat the call once they exist, or roll the worker image back to one
  that judges by rule 1.

  ## Emergency: `everything: true`

  Takes every rule-2 publication, whatever rule 1 said or whether anything
  recorded it: every passing toolchain build with `portability_rule` 2 at
  the current `builder_version` and every `pure_elixir` result with
  `portability_rule` 2 that still has files. It still only lists unless
  given `dry_run: false`, combines with `package:`, `version:` and
  `rule1_prefix:`, and is not capped unless given `limit:`. Rule 1's
  publications (`portability_rule` nil) are never touched.

  ## By judge revision: `judge_revision: n`

  Takes every passing toolchain build at the current `builder_version`
  with `portability_rule` 2 judged at revision `n` or later
  (`judge_revision >= n`), whatever rule 1 said: the one-call rollback of
  a judge refinement that shipped at revision `n` (precompiled judge
  refinements spec, "Revocation lever"). Full runs' `pure_elixir` results
  record no revision and are left alone, also when combined with
  `everything: true`: `judge_revision:` takes precedence over it for system
  results, so revoke those with a separate call. It counts as a filter for
  acting, combines with `package:`, `version:` and `rule1_prefix:`, and is
  capped by `limit:` like any call.

  It is coarse: it takes every rule-2 pass at revision `n` or later, not
  only those the refinement shipped at `n` made pass, so it also revokes
  packages every earlier revision passed. And a revoked row is rebuilt only
  on a `builder_version` bump, like any revocation: a fixed judge at a
  higher revision does not bring it back. Narrow it with `package:` or
  `rule1_prefix:` where the refinement's reach is known, or use `undo/1`.

  ## Safety

    * `revoke/1` only lists unless given `dry_run: false`, and acting needs
      `package:` (optionally with `version:`), `rule1_prefix:`,
      `judge_revision:`, `all: true` or `everything: true`, else it
      returns `{:error, :filter_required}`;
    * one call revokes at most `limit:` rows (default 50, toolchain builds
      and system results together; no default cap with `everything: true`),
      in package, version, kind and identity order; a dry run lists the same
      rows the same call would revoke;
    * acting is one statement, one `UPDATE ... RETURNING` per table over
      rows it locks first, and lists exactly the rows those updates changed;
    * it is idempotent: a revoked row no longer matches;
    * every row one call revokes carries the same timestamp (`revoked_at`
      or `unpublished_at`), which `revocations/0` lists and `undo/1` takes.
      Both match the reason as well, so they never list or put back what
      another tool withdrew (`Portal.Precompiled.PureElixirWithdrawal`'s
      withdrawals have no `unpublished_reason`).

  ## Operator commands (web host, through ops/portal-rpc.sh)

      Portal.Precompiled.ToolchainRevocation.revoke(all: true)
      Portal.Precompiled.ToolchainRevocation.revoke(dry_run: false, package: "phoenix", version: "1.8.16")
      Portal.Precompiled.ToolchainRevocation.revoke(dry_run: false, rule1_prefix: "calls erlang:open_port/", limit: 50)
      Portal.Precompiled.ToolchainRevocation.revoke(everything: true)
      Portal.Precompiled.ToolchainRevocation.revoke(dry_run: false, everything: true)
      Portal.Precompiled.ToolchainRevocation.revoke(dry_run: false, judge_revision: 1)
      Portal.Precompiled.ToolchainRevocation.revocations()
      Portal.Precompiled.ToolchainRevocation.undo(~U[2026-11-09 12:00:00.000000Z])

  Repeat an acting call until it returns `{:revoked, 0, [], _}`.
  """

  require Logger

  alias Portal.Repo

  @reason "rule 2 revoked"
  # The same text, for system results, where ingest reads it too.
  @result_reason Portal.Catalog.SystemResult.rule2_revocation()
  @default_limit 50
  # The toolchain a full run builds on, whose build says what rule 1 said
  # about a full run's `pure_elixir` result.
  @full_run_toolchain "1.20/29"

  @type row :: %{
          kind: :toolchain_build | :system_result,
          package: String.t(),
          version: String.t(),
          toolchain: String.t() | nil,
          variant: String.t() | nil,
          config_variant: String.t() | nil,
          rule1_reason: String.t() | nil,
          id: Ecto.UUID.t()
        }

  # $1 builder_version, $2 package (null: any), $3 version (null: any),
  # $4 rule1_reason prefix (null: any), $5 limit (null: none), $6 the full
  # run's toolchain, $7 everything (true: no rule-1 verdict needed), $8 the
  # lowest judge revision (null: any; given, no rule-1 verdict is needed and
  # system results are left alone: they record no revision). `<lock>` is
  # `FOR UPDATE OF t` / `OF s` when acting, empty for a dry run. Each kind
  # takes its first $5 rows, so the union's first $5 are the first $5 overall.
  @candidates """
  WITH tc AS (
    SELECT 'toolchain_build'::text AS kind, t.id, p.name, t.version, t.toolchain,
           t.variant::text AS variant, t.config_variant, t.rule1_reason
    FROM catalog_toolchain_builds t
    JOIN catalog_packages p ON p.id = t.package_id
    WHERE t.builder_version = $1
      AND t.portability_rule = 2
      AND ($7::boolean OR $8::integer IS NOT NULL OR t.rule1_reason IS NOT NULL)
      AND ($8::integer IS NULL OR t.judge_revision >= $8)
      AND t.revoked_at IS NULL
      AND t.status = 'pass'
      AND ($2::text IS NULL OR p.name = $2)
      AND ($3::text IS NULL OR t.version = $3)
      AND ($4::text IS NULL OR starts_with(t.rule1_reason, $4))
    ORDER BY p.name, t.version, t.toolchain, t.variant, t.config_variant, t.id
    LIMIT $5::bigint
    <lock_t>
  ), sr AS (
    SELECT 'system_result'::text AS kind, s.id, p.name, r.version_tested AS version,
           NULL::text AS toolchain, NULL::text AS variant, NULL::text AS config_variant,
           e.rule1_reason
    FROM catalog_system_results s
    JOIN catalog_runs r ON r.id = s.run_id
    JOIN catalog_packages p ON p.id = r.package_id
    LEFT JOIN LATERAL (
      SELECT t.rule1_reason
      FROM catalog_toolchain_builds t
      WHERE t.package_id = r.package_id
        AND t.version = r.version_tested
        AND t.toolchain = $6
        AND t.builder_version = $1
        AND t.variant = 'with'
        AND t.config_variant = 'default'
        AND t.portability_rule = 2
        AND t.rule1_reason IS NOT NULL
      LIMIT 1
    ) e ON true
    WHERE s.system_pkg = 'pure_elixir'
      AND $8::integer IS NULL
      AND s.portability_rule = 2
      AND ($7::boolean OR e.rule1_reason IS NOT NULL)
      AND s.unpublished_at IS NULL
      AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = s.id)
      AND ($2::text IS NULL OR p.name = $2)
      AND ($3::text IS NULL OR r.version_tested = $3)
      AND ($4::text IS NULL OR starts_with(e.rule1_reason, $4))
    ORDER BY p.name, r.version_tested, s.id
    LIMIT $5::bigint
    <lock_s>
  ), cand AS (
    SELECT * FROM tc UNION ALL SELECT * FROM sr
    ORDER BY name, version, kind, toolchain, variant, config_variant, id
    LIMIT $5::bigint
  )
  """

  @columns "c.kind, c.name, c.version, c.toolchain, c.variant, c.config_variant, c.rule1_reason, c.id"
  @order "ORDER BY c.name, c.version, c.kind, c.toolchain, c.variant, c.config_variant, c.id"

  @dry_run_sql (@candidates
                |> String.replace("<lock_t>", "")
                |> String.replace("<lock_s>", "")) <>
                 "SELECT #{@columns} FROM cand c #{@order}"

  # $9 the timestamp every row of the call carries. The updates re-check the
  # row is still unrevoked, so a row another writer revoked in between is
  # neither changed nor listed.
  @revoke_sql (@candidates
               |> String.replace("<lock_t>", "FOR UPDATE OF t")
               |> String.replace("<lock_s>", "FOR UPDATE OF s")) <>
                """
                , tb_done AS (
                  UPDATE catalog_toolchain_builds
                  SET revoked_at = $9, revoked_reason = '#{@reason}', updated_at = $9
                  WHERE id IN (SELECT id FROM cand WHERE kind = 'toolchain_build')
                    AND revoked_at IS NULL
                  RETURNING id
                ), sr_done AS (
                  UPDATE catalog_system_results
                  SET unpublished_at = $9, unpublished_reason = '#{@result_reason}',
                      updated_at = $9
                  WHERE id IN (SELECT id FROM cand WHERE kind = 'system_result')
                    AND unpublished_at IS NULL
                  RETURNING id
                )
                SELECT #{@columns} FROM cand c
                WHERE c.id IN (SELECT id FROM tb_done UNION ALL SELECT id FROM sr_done)
                #{@order}
                """

  @revocations_sql """
  SELECT at, sum(n)::bigint FROM (
    SELECT revoked_at AS at, count(*) AS n
    FROM catalog_toolchain_builds
    WHERE revoked_reason = $1 AND revoked_at IS NOT NULL
    GROUP BY revoked_at
    UNION ALL
    SELECT unpublished_at, count(*)
    FROM catalog_system_results
    WHERE unpublished_reason = $2 AND unpublished_at IS NOT NULL
    GROUP BY unpublished_at
  ) x
  GROUP BY at
  ORDER BY at
  """

  @undo_sql """
  WITH tb AS (
    UPDATE catalog_toolchain_builds
    SET revoked_at = NULL, revoked_reason = NULL, updated_at = now() AT TIME ZONE 'utc'
    WHERE revoked_reason = $1 AND revoked_at = $2
    RETURNING 1
  ), sr AS (
    UPDATE catalog_system_results
    SET unpublished_at = NULL, unpublished_reason = NULL, updated_at = now() AT TIME ZONE 'utc'
    WHERE unpublished_reason = $3 AND unpublished_at = $2
    RETURNING 1
  )
  SELECT (SELECT count(*) FROM tb) + (SELECT count(*) FROM sr)
  """

  @doc """
  Lists (the default) or revokes what rule 2 alone published.

  Options: `dry_run:` (`true`), `package:`, `version:` (only with
  `package:`), `rule1_prefix:` (what rule 1 said starts with it, e.g.
  `"calls System.cmd/"`), `all: true` (acting without `package:` or
  `rule1_prefix:`), `everything: true` (every rule-2 publication, see the
  moduledoc), `judge_revision:` (a positive integer, see the moduledoc),
  `limit:` (#{@default_limit}, none with `everything: true`:
  the most rows one call lists or revokes).

  Returns `{:dry_run, rows}`, `{:error, :filter_required}` for an act
  without a filter (nothing written), or `{:revoked, count, rows, at}`:
  the rows that call revoked and the timestamp `undo/1` takes.
  """
  @spec revoke(keyword()) ::
          {:dry_run, [row()]}
          | {:revoked, non_neg_integer(), [row()], DateTime.t()}
          | {:error, :filter_required}
  def revoke(opts \\ []) do
    params = params(opts)

    cond do
      Keyword.get(opts, :dry_run, true) ->
        {:dry_run, rows(Repo.query!(@dry_run_sql, params))}

      not filtered?(opts) ->
        {:error, :filter_required}

      true ->
        act(params)
    end
  end

  @doc """
  Every revocation on record, as `{timestamp, rows}`, oldest first: the
  toolchain builds and the `pure_elixir` results with the reason
  `"rule 2 revoked"`, grouped by their timestamp.
  """
  @spec revocations() :: [{DateTime.t(), non_neg_integer()}]
  def revocations do
    %{rows: rows} = Repo.query!(@revocations_sql, [@reason, @result_reason])
    Enum.map(rows, fn [at, n] -> {to_utc(at), n} end)
  end

  @doc """
  Puts back the rows one `revoke/1` call revoked at `at`: its toolchain
  builds get `revoked_at` and `revoked_reason` back to nil, its
  `pure_elixir` results (those ingest held back for it included)
  `unpublished_at` and `unpublished_reason`. Returns how many.
  """
  @spec undo(DateTime.t()) :: {:ok, non_neg_integer()}
  def undo(%DateTime{} = at) do
    %{rows: [[n]]} = Repo.query!(@undo_sql, [@reason, naive_utc(at), @result_reason])
    Logger.warning("restored #{n} rule-2 publications revoked at #{DateTime.to_iso8601(at)}")
    {:ok, n}
  end

  defp act(params) do
    now = NaiveDateTime.utc_now()
    at = to_utc(now)
    rows = rows(Repo.query!(@revoke_sql, params ++ [now]))

    for row <- rows do
      Logger.warning(
        "revoked #{row.kind} #{row.package} #{row.version} at #{DateTime.to_iso8601(at)}: " <>
          (row.rule1_reason || "no rule 1 verdict recorded")
      )
    end

    {:revoked, length(rows), rows, at}
  end

  defp rows(%{rows: rows}) do
    for [kind, name, version, toolchain, variant, config_variant, reason, id] <- rows do
      %{
        kind: kind(kind),
        package: name,
        version: version,
        toolchain: toolchain,
        variant: variant,
        config_variant: config_variant,
        rule1_reason: reason,
        id: Ecto.UUID.load!(id)
      }
    end
  end

  defp kind("toolchain_build"), do: :toolchain_build
  defp kind("system_result"), do: :system_result

  defp params(opts) do
    package = Keyword.get(opts, :package)
    version = Keyword.get(opts, :version)
    everything? = Keyword.get(opts, :everything) == true
    limit = Keyword.get(opts, :limit, if(everything?, do: nil, else: @default_limit))

    if version && is_nil(package),
      do: raise(ArgumentError, "version: needs package:, got: #{inspect(version)}")

    unless is_nil(limit) or (is_integer(limit) and limit > 0),
      do: raise(ArgumentError, "limit must be a positive integer, got: #{inspect(limit)}")

    revision = Keyword.get(opts, :judge_revision)

    unless is_nil(revision) or (is_integer(revision) and revision > 0),
      do:
        raise(
          ArgumentError,
          "judge_revision must be a positive integer, got: #{inspect(revision)}"
        )

    [
      Portal.Toolchains.builder_version(),
      package,
      version,
      Keyword.get(opts, :rule1_prefix),
      limit,
      @full_run_toolchain,
      everything?,
      revision
    ]
  end

  defp filtered?(opts),
    do:
      present?(Keyword.get(opts, :package)) or present?(Keyword.get(opts, :rule1_prefix)) or
        is_integer(Keyword.get(opts, :judge_revision)) or Keyword.get(opts, :all) == true or
        Keyword.get(opts, :everything) == true

  defp present?(value), do: is_binary(value) and value != ""

  defp naive_utc(%DateTime{} = at),
    do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_naive()

  defp to_utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
end
