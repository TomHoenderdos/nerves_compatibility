defmodule NccWorker.ConfigOverlay do
  @moduledoc """
  Writes a config variant's overlay (`Compatibility.ConfigVariants`) as the
  toolchain run's `config/config.exs`, before the traced compile. The
  project's Mix VM loads it (`loadconfig`), so the compile-time trace's config
  snapshot (R5) records the overlay's values for every key the closure reads.

  The plain project (`mix new`) has no `config/`; a file already there means
  something else wrote it, and it is never overwritten.
  """

  alias Compatibility.ConfigVariants

  @spec write(String.t(), String.t()) :: :ok | {:error, term()}
  # project_dir is the run's own project under the work mount.
  # sobelow_skip ["Traversal.FileModule"]
  def write(project_dir, name) do
    path = Path.join([project_dir, "config", "config.exs"])

    case ConfigVariants.overlay(name) do
      {:ok, []} -> :ok
      {:ok, items} -> put(path, items)
      :error -> {:error, {:unknown_config_variant, name}}
    end
  end

  # `:exclusive` creates the file or fails, in one step: nothing written
  # there between a check and the write can be overwritten.
  # sobelow_skip ["Traversal.FileModule"]
  defp put(path, items) do
    with :ok <- File.mkdir_p(Path.dirname(path)) do
      case File.write(path, ConfigVariants.render(items), [:exclusive]) do
        {:error, :eexist} -> {:error, :config_exists}
        other -> other
      end
    end
  end
end
