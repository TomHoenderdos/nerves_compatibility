defmodule Portal.Precompiled.HostNativeRevocation do
  @moduledoc """
  Revokes published host-native builds (`Portal.Catalog.HostNativeBuild`,
  board #85) one identity at a time. The `host_native_enabled` setting takes
  every one of them out at once and `Portal.Precompiled.Withheld` a whole
  package; this is the lever for a build found unsafe on its own (a judge
  refinement rolled back, an upstream archive found bad). Nothing runs it on
  its own.

  A revoked build gets `revoked_at`: it is not served (manifests, the
  package list, `files/{sha256}`), its package's fingerprint changes so the
  next signed batch drops it, and a rebuild of the same identity (package,
  version, toolchain, triple, `builder_version`) stays revoked, because the
  ingest's upsert never writes `revoked_at`. `undo/1` puts a call back.

  `revoke/1` takes a filter: `package:` (name), `version:`, `triple:`,
  `judge_revision:` (revision `n` or later, the rollback of a refinement
  that shipped at `n`), or `everything: true`. Only passing, unrevoked
  builds are candidates. It only lists unless given `dry_run: false`, and
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
          triple: String.t(),
          judge_revision: integer() | nil
        }

  @filters [:package, :version, :triple, :judge_revision]

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

  @doc "Every revocation on record, `{timestamp, builds}`, oldest first."
  @spec revocations() :: [{DateTime.t(), non_neg_integer()}]
  def revocations do
    from(h in "catalog_host_native_builds",
      where: not is_nil(h.revoked_at),
      group_by: h.revoked_at,
      order_by: h.revoked_at,
      select: {type(h.revoked_at, :utc_datetime_usec), count()}
    )
    |> Repo.all()
  end

  @doc "Puts back the builds one `revoke/1` call revoked at `at`; returns how many."
  @spec undo(DateTime.t()) :: {:ok, non_neg_integer()}
  def undo(%DateTime{} = at) do
    {n, _} =
      from(h in "catalog_host_native_builds",
        where: h.revoked_at == type(^at, :utc_datetime_usec),
        update: [
          set: [revoked_at: nil, updated_at: type(^DateTime.utc_now(), :utc_datetime_usec)]
        ]
      )
      |> Repo.update_all([])

    Logger.warning("restored #{n} host-native builds revoked at #{DateTime.to_iso8601(at)}")
    {:ok, n}
  end

  defp filtered?(opts),
    do: Keyword.get(opts, :everything) == true or Enum.any?(@filters, &(opts[&1] != nil))

  defp act(opts) do
    at = DateTime.utc_now()

    Repo.transaction(fn ->
      rows = opts |> candidates() |> Repo.all()
      ids = Enum.map(rows, & &1.id)

      from(h in "catalog_host_native_builds",
        where: h.id in type(^ids, {:array, :binary_id}) and is_nil(h.revoked_at),
        update: [
          set: [
            revoked_at: type(^at, :utc_datetime_usec),
            updated_at: type(^at, :utc_datetime_usec)
          ]
        ]
      )
      |> Repo.update_all([])

      for row <- rows do
        Logger.warning(
          "revoked host-native build #{row.package} #{row.version} #{row.triple} " <>
            "(#{row.toolchain}) at #{DateTime.to_iso8601(at)}"
        )
      end

      {:revoked, length(rows), rows, at}
    end)
    |> elem(1)
  end

  defp candidates(opts) do
    from(h in "catalog_host_native_builds",
      join: p in "catalog_packages",
      on: p.id == h.package_id,
      where: h.status == "pass" and is_nil(h.revoked_at),
      order_by: [p.name, h.version, h.triple, h.toolchain],
      select: %{
        id: type(h.id, :binary_id),
        package: p.name,
        version: h.version,
        toolchain: h.toolchain,
        triple: h.triple,
        judge_revision: h.judge_revision
      }
    )
    |> filter(:package, opts[:package], &where(&1, [_h, p], p.name == ^&2))
    |> filter(:version, opts[:version], &where(&1, [h], h.version == ^&2))
    |> filter(:triple, opts[:triple], &where(&1, [h], h.triple == ^&2))
    |> filter(:judge_revision, opts[:judge_revision], &where(&1, [h], h.judge_revision >= ^&2))
  end

  defp filter(query, _key, nil, _fun), do: query
  defp filter(query, _key, value, fun), do: fun.(query, value)
end
