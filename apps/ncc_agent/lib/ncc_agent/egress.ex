defmodule NccAgent.Egress do
  @moduledoc """
  The builder's egress ruleset (isolation design, section 3): chain
  `NCC-EGRESS` in the rootful daemon's `DOCKER-USER` chain, written and
  checked by `priv/egress.sh` (`NccAgent.Config` `egress_script`).

  `install/0` (re)writes the chain; `verify/0` checks it is in place. Both
  run the script with a 30 s limit and answer `{:error, output}` on any
  failure, a missing script included. Installs are serialised, so slots
  reinstalling at once do not interleave their `iptables` calls.
  """

  alias NccAgent.Config

  @timeout_ms 30_000

  @spec install() :: :ok | {:error, String.t()}
  def install do
    :global.trans({__MODULE__, :install}, fn -> run("install") end)
  end

  @spec verify() :: :ok | {:error, String.t()}
  def verify, do: run("verify")

  @doc "`\"ok\"` when `verify/0` passes, `\"missing\"` otherwise (the `/status` value)."
  @spec status() :: String.t()
  def status, do: if(verify() == :ok, do: "ok", else: "missing")

  defp run(action) do
    script = Config.get().egress_script
    task = Task.async(fn -> cmd(script, action) end)

    case Task.yield(task, @timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, "#{action}: #{inspect(reason)}"}
      nil -> {:error, "#{action}: timed out after #{div(@timeout_ms, 1000)} s"}
    end
  end

  # sobelow_skip ["CI.System"]
  defp cmd(script, action) do
    case System.cmd(script, [action], stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, status} -> {:error, "#{action} exited #{status}: #{String.trim(output)}"}
    end
  rescue
    e in ErlangError -> {:error, "#{action}: cannot run #{script}: #{inspect(e.original)}"}
  end
end
