defmodule Portal.Workers.CoverageRefresh do
  @moduledoc """
  Hourly cron (queue `:intake`) and the admin Maintenance page's refresh
  button: computes `Portal.Catalog.Coverage.report/1` and the two coverage
  metrics (`Portal.Catalog.CoverageMetrics`) and stores both for the page
  to show.

  The report asks the Hex registry (`Portal.HexDeps`, cached for an hour)
  about every ranked package's optional dependencies, and the metrics read
  the whole registry (`Portal.HexRegistry`) and the whole catalog, so they
  are computed here, on the web host's HTTP queue, and never on a page load
  or click. Unique while one is waiting or running, so repeated clicks queue
  one refresh. One that fails leaves the other stored.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  alias Portal.Catalog.{Coverage, CoverageMetrics}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    report = safely(fn -> Coverage.store(Coverage.report()) end)
    metrics = safely(&refresh_metrics/0)

    case {report, metrics} do
      {{:ok, _stored}, {:ok, _metrics}} -> :ok
      {{:error, reason}, _metrics} -> {:error, reason}
      {_report, {:error, reason}} -> {:error, reason}
    end
  end

  defp refresh_metrics do
    with {:ok, registry} <- registry_source().snapshot(all_versions: true) do
      registry |> CoverageMetrics.compute() |> CoverageMetrics.store()
    end
  end

  # A step that raises is an error like any other, so the other step still
  # runs and stores; the job then fails and Oban retries both.
  defp safely(step) do
    step.()
  rescue
    exception -> {:error, Exception.message(exception)}
  end

  defp registry_source,
    do: Application.get_env(:portal, :coverage_registry_source, Portal.HexRegistry)

  @doc "Queue a refresh now (the admin button)."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue, do: %{} |> new() |> Oban.insert()
end
