defmodule NccAgent.NervesCache do
  @moduledoc """
  The per-run view of the shared Nerves cache. This minimal version gives a
  run an empty `work/nerves/artifacts` and `work/nerves/dl` and never warms;
  Task 14 completes it with the symlink farm onto the read-only
  `/nerves-cache` and the allowlisted warm run.
  """

  alias NccAgent.Config

  @artifacts "/work/nerves/artifacts"
  @dl "/work/nerves/dl"

  @type prepared :: %{
          env: [{String.t(), String.t()}],
          artifacts_dir: Path.t(),
          dl_dir: Path.t()
        }

  @doc "Creates the run's Nerves dirs under `work_dir` and returns the worker env for them."
  @spec prepare(Config.t(), Path.t()) :: prepared()
  # `work_dir` is the job's own scratch dir.
  # sobelow_skip ["Traversal.FileModule"]
  def prepare(_config, work_dir) do
    artifacts = Path.join(work_dir, "nerves/artifacts")
    dl = Path.join(work_dir, "nerves/dl")
    File.mkdir_p!(artifacts)
    File.mkdir_p!(dl)

    %{
      env: [{"NERVES_ARTIFACTS_DIR", @artifacts}, {"NERVES_DL_DIR", @dl}],
      artifacts_dir: artifacts,
      dl_dir: dl
    }
  end

  @doc "Warms the shared cache with a run's allowlisted misses. Not yet: always `:skipped`."
  @spec warm(Config.t(), map(), map()) :: :ok | :skipped | {:error, term()}
  def warm(_config, _claim, _result), do: :skipped
end
