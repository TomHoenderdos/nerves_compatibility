defmodule NccAgent.Application do
  @moduledoc """
  Loads the configuration, installs the egress ruleset (`NccAgent.Egress`;
  a failure is logged, and the slots refuse to claim until it verifies) and
  starts the agent: the identity, the updater
  and one `NccAgent.Slot` per configured slot (each stopped with time to
  kill its container and hand its lease back). A release without its environment
  must not spin, so a bad configuration stops the VM before any slot runs.
  """
  use Application

  require Logger

  @impl true
  def start(_type, _args) do
    # Owned by this process, which lives as long as the application.
    NccAgent.HexRegistry.create_table()

    children =
      if Application.get_env(:ncc_agent, :load_config, true) do
        case NccAgent.Config.load() do
          {:ok, config} ->
            NccAgent.Config.put(config)
            clear_scratch(config)
            install_egress()
            [NccAgent.Identity, NccAgent.Updater, slots(config)]

          {:error, errors} ->
            Enum.each(errors, &Logger.error/1)
            System.stop(1)
            []
        end
      else
        # Tests drive the identity, the updater and the jobs themselves.
        [NccAgent.Identity, NccAgent.Updater]
      end

    Supervisor.start_link(children, strategy: :one_for_one, name: NccAgent.Supervisor)
  end

  # No job runs yet: whatever is in the scratch dir is left over from a
  # VM that stopped mid-job, and so is any worker container still running,
  # which would otherwise keep writing into the binds being removed.
  # sobelow_skip ["Traversal.FileModule"]
  defp clear_scratch(config) do
    NccAgent.Docker.kill_leftovers(config)
    scratch = NccAgent.Config.path(config, :scratch)
    File.rm_rf(scratch)
    File.mkdir_p(scratch)
  end

  # A failed install must not stop the VM: every slot verifies before each
  # claim, reinstalls once and claims nothing until the ruleset is in place.
  defp install_egress do
    case NccAgent.Egress.install() do
      :ok -> Logger.info("egress ruleset installed")
      {:error, why} -> Logger.error("egress ruleset not installed; slots will not claim: #{why}")
    end
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
