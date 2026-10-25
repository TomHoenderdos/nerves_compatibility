defmodule NccAgent.Fs do
  @moduledoc "Host-side filesystem helpers shared by `NccAgent.Job` and `NccAgent.NervesCache`."

  require Logger

  alias NccAgent.Config

  @doc """
  Hands `paths` to `config.build_user` when it is not the agent's own user,
  logging a failure. `flags` is `["-R"]` for a dir tree the agent just
  created, or `[]`: the non-recursive form adds `-h`, so a symlink a
  container planted is re-owned itself and never its target (the agent runs
  as root).
  """
  @spec chown(Config.t(), [Path.t()], [String.t()]) :: :ok
  # sobelow_skip ["CI.System"]
  def chown(config, paths, flags) do
    flags = if "-R" in flags, do: flags, else: ["-h" | flags]

    if config.build_user != Config.defaults().build_user do
      case System.cmd("chown", flags ++ [config.build_user | paths], stderr_to_stdout: true) do
        {_, 0} ->
          :ok

        {out, status} ->
          Logger.warning("chown #{config.build_user} exited #{status}: #{String.trim(out)}")
      end
    end

    :ok
  end
end
