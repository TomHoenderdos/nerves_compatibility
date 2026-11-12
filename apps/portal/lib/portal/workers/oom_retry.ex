defmodule Portal.Workers.OomRetry do
  @moduledoc """
  Whether a build job's attempt retries an OOM-killed container.

  A container the kernel OOM-kills exits 137, which `Portal.Workers.Build`
  and `Portal.Workers.ToolchainBuild` return as `{:error, "worker/runner exit
  137"}`, and Oban stores in the job's `errors`, newest last. The attempt
  after one retries with less memory demand: `Build` with one target at a
  time (`NCC_BUILD_CONCURRENCY=1`), `ToolchainBuild` at the build memory
  limit rather than the toolchain one.
  """

  @doc "True on an attempt after the first whose newest error is an exit 137."
  @spec oom_retry?(Oban.Job.t()) :: boolean()
  def oom_retry?(%Oban.Job{attempt: attempt} = job) when is_integer(attempt) and attempt > 1 do
    case last_error(job) do
      error when is_binary(error) -> String.contains?(error, "exit 137")
      nil -> false
    end
  end

  def oom_retry?(%Oban.Job{}), do: false

  @doc "The newest entry of the job's `errors`, as its `\"error\"` string, or nil."
  @spec last_error(Oban.Job.t()) :: String.t() | nil
  def last_error(%Oban.Job{errors: errors}) when is_list(errors) and errors != [] do
    case List.last(errors) do
      %{"error" => error} when is_binary(error) -> error
      _ -> nil
    end
  end

  def last_error(%Oban.Job{}), do: nil
end
