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

  @doc """
  Makes the agent's own user (root, under systemd) the owner of one tree it
  just extracted (`NccAgent.BuildCache`), whatever the archive or the
  extraction left: the build user may read a build cache entry, never own
  or write it. A failure is an error for the caller, which then does not
  publish the entry. `-R` without `-H`/`-L` is physical: a link in the
  tree is re-owned itself, never followed.
  """
  @spec own_tree(Path.t()) :: :ok | {:error, {:chown, non_neg_integer()}}
  # sobelow_skip ["CI.System"]
  def own_tree(path) do
    case System.cmd("chown", ["-R", Config.defaults().build_user, path], stderr_to_stdout: true) do
      {_, 0} -> :ok
      {_, status} -> {:error, {:chown, status}}
    end
  end
end
