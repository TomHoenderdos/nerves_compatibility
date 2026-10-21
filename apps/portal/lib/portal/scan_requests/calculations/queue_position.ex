defmodule Portal.ScanRequests.Calculations.QueuePosition do
  @moduledoc """
  A request's place in the build queue, from its Oban job: the map
  `Portal.Admin.queue_positions/1` gives for it (`priority`, `state`,
  `attempt`, `adjustable?`), or nil when no job is waiting. Computed for the
  whole page of requests in one query, so the numbers are the ones the old
  admin page showed.
  """
  use Ash.Resource.Calculation

  @impl true
  def calculate(requests, _opts, _context) do
    positions = Portal.Admin.queue_positions(Enum.map(requests, & &1.id))
    Enum.map(requests, &Map.get(positions, &1.id))
  end
end
