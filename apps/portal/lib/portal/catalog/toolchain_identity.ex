defmodule Portal.Catalog.ToolchainIdentity do
  @moduledoc """
  Whether toolchain builds can be stored per config variant yet.

  The identity gained `config_variant` with a second unique index beside the
  old five-column one, which the release before config variants still
  upserts against while a deploy rolls out. While that old index exists, a
  second config variant of one identity cannot be stored, so the backlog
  proposes none (`Portal.Catalog.toolchain_backlog/3`). Dropping the index
  opens it; recreating it (a rollback) closes it again.
  """

  require Logger

  @legacy_index "catalog_toolchain_builds_unique_identity_index"

  @spec legacy_index() :: String.t()
  def legacy_index, do: @legacy_index

  @doc """
  True once the legacy index is gone. Fails closed: when the database cannot
  be asked (an error or a raise from `repo`), it logs a warning and answers
  false, so the backlog proposes only defaults until it can be asked again.
  """
  @spec config_variants_ready?(module()) :: boolean()
  def config_variants_ready?(repo \\ Portal.Repo) do
    case repo.query("SELECT to_regclass($1) IS NOT NULL", [@legacy_index]) do
      {:ok, %{rows: [[present]]}} -> not present
      other -> closed(other)
    end
  rescue
    exception -> closed(exception)
  end

  defp closed(reason) do
    Logger.warning(
      "could not check for #{@legacy_index}, config variants stay off: #{inspect(reason)}"
    )

    false
  end
end
