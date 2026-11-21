defmodule Portal.Precompiled.FirmwareRefusal do
  @moduledoc """
  Withdraws a firmware target's builds that a newer run's refusal of that
  target supersedes: a refusal for a baked build path (R2), or a firmware
  judge refusal (`firmware_judge` "skipped", `NccWorker.FirmwareInputs`: a
  compile-time probe, a rebar3 plugin or hook, or a dependency's taint by
  one).

  The worker judges every passing firmware target's files by the baked build
  path rule (`NccWorker.FirmwareBuildRoot`) and writes the verdict as the
  system's `build_root`; with the firmware judge on, it also writes
  `firmware_judge`. A refused or unjudgeable build publishes nothing, but
  the precompiled selectors pick per version and target among every
  unrevoked run, so without this an older run's build of the same version
  and target, judged by nobody, would go on being served.

  ## R2

  A refusal is a system result with a `build_root` (stored by ingest, kept
  by carried copies) whose own `status` is not `"pass"`, or one of whose
  judged `variants` is not `"pass"`, in an unrevoked run (and, for a carried
  copy, an unrevoked building run). It withdraws every passing result of the
  same package, version and `system_pkg` that has files, is not withdrawn
  yet, and was built strictly before it. Built means the `finished_at` of
  the run that built it: the carried-from run for a carried copy
  (`carried_from_run_id`), else its own. So:

    * an older run's build, and every carried copy of one, is withdrawn;
    * an older build ingested after the refusal (a late remote lease) is
      withdrawn by that ingest;
    * a build finished after the refusal (a later judge, a fixed package)
      is not, and serves the target again;
    * a variant refusal withdraws the older result whole, its own build too:
      the variant's files are on the same row.

  Its withdrawals carry `Portal.Catalog.SystemResult.superseded_by_refusal/0`
  and the same timestamp for every row one call withdraws.

  ## The firmware judge (stream S8)

  A refusal is a system result or pinned firmware build whose
  `firmware_judge` is "skipped": a system result in an unrevoked run, not a
  carried copy; a pinned build not revoked. It withdraws every passing
  build of the same package version that has files and is not withdrawn
  yet, a system result or a pinned build, of the same target or, when its
  classes include `"probe"` or `"plugins_hooks"` (the package's own code),
  of any firmware target (review S10), that was built before it or is no
  judge pass itself (review B1: a later build the judge did not run on, or
  could not judge, does not serve over the refusal; only a judge pass
  does). Its withdrawals carry `SystemResult.judge_refusal/0` and, as
  timestamp, the refusing build's `inserted_at` (the newest refusal's, when
  several apply), the same hold `Portal.Precompiled.Holds` gives a new
  build of the target at ingest.

  A build either rule covers that is already withdrawn otherwise gets the
  rule's hold in its `other_holds` instead (review R4), once: R2's with this
  call's timestamp, the judge's with its newest refusal's. So it stays out
  when its own withdrawal is undone (`Portal.Precompiled.Holds.undo/2`), and
  a bare undo of that withdrawal fails on the hold set's check constraint.

  Statuses, runs and logs never change: only `unpublished_at`,
  `unpublished_reason` and `other_holds`, which are the audit trail. Nothing undoes it
  automatically, also not a later revocation of the refusing run; putting a
  result back is `Portal.Precompiled.Holds.undo/2`, which runs this sweep
  again afterwards.

  Ingest calls `withdraw_superseded/2` for the version it stored, in its
  transaction, and so does `Portal.Precompiled.FirmwareBuildPathWithdrawal.undo/1`
  for the versions it puts back. A release without this module stores no
  `build_root`, so a refusal it ingested is lost for good: no sweep can see
  it, only a new run of that version records it again. What a sweep does
  find is an older build that such a release ingested after a refusal this
  one stored (both hosts are not on the same release during a deploy), or a
  result put back by hand; `withdraw_superseded/0` sweeps every version for
  those:

      bin/portal rpc 'Portal.Precompiled.FirmwareRefusal.withdraw_superseded() |> IO.inspect()'
  """

  alias Portal.Catalog.SystemResult
  alias Portal.Repo

  require Logger

  # `$1`/`$2` scope it to a package and version (NULL: every one). `o` is the
  # candidate, `f` the refusal; `ob`/`fb` their building runs when carried.
  # The R2 candidates of `$1`/`$2`: `$WITHDRAWN` picks the served ones, or
  # those already withdrawn otherwise that carry no R2 hold yet.
  @r2_candidates """
    SELECT o.id
    FROM catalog_system_results o
    JOIN catalog_runs orun ON orun.id = o.run_id
    LEFT JOIN catalog_runs ob ON ob.id = o.carried_from_run_id
    JOIN catalog_runs frun
      ON frun.package_id = orun.package_id AND frun.version_tested = orun.version_tested
    JOIN catalog_system_results f ON f.run_id = frun.id AND f.system_pkg = o.system_pkg
    LEFT JOIN catalog_runs fb ON fb.id = f.carried_from_run_id
    WHERE ($1::uuid IS NULL OR orun.package_id = $1::uuid)
      AND ($2::text IS NULL OR orun.version_tested = $2::text)
      AND $WITHDRAWN
      AND o.status = 'pass'
      AND o.system_pkg NOT IN ('host', 'pure_elixir')
      AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = o.id)
      AND frun.revoked_at IS NULL
      AND (f.carried_from_run_id IS NULL OR fb.revoked_at IS NULL)
      AND jsonb_typeof(f.build_root) = 'object'
      AND (coalesce(f.build_root->>'status', '') <> 'pass'
           OR (jsonb_typeof(f.build_root->'variants') = 'object'
               AND EXISTS (SELECT 1 FROM jsonb_each(f.build_root->'variants') v
                           WHERE jsonb_typeof(v.value) <> 'object'
                              OR coalesce(v.value->>'status', '') <> 'pass')))
      AND coalesce(fb.finished_at, frun.finished_at) >
          coalesce(ob.finished_at, orun.finished_at)
  """

  @withdraw_sql """
  UPDATE catalog_system_results s
  SET unpublished_at = $3, unpublished_reason = $4, updated_at = $3
  WHERE s.id IN (
  #{String.replace(@r2_candidates, "$WITHDRAWN", "o.unpublished_at IS NULL")}
  )
  """

  # Review R4: an already withdrawn result gets the hold too (`other_holds`),
  # once, so it stays out when its own withdrawal is undone, and a bare undo
  # of that withdrawal fails (the hold set's check constraint).
  @hold_withdrawn_sql """
  UPDATE catalog_system_results s
  SET other_holds = coalesce(s.other_holds, '{}') ||
                      ARRAY[jsonb_build_object('reason', $4::text, 'at', $5::text)],
      updated_at = $3
  WHERE s.id IN (
  #{String.replace(@r2_candidates, "$WITHDRAWN", "o.unpublished_at IS NOT NULL AND o.unpublished_reason IS DISTINCT FROM $4 AND NOT EXISTS (SELECT 1 FROM unnest(coalesce(o.other_holds, '{}')) h WHERE h->>'reason' = $4)")}
  )
  """

  # The firmware judge's refusals of a package version (`$1`/`$2`, NULL:
  # every one): each refusing build's target, whether it holds every target
  # (`wide`), when it was built and its hold timestamp (`at`).
  @refusals_cte """
  refusals AS (
    SELECT r.package_id, r.version_tested AS version, f.system_pkg AS target,
           (f.firmware_judge->'classes' ?| ARRAY['probe', 'plugins_hooks']) AS wide,
           r.finished_at AS built, f.inserted_at AS at
    FROM catalog_system_results f JOIN catalog_runs r ON r.id = f.run_id
    WHERE ($1::uuid IS NULL OR r.package_id = $1::uuid)
      AND ($2::text IS NULL OR r.version_tested = $2::text)
      AND f.system_pkg NOT IN ('host', 'pure_elixir')
      AND f.carried_from_run_id IS NULL AND r.revoked_at IS NULL
      AND jsonb_typeof(f.firmware_judge) = 'object' AND f.firmware_judge->>'status' = 'skipped'
    UNION ALL
    SELECT f.package_id, f.version, f.target,
           (f.firmware_judge->'classes' ?| ARRAY['probe', 'plugins_hooks']),
           f.finished_at, f.inserted_at
    FROM catalog_pinned_builds f
    WHERE ($1::uuid IS NULL OR f.package_id = $1::uuid)
      AND ($2::text IS NULL OR f.version = $2::text)
      AND f.target LIKE 'nerves\\_system\\_%' AND f.revoked_at IS NULL
      AND jsonb_typeof(f.firmware_judge) = 'object' AND f.firmware_judge->>'status' = 'skipped'
  )
  """

  # The judge candidates and the newest refusal that applies to each (`at`):
  # a system result, then a pinned build. `$WITHDRAWN` picks the served ones
  # or the withdrawn ones (`o` the candidate).
  @judged_results """
    SELECT DISTINCT ON (o.id) o.id, f.at, o.unpublished_at, o.unpublished_reason, o.other_holds
    FROM catalog_system_results o
    JOIN catalog_runs orun ON orun.id = o.run_id
    LEFT JOIN catalog_runs ob ON ob.id = o.carried_from_run_id
    JOIN refusals f ON f.package_id = orun.package_id AND f.version = orun.version_tested
                   AND (f.target = o.system_pkg OR coalesce(f.wide, false))
    WHERE $WITHDRAWN
      AND o.status = 'pass'
      AND o.system_pkg NOT IN ('host', 'pure_elixir')
      AND EXISTS (SELECT 1 FROM catalog_artifact_memberships m WHERE m.system_result_id = o.id)
      AND (coalesce(o.firmware_judge->>'status', '') <> 'pass'
           OR coalesce(ob.finished_at, orun.finished_at) < f.built)
    ORDER BY o.id, f.at DESC
  """

  @judged_pinned """
    SELECT DISTINCT ON (o.id) o.id, f.at, o.unpublished_at, o.unpublished_reason, o.other_holds
    FROM catalog_pinned_builds o
    JOIN refusals f ON f.package_id = o.package_id AND f.version = o.version
                   AND (f.target = o.target OR coalesce(f.wide, false))
    WHERE $WITHDRAWN AND o.revoked_at IS NULL
      AND o.status = 'pass'
      AND o.target LIKE 'nerves\\_system\\_%'
      AND (coalesce(o.firmware_judge->>'status', '') <> 'pass' OR o.finished_at < f.built)
    ORDER BY o.id, f.at DESC
  """

  # Whether the candidate `w` already carries the judge hold of its newest
  # refusal, as its withdrawal or in `other_holds`.
  @judge_held "((w.unpublished_reason = $3 AND w.unpublished_at = w.at) OR " <>
                "EXISTS (SELECT 1 FROM unnest(coalesce(w.other_holds, '{}')) h " <>
                "WHERE h->>'reason' = $3 AND (h->>'at')::timestamp = w.at))"

  @judge_entry "ARRAY[jsonb_build_object('reason', $3::text, " <>
                 "'at', to_char(w.at, 'YYYY-MM-DD\"T\"HH24:MI:SS.US'))]"

  @withdraw_judged_sql """
  WITH #{@refusals_cte}
  UPDATE catalog_system_results s
  SET unpublished_at = w.at, unpublished_reason = $3, updated_at = now() AT TIME ZONE 'utc'
  FROM (#{String.replace(@judged_results, "$WITHDRAWN", "o.unpublished_at IS NULL")}) w
  WHERE s.id = w.id
  """

  @hold_judged_sql """
  WITH #{@refusals_cte}
  UPDATE catalog_system_results s
  SET other_holds = coalesce(s.other_holds, '{}') || #{@judge_entry},
      updated_at = now() AT TIME ZONE 'utc'
  FROM (#{String.replace(@judged_results, "$WITHDRAWN", "o.unpublished_at IS NOT NULL")}) w
  WHERE s.id = w.id AND NOT #{@judge_held}
  """

  @withdraw_judged_pinned_sql """
  WITH #{@refusals_cte}
  UPDATE catalog_pinned_builds pb
  SET unpublished_at = w.at, unpublished_reason = $3, updated_at = now() AT TIME ZONE 'utc'
  FROM (#{String.replace(@judged_pinned, "$WITHDRAWN", "o.unpublished_at IS NULL")}) w
  WHERE pb.id = w.id
  """

  @hold_judged_pinned_sql """
  WITH #{@refusals_cte}
  UPDATE catalog_pinned_builds pb
  SET other_holds = coalesce(pb.other_holds, '{}') || #{@judge_entry},
      updated_at = now() AT TIME ZONE 'utc'
  FROM (#{String.replace(@judged_pinned, "$WITHDRAWN", "o.unpublished_at IS NOT NULL")}) w
  WHERE pb.id = w.id AND NOT #{@judge_held}
  """

  @doc """
  Withdraws every result of every package version that a newer refusal of
  its target supersedes (see the moduledoc). Returns how many it withdrew;
  idempotent.
  """
  @spec withdraw_superseded() :: non_neg_integer()
  def withdraw_superseded, do: run(nil, nil)

  @doc "`withdraw_superseded/0` for one package (`package_id`) and `version`."
  @spec withdraw_superseded(Ecto.UUID.t(), String.t()) :: non_neg_integer()
  def withdraw_superseded(package_id, version) when is_binary(package_id) and is_binary(version),
    do: run(Ecto.UUID.dump!(package_id), version)

  # Both statements are module attributes, fixed at compile time.
  # sobelow_skip ["SQL.Query"]
  defp run(package_id, version) do
    at = DateTime.utc_now()

    r2_reason = SystemResult.superseded_by_refusal()
    iso = at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()

    # The holds on rows already withdrawn first, then the withdrawals: a row
    # this call withdraws is not held twice (review R4).
    %{num_rows: _} =
      Repo.query!(@hold_withdrawn_sql, [package_id, version, at, r2_reason, iso])

    %{num_rows: r2} = Repo.query!(@withdraw_sql, [package_id, version, at, r2_reason])

    judged =
      for sql <- [
            @hold_judged_sql,
            @withdraw_judged_sql,
            @hold_judged_pinned_sql,
            @withdraw_judged_pinned_sql
          ],
          into: [] do
        %{num_rows: n} = Repo.query!(sql, [package_id, version, SystemResult.judge_refusal()])
        {sql, n}
      end

    judged =
      for {sql, n} <- judged, sql in [@withdraw_judged_sql, @withdraw_judged_pinned_sql], do: n

    n = r2 + Enum.sum(judged)

    if n > 0 do
      Logger.info(
        "firmware refusal: withdrew #{r2} older firmware result(s) for a build path and " <>
          "#{Enum.sum(judged)} firmware build(s) for a judge refusal" <>
          if(version, do: " of version #{version}", else: "") <>
          " at #{DateTime.to_iso8601(at)}"
      )
    end

    n
  end
end
