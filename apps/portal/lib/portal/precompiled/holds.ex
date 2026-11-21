defmodule Portal.Precompiled.Holds do
  @moduledoc """
  The holds on a firmware target's builds (stream S8): what keeps a new
  build of a package version's firmware target out of the precompiled API
  because an earlier one was refused or revoked. `mix firmware` is not
  traced unless the firmware judge runs (`NccWorker.FirmwareInputs`), so a
  new run of the same version would otherwise publish again what a judge
  refused.

  ## The sources

  A hold comes from a firmware build of the same package version, a system
  result (`catalog_system_results`, not `host` or `pure_elixir`) or a pinned
  firmware build (`catalog_pinned_builds`):

    * **a withdrawal or revocation with a reason** (`unpublished_reason`, a
      pinned build's `revoked_reason`, or an entry of `other_holds`), but
      not the reasons every new build is judged by again
      (`SystemResult.rejudged_reasons/0`: the baked build path ones). It
      holds every new build of the target, whatever its verdict, until the
      operator undoes it (`undo/2`);
    * **a firmware judge refusal**: a build whose `firmware_judge` is
      "skipped", in an unrevoked run (a system result) or not revoked (a
      pinned build), not a carried copy. It holds every new build of the
      target that is not itself a judge pass ("pass"): one the judge did not
      run on, could not judge, or refused. Its reason is
      `SystemResult.judge_refusal/0` and its timestamp the refusing build's
      `inserted_at`.

  A source holds its own system only, unless it is about the package's own
  code (review S10): a reason naming a probe, a plugin or a rebar3 rule or
  hook (`SystemResult.version_wide?/1`), or a judge refusal whose classes
  include `"probe"` or `"plugins_hooks"`. Those hold every firmware system
  of the version, also one built for the first time after it.

  ## The set

  A held build is stored withdrawn with every hold that applies: the newest
  as its `unpublished_reason` and `unpublished_at`, the others in
  `other_holds` (`%{"reason", "at"}`). It is served only when it has none:
  `undo/2` releases one hold and keeps the row withdrawn while another
  remains, and a check constraint refuses a write that clears
  `unpublished_at` while `other_holds` is not empty.
  """

  alias Portal.Catalog.SystemResult
  alias Portal.Precompiled.FirmwareRefusal
  alias Portal.Repo

  require Logger

  @typedoc "One hold: its reason and timestamp (UTC, microseconds)."
  @type hold :: {NaiveDateTime.t(), String.t()}

  # Every source of a package version (`$1`, `$2`), with its target, its
  # timestamp and reason, whether it holds every system (`wide`) and whether
  # a judge pass is exempt from it (`judge`). `$3` the rejudged reasons, `$4`
  # the judge's reason, `$5` the version-wide pattern.
  @sources_sql """
  WITH withdrawn AS (
    SELECT s.system_pkg AS target, s.unpublished_at AS at, s.unpublished_reason AS reason
    FROM catalog_system_results s JOIN catalog_runs r ON r.id = s.run_id
    WHERE r.package_id = $1 AND r.version_tested = $2
      AND s.system_pkg NOT IN ('host', 'pure_elixir')
      AND s.unpublished_at IS NOT NULL AND s.unpublished_reason IS NOT NULL
    UNION
    SELECT s.system_pkg, (h->>'at')::timestamp, h->>'reason'
    FROM catalog_system_results s JOIN catalog_runs r ON r.id = s.run_id
    CROSS JOIN LATERAL unnest(coalesce(s.other_holds, '{}')) h
    WHERE r.package_id = $1 AND r.version_tested = $2
      AND s.system_pkg NOT IN ('host', 'pure_elixir')
    UNION
    SELECT pb.target, pb.unpublished_at, pb.unpublished_reason
    FROM catalog_pinned_builds pb
    WHERE pb.package_id = $1 AND pb.version = $2 AND pb.target LIKE 'nerves\\_system\\_%'
      AND pb.unpublished_at IS NOT NULL AND pb.unpublished_reason IS NOT NULL
    UNION
    SELECT pb.target, (h->>'at')::timestamp, h->>'reason'
    FROM catalog_pinned_builds pb
    CROSS JOIN LATERAL unnest(coalesce(pb.other_holds, '{}')) h
    WHERE pb.package_id = $1 AND pb.version = $2 AND pb.target LIKE 'nerves\\_system\\_%'
    UNION
    SELECT pb.target, pb.revoked_at, pb.revoked_reason
    FROM catalog_pinned_builds pb
    WHERE pb.package_id = $1 AND pb.version = $2 AND pb.target LIKE 'nerves\\_system\\_%'
      AND pb.revoked_at IS NOT NULL AND pb.revoked_reason IS NOT NULL
  ), refused AS (
    SELECT s.system_pkg AS target, s.inserted_at AS at, s.firmware_judge->'classes' AS classes
    FROM catalog_system_results s JOIN catalog_runs r ON r.id = s.run_id
    WHERE r.package_id = $1 AND r.version_tested = $2
      AND s.system_pkg NOT IN ('host', 'pure_elixir')
      AND s.carried_from_run_id IS NULL AND r.revoked_at IS NULL
      AND jsonb_typeof(s.firmware_judge) = 'object' AND s.firmware_judge->>'status' = 'skipped'
    UNION
    SELECT pb.target, pb.inserted_at, pb.firmware_judge->'classes'
    FROM catalog_pinned_builds pb
    WHERE pb.package_id = $1 AND pb.version = $2 AND pb.target LIKE 'nerves\\_system\\_%'
      AND pb.revoked_at IS NULL
      AND jsonb_typeof(pb.firmware_judge) = 'object' AND pb.firmware_judge->>'status' = 'skipped'
  )
  SELECT target, at, reason, reason ~* $5, reason = $4 FROM withdrawn
  WHERE NOT (reason = ANY($3::text[]))
  UNION
  SELECT target, at, $4,
         jsonb_typeof(classes) = 'array' AND classes ?| ARRAY['probe', 'plugins_hooks'], true
  FROM refused
  """

  @doc """
  The holds on new builds of `package_id` `version`: for each target of
  `verdicts` (`%{system_pkg => its own firmware_judge status or nil}`), its
  holds, newest first (`[]` for none). `host` and `pure_elixir` are never
  held here.
  """
  @spec for_targets(Ecto.UUID.t(), String.t(), %{String.t() => String.t() | nil}) ::
          %{String.t() => [hold()]}
  def for_targets(package_id, version, verdicts) do
    targets = verdicts |> Map.keys() |> Enum.reject(&(&1 in ["host", "pure_elixir"]))

    case targets do
      [] -> %{}
      _ -> package_id |> sources(version) |> holds_of(Map.take(verdicts, targets))
    end
  end

  defp sources(package_id, version) do
    %{rows: rows} =
      Repo.query!(@sources_sql, [
        Ecto.UUID.dump!(package_id),
        version,
        SystemResult.rejudged_reasons(),
        SystemResult.judge_refusal(),
        SystemResult.version_wide_pattern()
      ])

    for [target, at, reason, wide, judge] <- rows,
        do: %{target: target, at: at, reason: reason, wide: wide == true, judge: judge == true}
  end

  defp holds_of(sources, verdicts) do
    Map.new(verdicts, fn {target, verdict} ->
      holds =
        for source <- sources,
            source.target == target or source.wide,
            not (source.judge and verdict == "pass"),
            uniq: true,
            do: {source.at, source.reason}

      {target, newest_first(holds)}
    end)
  end

  @doc """
  `holds` by time, newest first (a struct compare would compare fields),
  then by reason.
  """
  @spec newest_first([hold()]) :: [hold()]
  def newest_first(holds) do
    Enum.sort(holds, fn {a, ra}, {b, rb} ->
      case NaiveDateTime.compare(a, b) do
        :gt -> true
        :lt -> false
        :eq -> ra >= rb
      end
    end)
  end

  @doc """
  What a held row is stored with: `{unpublished_at, unpublished_reason,
  other_holds}` for `holds` (newest first), or `{nil, nil, nil}` for none.
  """
  @spec columns([hold()]) ::
          {DateTime.t() | nil, String.t() | nil, [map()] | nil}
  def columns([]), do: {nil, nil, nil}

  def columns([{at, reason} | rest]) do
    others = if rest == [], do: nil, else: Enum.map(rest, &entry/1)
    {DateTime.from_naive!(at, "Etc/UTC"), reason, others}
  end

  @doc "A hold as an `other_holds` entry."
  @spec entry(hold()) :: map()
  def entry({at, reason}), do: %{"reason" => reason, "at" => NaiveDateTime.to_iso8601(at)}

  # --- undo ---------------------------------------------------------------------

  @tables ["catalog_system_results", "catalog_pinned_builds"]

  # Takes the hold out of every row's `other_holds`.
  @drop_other_sql """
  UPDATE $TABLE SET
    other_holds = nullif(ARRAY(SELECT h FROM unnest(other_holds) h
                               WHERE NOT (h->>'reason' = $1 AND (h->>'at')::timestamp = $2)),
                         '{}'),
    updated_at = now() AT TIME ZONE 'utc'
  WHERE EXISTS (SELECT 1 FROM unnest(coalesce(other_holds, '{}')) h
                WHERE h->>'reason' = $1 AND (h->>'at')::timestamp = $2)
  RETURNING id
  """

  # Releases the rows the hold is the newest of: the next newest becomes
  # theirs, or the row is served when none is left.
  @release_sql """
  WITH hit AS (
    SELECT t.id,
           (SELECT h FROM unnest(t.other_holds) h
            ORDER BY (h->>'at')::timestamp DESC, h->>'reason' DESC LIMIT 1) AS nxt
    FROM $TABLE t
    WHERE t.unpublished_reason = $1 AND t.unpublished_at = $2
  )
  UPDATE $TABLE t SET
    unpublished_at = (hit.nxt->>'at')::timestamp,
    unpublished_reason = hit.nxt->>'reason',
    other_holds = CASE WHEN hit.nxt IS NULL THEN NULL
                       ELSE nullif(array_remove(t.other_holds, hit.nxt), '{}') END,
    updated_at = now() AT TIME ZONE 'utc'
  FROM hit WHERE t.id = hit.id
  RETURNING t.id, t.unpublished_at IS NULL
  """

  @doc """
  Releases the hold `reason` at `at` (a `NaiveDateTime`, UTC, as a
  revocation printed it) from every firmware system result and pinned build
  that carries it, as its newest hold or in `other_holds`. A row keeps
  every other hold, and stays withdrawn while one is left. Each row it
  served again then gets the holds that apply to it now
  (`for_targets/3`, also a revocation it never recorded because it was
  already withdrawn), and the superseding firmware refusals run over every
  version (`Portal.Precompiled.FirmwareRefusal.withdraw_superseded/0`), so a
  released row a newer refusal covers stays out. A judge refusal's holds
  come back that way too: only a later judge pass, or revoking the refusing
  run, releases it.

  Returns `{:ok, %{released: rows served again, kept: rows that lost this
  hold and stay withdrawn}}`.
  """
  @spec undo(String.t(), NaiveDateTime.t()) ::
          {:ok, %{released: non_neg_integer(), kept: non_neg_integer()}}
  def undo(reason, %NaiveDateTime{} = at) when is_binary(reason) do
    {:ok, result} =
      Repo.transaction(
        fn ->
          touched =
            Enum.flat_map(@tables, fn table ->
              %{rows: others} = Repo.query!(sql(@drop_other_sql, table), [reason, at])
              %{rows: newest} = Repo.query!(sql(@release_sql, table), [reason, at])

              Enum.map(others, fn [id] -> {table, id} end) ++
                for([id, _served] <- newest, do: {table, id})
            end)
            |> Enum.uniq()

          :ok = reapply(touched)
          _ = FirmwareRefusal.withdraw_superseded()
          counts(touched)
        end,
        timeout: :infinity
      )

    Logger.warning(
      "released hold #{inspect(reason)} at #{NaiveDateTime.to_iso8601(at)}: #{inspect(result)}"
    )

    {:ok, result}
  end

  defp sql(template, table) when table in @tables, do: String.replace(template, "$TABLE", table)

  @doc """
  Holds anew each of `touched` (`{table, id}`, a system result or pinned
  build) that is served: what applies to it now (`for_targets/3`), also a
  revocation it never recorded because it was withdrawn when that ran. For
  every undo that puts firmware builds back.
  """
  @spec reapply([{String.t(), term()}]) :: :ok
  def reapply(touched) do
    touched
    |> served()
    |> Enum.group_by(fn row -> {row.package_id, row.version} end)
    |> Enum.each(fn {{package_id, version}, rows} ->
      verdicts = Map.new(rows, &{&1.target, &1.verdict})
      holds = for_targets(Ecto.UUID.load!(package_id), version, verdicts)

      for row <- rows, (held = Map.get(holds, row.target, [])) != [] do
        {at, reason, others} = columns(held)

        Repo.query!(
          "UPDATE #{row.table} SET unpublished_at = $2, unpublished_reason = $3, " <>
            "other_holds = $4, updated_at = now() AT TIME ZONE 'utc' WHERE id = $1",
          [row.id, at, reason, others]
        )
      end
    end)
  end

  # The touched rows that are served again (no `unpublished_at`, a firmware
  # target), with what `for_targets/3` needs.
  defp served(touched) do
    {results, pinned} = Enum.split_with(touched, &(elem(&1, 0) == "catalog_system_results"))

    %{rows: a} =
      Repo.query!(
        """
        SELECT s.id, r.package_id, r.version_tested, s.system_pkg, s.firmware_judge->>'status'
        FROM catalog_system_results s JOIN catalog_runs r ON r.id = s.run_id
        WHERE s.id = ANY($1) AND s.unpublished_at IS NULL
          AND s.system_pkg NOT IN ('host', 'pure_elixir')
        """,
        [Enum.map(results, &elem(&1, 1))]
      )

    %{rows: b} =
      Repo.query!(
        """
        SELECT pb.id, pb.package_id, pb.version, pb.target, pb.firmware_judge->>'status'
        FROM catalog_pinned_builds pb
        WHERE pb.id = ANY($1) AND pb.unpublished_at IS NULL
          AND pb.target LIKE 'nerves\\_system\\_%'
        """,
        [Enum.map(pinned, &elem(&1, 1))]
      )

    for {table, rows} <- [{"catalog_system_results", a}, {"catalog_pinned_builds", b}],
        [id, package_id, version, target, verdict] <- rows,
        do: %{
          table: table,
          id: id,
          package_id: package_id,
          version: version,
          target: target,
          verdict: verdict
        }
  end

  defp counts(touched) do
    {results, pinned} = Enum.split_with(touched, &(elem(&1, 0) == "catalog_system_results"))

    served =
      Enum.sum(
        for {table, ids} <- [
              {"catalog_system_results", Enum.map(results, &elem(&1, 1))},
              {"catalog_pinned_builds", Enum.map(pinned, &elem(&1, 1))}
            ] do
          %{rows: [[n]]} =
            Repo.query!(
              "SELECT count(*) FROM #{table} WHERE id = ANY($1) AND unpublished_at IS NULL",
              [ids]
            )

          n
        end
      )

    %{released: served, kept: length(touched) - served}
  end

  @doc """
  Every hold `reason` on record, by timestamp: `[{at, rows}]`, the rows that
  carry it (as their newest hold or in `other_holds`), oldest first.
  """
  @spec list(String.t()) :: [{NaiveDateTime.t(), pos_integer()}]
  def list(reason) when is_binary(reason) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT at, count(*) FROM (
          SELECT t.id, t.unpublished_at AS at FROM catalog_system_results t
          WHERE t.unpublished_reason = $1 AND t.unpublished_at IS NOT NULL
          UNION
          SELECT t.id, (h->>'at')::timestamp FROM catalog_system_results t
          CROSS JOIN LATERAL unnest(coalesce(t.other_holds, '{}')) h WHERE h->>'reason' = $1
          UNION
          SELECT t.id, t.unpublished_at FROM catalog_pinned_builds t
          WHERE t.unpublished_reason = $1 AND t.unpublished_at IS NOT NULL
          UNION
          SELECT t.id, (h->>'at')::timestamp FROM catalog_pinned_builds t
          CROSS JOIN LATERAL unnest(coalesce(t.other_holds, '{}')) h WHERE h->>'reason' = $1
        ) x GROUP BY at ORDER BY at
        """,
        [reason]
      )

    Enum.map(rows, fn [at, n] -> {at, n} end)
  end
end
