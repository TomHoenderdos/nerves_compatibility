defmodule Portal.Catalog.ForeignPrivMark do
  @moduledoc """
  Sets `foreign_priv_run_id` in every write of a toolchain, pinned or
  deterministic build: the write's own `run_id` when it sets a non-empty
  `foreign_priv`, else nil. The list then counts only while that run is
  still the row's (`Portal.Precompiled.ForeignPriv.counted/1`): a release
  that does not know these columns rewrites `run_id` and leaves them.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    run_id =
      case Ash.Changeset.get_attribute(changeset, :foreign_priv) do
        [_ | _] -> Ash.Changeset.get_attribute(changeset, :run_id)
        _ -> nil
      end

    Ash.Changeset.force_change_attribute(changeset, :foreign_priv_run_id, run_id)
  end
end
