defmodule NccAgent.Application do
  @moduledoc """
  Loads the configuration and starts the agent: the identity and one
  `NccAgent.Slot` per configured slot. A release without its environment
  must not spin, so a bad configuration stops the VM before any slot runs.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:ncc_agent, :load_config, true) do
        case NccAgent.Config.load() do
          {:ok, config} ->
            NccAgent.Config.put(config)
            [NccAgent.Identity, slots(config)]

          {:error, errors} ->
            Enum.each(errors, &Logger.error/1)
            System.stop(1)
            []
        end
      else
        # Tests drive the identity and the jobs themselves.
        [NccAgent.Identity]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NccAgent.Supervisor)
  end

  defp slots(config) do
    %{
      id: NccAgent.SlotSupervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           Enum.map(1..config.slots, &{NccAgent.Slot, &1}),
           [strategy: :one_for_one, name: NccAgent.SlotSupervisor]
         ]}
    }
  end
end
