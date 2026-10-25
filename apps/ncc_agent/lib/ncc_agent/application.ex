defmodule NccAgent.Application do
  @moduledoc """
  Loads the configuration and starts the agent. A release without its
  environment must not spin, so a bad configuration stops the VM.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    if Application.get_env(:ncc_agent, :load_config, true), do: load_config!()

    # Tasks 13-15 add the slot supervisor and the egress ruleset.
    children = [NccAgent.Identity]
    Supervisor.start_link(children, strategy: :one_for_one, name: NccAgent.Supervisor)
  end

  defp load_config! do
    case NccAgent.Config.load() do
      {:ok, config} ->
        NccAgent.Config.put(config)

      {:error, errors} ->
        Enum.each(errors, &Logger.error/1)
        System.stop(1)
    end
  end
end
