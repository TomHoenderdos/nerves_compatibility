defmodule Portal.Workers.CoverageRefresh do
  @moduledoc """
  Hourly cron (queue `:intake`) and the admin Maintenance page's refresh
  button: computes `Portal.Catalog.Coverage.report/1` and stores it
  (`Portal.Catalog.Coverage.store/1`) for the page to show.

  The report asks the Hex registry (`Portal.HexDeps`, cached for an hour)
  about every ranked package's optional dependencies, so it is computed here,
  on the web host's HTTP queue, and never on a page load or click. Unique
  while one is waiting or running, so repeated clicks queue one refresh.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Catalog.Coverage

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case Coverage.store(Coverage.report()) do
      {:ok, _stored} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Queue a refresh now (the admin button)."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()
end
