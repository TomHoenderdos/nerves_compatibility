defmodule Portal.Precompiled.RelocationRevocation do
  @moduledoc """
  The lever for relocated builds (`Portal.Precompiled.Relocated`): revokes
  every toolchain row of a package (and version), or all of them, whose own
  build or any earlier build (`Portal.Catalog.ToolchainBuild.EarlierBuilds`)
  is relocated. A build counts only while its record is its own run's
  (`relocation_run_id = run_id`). Revoking a row hides its earlier builds
  too, a plain one beside a relocated one included.

  Counts first: `dry_run: true` is the default and writes nothing, and its
  listing is cut at `limit:` (50). Acting needs a filter. A revoked build
  gets `revoked_at` and `revoked_reason` (`reason/0`) and leaves the
  manifest at the next batch with its files. `undo/1` puts back exactly one
  act's rows. Nothing runs it on its own. Turning `relocated_enabled` off is
  the lever for all of them at once without revoking any.
  """

  import Ecto.Query

  require Logger

  alias Portal.Repo

  @reason "relocation revoked"
  @table "catalog_toolchain_builds"
  @filters [:package, :version]

  @type row :: %{
          id: Ecto.UUID.t(),
          package: String.t(),
          version: String.t(),
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
    {n, _} =
      from(t in @table,
        where: t.revoked_at == type(^at, :utc_datetime_usec) and t.revoked_reason == ^@reason,
        update: [
          set: [
            revoked_at: nil,
            revoked_reason: nil,
            updated_at: type(^DateTime.utc_now(), :utc_datetime_usec)
          ]
        ]
      )
      |> Repo.update_all([])

    Logger.warning("restored #{n} relocated builds revoked at #{DateTime.to_iso8601(at)}")
    n
  end

  defp filtered?(opts),
    do: Keyword.get(opts, :everything) == true or Enum.any?(@filters, &(opts[&1] != nil))

  defp act(opts) do
    at = DateTime.utc_now()

    Repo.transaction(fn ->
      rows = rows(opts)
      ids = Enum.map(rows, & &1.id)

      from(t in @table,
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

      for row <- rows do
        Logger.warning(
          "relocation revoked: #{row.package} #{row.version} #{row.id} at #{DateTime.to_iso8601(at)}"
        )
      end

      {:revoked, length(rows), rows, at}
    end)
    |> elem(1)
  end

  defp rows(opts) do
    from(t in @table,
      as: :build,
      join: p in "catalog_packages",
      as: :package,
      on: p.id == t.package_id,
      where: is_nil(t.revoked_at),
      where:
        t.relocation_run_id == t.run_id or
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS e WHERE e->>'relocation_run_id' = e->>'run_id')",
            t.earlier_builds
          ),
      order_by: [p.name, t.version, t.id],
      select: %{
        id: type(t.id, Ecto.UUID),
        package: p.name,
        version: t.version,
        config_variant: t.config_variant
      }
    )
    |> where_package(opts[:package])
    |> where_version(opts[:version])
    |> Repo.all()
  end

  defp where_package(query, nil), do: query
  defp where_package(query, name), do: where(query, [package: p], p.name == ^name)

  defp where_version(query, nil), do: query
  defp where_version(query, version), do: where(query, [build: t], t.version == ^version)
end
