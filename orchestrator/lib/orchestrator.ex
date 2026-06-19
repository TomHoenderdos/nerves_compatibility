defmodule Orchestrator do
  @moduledoc """
  Nerves Compatibility Orchestrator.

  Coordinates polling Hex.pm for packages and running compatibility checks.
  """

  @doc """
  Returns the configuration for the orchestrator.
  """
  def config() do
    Application.get_all_env(:orchestrator)
  end

  @doc """
  Get the polling interval in milliseconds.
  """
  def poll_interval() do
    Application.get_env(:orchestrator, :poll_interval_ms, :timer.hours(1))
  end

  @doc """
  Hex usernames whose owned packages get prepended to the scan queue so
  they're covered first. Empty list disables the priority step.
  """
  def priority_users() do
    Application.get_env(:orchestrator, :priority_users, [])
  end

  @doc """
  Get the path to the runner executable.
  """
  def runner_path() do
    Application.get_env(:orchestrator, :runner_path, "../runner/ncc_runner")
    |> Path.expand()
  end

  @doc """
  Get the path to the worker Docker image.
  """
  def docker_image() do
    Application.get_env(:orchestrator, :docker_image, "ncc-worker:local")
  end

  @doc """
  Get the directory for storing temporary runner files.
  """
  def runner_tmp_dir() do
    Application.get_env(:orchestrator, :runner_tmp_dir, "../runner/tmp")
    |> Path.expand()
  end

  @doc """
  Get the directory for storing compatibility test results.
  """
  def results_dir() do
    Application.get_env(:orchestrator, :results_dir, "../compat_test_results")
    |> Path.expand()
  end

  @doc """
  Get the directory for the public site output.
  """
  def public_dir() do
    Application.get_env(:orchestrator, :public_dir, "../public")
    |> Path.expand()
  end

  @doc """
  Get the directory for example data (used for initial site generation).
  """
  def example_data_dir() do
    Application.get_env(:orchestrator, :example_data_dir, "../example_data")
    |> Path.expand()
  end

  @doc """
  Get the path to the DETS queue file.
  """
  def queue_file() do
    Application.get_env(:orchestrator, :queue_file, "queue.dets")
    |> Path.expand()
  end

  @doc """
  Get the path to the checked packages DETS file.
  """
  def checked_file() do
    Application.get_env(:orchestrator, :checked_file, "checked.dets")
    |> Path.expand()
  end

  @doc """
  Get the path to the package metadata JSON file.
  """
  @spec package_metadata_file() :: Path.t()
  def package_metadata_file() do
    Application.get_env(:orchestrator, :package_metadata_file, "../package_metadata.json")
    |> Path.expand()
  end

  @doc """
  Load package metadata.

  Returns empty metadata if file doesn't exist or on error.
  """
  @spec load_package_metadata() :: Compatibility.PackageMetadata.t()
  def load_package_metadata() do
    case Compatibility.PackageMetadata.load(package_metadata_file()) do
      {:ok, metadata} -> metadata
      {:error, _} -> %Compatibility.PackageMetadata{}
    end
  end
end
