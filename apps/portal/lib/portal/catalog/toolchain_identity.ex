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

  @legacy_index "catalog_toolchain_builds_unique_identity_index"

  @spec legacy_index() :: String.t()
  def legacy_index, do: @legacy_index

  @spec config_variants_ready?() :: boolean()
  def config_variants_ready? do
    %{rows: [[present]]} =
      Portal.Repo.query!("SELECT to_regclass($1) IS NOT NULL", [@legacy_index])

    not present
  end
end
