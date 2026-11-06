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
  As `chown/3` with `-R` on one tree the agent just extracted, but a failure
  is an error for the caller: a build cache entry the build user cannot read
  must not be published (`NccAgent.BuildCache`). `-R` without `-H`/`-L` is
  physical: a link in the tree is re-owned itself, never followed.
  """
  @spec chown_tree(Config.t(), Path.t()) :: :ok | {:error, {:chown, non_neg_integer()}}
  # sobelow_skip ["CI.System"]
  def chown_tree(config, path) do
    if config.build_user == Config.defaults().build_user do
      :ok
    else
      case System.cmd("chown", ["-R", config.build_user, path], stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, status} -> {:error, {:chown, status}}
      end
    end
  end
end
