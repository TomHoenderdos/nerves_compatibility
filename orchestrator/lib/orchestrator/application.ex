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

    children = [
      # Durable queue for package/versions to process
      {Orchestrator.Queue, []},
      # Polls Hex.pm for new packages
      {Orchestrator.HexPoller, []},
      # Processes packages from the queue
      {Orchestrator.Processor, []}
    ]

    opts = [strategy: :one_for_one, name: Orchestrator.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
