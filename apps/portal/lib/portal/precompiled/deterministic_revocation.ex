defmodule Portal.Precompiled.DeterministicRevocation do
  @moduledoc """
  Revokes published deterministic siblings (`Portal.Catalog.DeterministicBuild`)
  alone, leaving their toolchain builds served. Every lever that withdraws a
  toolchain build (`Portal.Precompiled.ToolchainRevocation`,
  `Portal.Precompiled.Withheld`, `Portal.Catalog.mark_withheld_revoked/2`, a
  named config variant whose default is not served) withdraws its sibling
  with it, because a sibling is served only beside its served toolchain
  build (`Portal.Deterministic`), and the `deterministic_builds_enabled`
  setting takes every one of them out at once. This is the lever for a
  sibling found unsafe on its own: a change to what the option does that the
  checks did not catch, or a refinement of them rolled back. Nothing runs it
  on its own.

  A revoked sibling gets `revoked_at` and `revoked_reason`: it is not served
  (manifests, `files/{sha256}`), and its package's fingerprint changes so the
  next signed batch drops it. A rebuild writes a new sibling row (the ingest
  replaces a toolchain build's sibling with the run's own), so a revocation
  holds until the toolchain build is rebuilt; `undo/1` puts a call back.

  `revoke/1` takes a filter: `package:` (name), `version:`, `judge_revision:`
  (revision `n` or later), or `everything: true`. Only passing, unrevoked
  siblings are candidates. It only lists unless given `dry_run: false`, and
  never acts without a filter.
  """

  import Ecto.Query

  require Logger

  alias Portal.Repo

  @type row :: %{
          id: Ecto.UUID.t(),
          package: String.t(),
          version: String.t(),
          toolchain: String.t(),
          variant: String.t(),
          config_variant: String.t(),
          judge_revision: integer() | nil
        }

  @filters [:package, :version, :judge_revision]
  @reason "deterministic revoked"

  @doc "The `revoked_reason` this lever writes."
  @spec reason() :: String.t()
  def reason, do: @reason

  @doc """
  `{:dry_run, rows}` (the default), `{:revoked, count, rows, at}` with
  `dry_run: false`, or `{:error, :filter_required}` for an act with no
  filter (nothing written).
  """
  @spec revoke(keyword()) ::
          {:dry_run, [row()]}
          | {:revoked, non_neg_integer(), [row()], DateTime.t()}
          | {:error, :filter_required}
  def revoke(opts \\ []) do
    cond do
      Keyword.get(opts, :dry_run, true) -> {:dry_run, Repo.all(candidates(opts))}
      not filtered?(opts) -> {:error, :filter_required}
      true -> act(opts)
    end
  end

  @doc "Every revocation on record, `{timestamp, siblings}`, oldest first."
  @spec revocations() :: [{DateTime.t(), non_neg_integer()}]
  def revocations do
    from(d in "catalog_deterministic_builds",
      where: not is_nil(d.revoked_at),
      group_by: d.revoked_at,
      order_by: d.revoked_at,
      select: {type(d.revoked_at, :utc_datetime_usec), count()}
    )
    |> Repo.all()
  end

  @doc "Puts back the siblings one `revoke/1` call revoked at `at`; returns how many."
  @spec undo(DateTime.t()) :: {:ok, non_neg_integer()}
  def undo(%DateTime{} = at) do
    {n, _} =
      from(d in "catalog_deterministic_builds",
        where: d.revoked_at == type(^at, :utc_datetime_usec),
        update: [
          set: [
            revoked_at: nil,
            revoked_reason: nil,
            updated_at: type(^DateTime.utc_now(), :utc_datetime_usec)
          ]
        ]
      )
      |> Repo.update_all([])

    Logger.warning("restored #{n} deterministic siblings revoked at #{DateTime.to_iso8601(at)}")
    {:ok, n}
  end

  defp filtered?(opts),
    do: Keyword.get(opts, :everything) == true or Enum.any?(@filters, &(opts[&1] != nil))

  defp act(opts) do
    at = DateTime.utc_now()

    Repo.transaction(fn ->
      rows = opts |> candidates() |> Repo.all()
      ids = Enum.map(rows, & &1.id)

      from(d in "catalog_deterministic_builds",
        where: d.id in type(^ids, {:array, :binary_id}) and is_nil(d.revoked_at),
        update: [
          set: [
            revoked_at: type(^at, :utc_datetime_usec),
            revoked_reason: ^@reason,
            updated_at: type(^at, :utc_datetime_usec)
          ]
        ]
      )
      |> Repo.update_all([])

      for row <- rows do
        Logger.warning(
          "revoked deterministic sibling #{row.package} #{row.version} (#{row.toolchain}, " <>
            "#{row.variant}, #{row.config_variant}) at #{DateTime.to_iso8601(at)}"
        )
      end

      {:revoked, length(rows), rows, at}
    end)
    |> elem(1)
  end

  defp candidates(opts) do
    from(d in "catalog_deterministic_builds",
      join: t in "catalog_toolchain_builds",
      on: t.id == d.toolchain_build_id,
      join: p in "catalog_packages",
      on: p.id == d.package_id,
      where: d.status == "pass" and is_nil(d.revoked_at),
      order_by: [p.name, d.version, t.toolchain, t.variant, t.config_variant],
      select: %{
        id: type(d.id, :binary_id),
        package: p.name,
        version: d.version,
        toolchain: t.toolchain,
        variant: t.variant,
        config_variant: t.config_variant,
        judge_revision: d.judge_revision
      }
    )
    |> filter(opts[:package], &where(&1, [_d, _t, p], p.name == ^&2))
    |> filter(opts[:version], &where(&1, [d], d.version == ^&2))
    |> filter(opts[:judge_revision], &where(&1, [d], d.judge_revision >= ^&2))
  end

  defp filter(query, nil, _fun), do: query
  defp filter(query, value, fun), do: fun.(query, value)
end
