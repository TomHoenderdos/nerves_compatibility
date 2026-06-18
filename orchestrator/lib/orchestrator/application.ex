defmodule Orchestrator.Application do
  @moduledoc """
  The Orchestrator application.

  Supervises the Hex polling and package processing workflows.
  """

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("Starting Nerves Compatibility Orchestrator")

    children =
      [
        # Durable queue for package/versions to process
        {Orchestrator.Queue, []},
        # Polls Hex.pm for new packages
        {Orchestrator.HexPoller, []},
        # Processes packages from the queue
        {Orchestrator.Processor, []}
      ]
      |> maybe_add_scan_request_server()

    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp maybe_add_scan_request_server(children) do
    if Application.get_env(:orchestrator, :scan_request_server, false) do
      port = Application.get_env(:orchestrator, :scan_request_port, 4080)

      Logger.info("Starting scan request API on port #{port}")

      children ++
        [
          {Bandit, plug: Orchestrator.ScanRequestRouter, scheme: :http, port: port}
        ]
    else
      children
    end
  end
end
