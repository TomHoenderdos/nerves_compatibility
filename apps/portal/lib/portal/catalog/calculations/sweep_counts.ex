defmodule Portal.Catalog.Calculations.SweepCounts do
  @moduledoc """
  A sweep's job counts: `Portal.BulkRebuild.status/1`'s map, for every sweep
  Ash loaded for this page in one call (`Portal.BulkRebuild.status_many/1`)
  instead of one `status/1` per row. The admin Maintenance page loads this
  instead of calling `status/1` while rendering each row.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(sweeps, _opts, _context) do
    counts = Portal.BulkRebuild.status_many(Enum.map(sweeps, & &1.id))
    Enum.map(sweeps, &Map.fetch!(counts, &1.id))
  end
end
