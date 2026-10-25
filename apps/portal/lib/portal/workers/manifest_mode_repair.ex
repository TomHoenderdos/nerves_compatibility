defmodule Portal.Workers.ManifestModeRepair do
  @moduledoc """
  Oban worker (queue `:maintenance`, the admin Maintenance page's "Repair
  published file modes" button, no cron) that runs
  `Portal.Catalog.ManifestModeRepair.run/1` once over every stored run.
  """

  use Oban.Worker,
    queue: :maintenance,
    unique: [period: 86_400, states: :incomplete]

  alias Portal.Catalog.ManifestModeRepair

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    _report = ManifestModeRepair.run()
    :ok
  end

  @doc "Queue a repair now. `{:error, :already_queued}` while one is pending."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, :already_queued | term()}
  def enqueue do
    case %{} |> new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :already_queued}
      other -> other
    end
  end
end
