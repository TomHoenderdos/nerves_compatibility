defmodule Portal.Catalog.RelocationMark do
  @moduledoc """
  Sets `relocation_run_id` in every write of a toolchain build: the write's
  own `run_id` when it sets a `relocation` record, else nil. The record then
  counts only while that run is still the row's
  (`Portal.Precompiled.Relocated.counted/1`): a release that does not know
  these columns rewrites `run_id` and leaves them.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    run_id =
      case Ash.Changeset.get_attribute(changeset, :relocation) do
        %{} -> Ash.Changeset.get_attribute(changeset, :run_id)
        _ -> nil
      end

    Ash.Changeset.force_change_attribute(changeset, :relocation_run_id, run_id)
  end
end
