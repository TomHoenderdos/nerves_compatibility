defmodule Portal.Precompiled.ForeignPrivRevocation do
  @moduledoc """
  The lever for foreign priv builds (foreign priv spec 4.4, item 3): revokes
  every counted foreign build, toolchain, pinned or deterministic sibling,
  of a package (and version), of a reviewed rule (`rule:`, or `js_sha256:`
  for "a review was wrong": every build whose kino `lib/kino/js.ex` was that
  one, mapped to the rules that reviewed it), or all of them. A build counts
  only while its list is its own run's (`foreign_priv_run_id = run_id`,
  `Portal.Precompiled.ForeignPriv.counted/1`) and not empty.

  Counts first: `dry_run: true` is the default and writes nothing, and its
  listing is cut at `limit:` (50). Acting needs a filter. A revoked build
  gets `revoked_at` and `revoked_reason` (`reason/0`): it leaves the
  manifest at the next batch with its files, and a toolchain or pinned
  build takes its sibling with it (`Portal.Deterministic`). `undo/1` puts
  back exactly one act's rows. Nothing runs it on its own.
  """

  import Ecto.Query

  require Logger

  alias Portal.Repo

  @reason "foreign priv revoked"
  @tables ["catalog_toolchain_builds", "catalog_pinned_builds", "catalog_deterministic_builds"]
  @filters [:package, :version, :rule, :js_sha256]

  @type row :: %{
          table: String.t(),
          id: Ecto.UUID.t(),
          package: String.t(),
          version: String.t(),
          rule: String.t() | nil,
          config_variant: String.t() | nil
        }

  @doc "The `revoked_reason` this lever writes."
  @spec reason() :: String.t()
  def reason, do: @reason

  @doc """
  `{:dry_run, rows}` (the default, at most `limit:` rows), `{:revoked,
  count, rows, at}` with `dry_run: false`, or `{:error, :filter_required}`
  for an act with no filter (nothing written).
  """
  @spec revoke(keyword()) ::
          {:dry_run, [row()]}
          | {:revoked, non_neg_integer(), [row()], DateTime.t()}
          | {:error, :filter_required}
  def revoke(opts \\ []) do
    cond do
      Keyword.get(opts, :dry_run, true) ->
        {:dry_run, opts |> rows() |> Enum.take(Keyword.get(opts, :limit, 50))}

      not filtered?(opts) ->
        {:error, :filter_required}

      true ->
        act(opts)
    end
  end

  @doc "Puts back the builds one `revoke/1` call revoked at `at`; returns how many."
  @spec undo(DateTime.t()) :: non_neg_integer()
  def undo(%DateTime{} = at) do
    {:ok, n} =
      Repo.transaction(fn ->
        Enum.reduce(@tables, 0, fn table, n ->
          {count, _} =
            from(t in table,
              where:
                t.revoked_at == type(^at, :utc_datetime_usec) and t.revoked_reason == ^@reason,
              update: [
                set: [
                  revoked_at: nil,
                  revoked_reason: nil,
                  updated_at: type(^DateTime.utc_now(), :utc_datetime_usec)
                ]
              ]
            )
            |> Repo.update_all([])

          n + count
        end)
      end)

    Logger.warning("restored #{n} foreign priv builds revoked at #{DateTime.to_iso8601(at)}")
    n
  end

  defp filtered?(opts),
    do: Keyword.get(opts, :everything) == true or Enum.any?(@filters, &(opts[&1] != nil))

  defp act(opts) do
    at = DateTime.utc_now()

    Repo.transaction(fn ->
      rows = rows(opts)

      rows
      |> Enum.group_by(& &1.table, & &1.id)
      |> Enum.each(fn {table, ids} -> stamp(table, ids, at) end)

      for row <- rows do
        Logger.warning(
          "foreign priv revoked: #{row.package} #{row.version} #{row.table} #{row.id} " <>
            "(#{row.rule}) at #{DateTime.to_iso8601(at)}"
        )
      end

      {:revoked, length(rows), rows, at}
    end)
    |> elem(1)
  end

  defp stamp(table, ids, at) do
    from(t in table,
      where: t.id in type(^ids, {:array, :binary_id}) and is_nil(t.revoked_at),
      update: [
        set: [
          revoked_at: type(^at, :utc_datetime_usec),
          revoked_reason: ^@reason,
          updated_at: type(^at, :utc_datetime_usec)
        ]
      ]
    )
    |> Repo.update_all([])
  end

  defp rows(opts) do
    rules = rule_ids(opts)
    Enum.flat_map(@tables, &(&1 |> candidates(opts, rules) |> Repo.all()))
  end

  defp candidates(table, opts, rules) do
    from(t in table,
      as: :build,
      join: p in "catalog_packages",
      as: :package,
      on: p.id == t.package_id,
      where: is_nil(t.revoked_at) and t.foreign_priv_run_id == t.run_id,
      where: fragment("coalesce(array_length(?, 1), 0) > 0", t.foreign_priv),
      order_by: [p.name, t.version, t.id],
      select: %{
        table: ^table,
        id: type(t.id, Ecto.UUID),
        package: p.name,
        version: t.version,
        rule: t.foreign_priv_rule
      }
    )
    |> select_config_variant(table)
    |> where_package(opts[:package])
    |> where_version(opts[:version])
    |> where_rules(rules)
  end

  # Every config variant (`config_variant`) of a foreign build is revoked
  # alike: each is its own build with its own archives. The listing names it
  # so a dry run shows which; a sibling has none of its own.
  defp select_config_variant(query, "catalog_deterministic_builds"),
    do: select_merge(query, %{config_variant: type(^nil, :string)})

  defp select_config_variant(query, _table),
    do: select_merge(query, [build: t], %{config_variant: t.config_variant})

  defp where_package(query, nil), do: query
  defp where_package(query, name), do: where(query, [package: p], p.name == ^name)

  defp where_version(query, nil), do: query
  defp where_version(query, version), do: where(query, [build: t], t.version == ^version)

  defp where_rules(query, nil), do: query
  defp where_rules(query, rules), do: where(query, [build: t], t.foreign_priv_rule in ^rules)

  # A rule id, or every rule whose reviewed `lib/kino/js.ex` has the sha.
  defp rule_ids(opts) do
    case {opts[:rule], opts[:js_sha256]} do
      {nil, nil} ->
        nil

      {rule, nil} ->
        [rule]

      {_, sha} ->
        for rule <- Compatibility.ForeignPriv.rules(), rule.js_sha256 == sha, do: rule.id
    end
  end
end
