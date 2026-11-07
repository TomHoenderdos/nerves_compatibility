defmodule Portal.Catalog.ToolchainBuild.MarkRun do
  @moduledoc """
  Sets `compile_env_run_id` in every write of a toolchain build: the write's
  own `run_id` when it sets `compile_env_rule`, else nil. The mark then
  names the run that wrote it, and counts only while that run is still the
  row's (`Portal.Precompiled.Withheld.records_config_reads?/1`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    run_id =
      if Ash.Changeset.get_attribute(changeset, :compile_env_rule) != nil,
        do: Ash.Changeset.get_attribute(changeset, :run_id)

    Ash.Changeset.force_change_attribute(changeset, :compile_env_run_id, run_id)
  end
end
