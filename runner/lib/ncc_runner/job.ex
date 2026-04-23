defmodule NccRunner.Job do
  @moduledoc """
  Job payload definition and validation.

  The job.json format defines:
  - run_id: Unique identifier for this test run
  - image_digest: SHA256 digest of the worker container image
  - image_name: Full image reference (e.g., ghcr.io/org/ncc-worker)
  - package: Package information to test (forwarded to worker)
  - systems_override: Optional map of system packages to version requirements
  - systems_filter: Optional list of system names to test (e.g., ["nerves_system_rpi4"])
  - limits: Optional resource limits
  - docker: Optional Docker-specific configuration
  - cache_dir: Optional host path for Hex cache persistence
  """

  @type t :: %__MODULE__{
          run_id: String.t(),
          image_digest: String.t(),
          image_name: String.t(),
          package: map(),
          systems_override: nil | map(),
          systems_filter: nil | [String.t()],
          limits: nil | limits(),
          docker: nil | docker_config(),
          cache_dir: nil | String.t()
        }

  @type limits :: %{
          optional(:timeout_seconds) => pos_integer(),
          optional(:max_log_bytes) => pos_integer()
        }

  @type docker_config :: %{
          optional(:platform) => String.t(),
          optional(:network_mode) => String.t(),
          optional(:extra_hosts) => [String.t()],
          optional(:memory) => String.t(),
          optional(:cpus) => String.t(),
          optional(:pids_limit) => pos_integer()
        }

  defstruct [
    :run_id,
    :image_digest,
    :image_name,
    :package,
    :systems_override,
    :systems_filter,
    :limits,
    :docker,
    :cache_dir,
    :files_dir
  ]

  @doc """
  Load and validate a job from a JSON file.

  ## Examples

      iex> NccRunner.Job.load("path/to/job.json")
      {:ok, %NccRunner.Job{run_id: "test-1", ...}}

      iex> NccRunner.Job.load("invalid.json")
      {:error, "missing required field: run_id"}
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, String.t()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content),
         {:ok, job} <- from_map(data) do
      {:ok, job}
    end
  end

  @doc """
  Convert a map to a Job struct with validation.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, String.t()}
  def from_map(data) when is_map(data) do
    with {:ok, run_id} <- required_string(data, "run_id"),
         {:ok, image_digest} <- required_string(data, "image_digest"),
         {:ok, image_name} <- required_string(data, "image_name"),
         {:ok, package} <- required_map(data, "package"),
         :ok <- validate_digest(image_digest) do
      job = %__MODULE__{
        run_id: run_id,
        image_digest: image_digest,
        image_name: image_name,
        package: package,
        systems_override: data["systems_override"],
        systems_filter: data["systems_filter"],
        limits: parse_limits(data["limits"]),
        docker: parse_docker_config(data["docker"]),
        cache_dir: data["cache_dir"],
        files_dir: data["files_dir"]
      }

      {:ok, job}
    end
  end

  def from_map(_), do: {:error, "job payload must be a JSON object"}

  @doc """
  Get the full Docker image reference.

  For remote images (containing a registry), uses name@digest format.
  For local images (no registry), uses just the name/tag.
  """
  @spec image_ref(t()) :: String.t()
  def image_ref(%__MODULE__{image_name: name, image_digest: digest}) do
    # If the image name contains a registry (has a slash before any colon),
    # it's likely a remote image and we should use digest.
    # Otherwise, it's a local image and we should just use the name/tag.
    if String.contains?(name, "/") do
      # Remote image - use digest for reproducibility
      "#{name}@#{digest}"
    else
      # Local image - just use the tag
      name
    end
  end

  @doc """
  Prepare the input.json that will be written to the work directory for the worker.
  This includes the package info and any overrides.
  """
  @spec worker_input(t()) :: map()
  def worker_input(%__MODULE__{} = job) do
    input = %{
      "run_id" => job.run_id,
      "image" => %{
        "name" => job.image_name,
        "digest" => job.image_digest
      },
      "package" => job.package
    }

    input =
      if job.systems_override do
        Map.put(input, "systems_override", job.systems_override)
      else
        input
      end

    input =
      if job.systems_filter do
        Map.put(input, "systems_filter", job.systems_filter)
      else
        input
      end

    if job.limits do
      Map.put(input, "limits", job.limits)
    else
      input
    end
  end

  # Private helpers

  defp required_string(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_binary(value) and value != "" ->
        {:ok, value}

      {:ok, _} ->
        {:error, "field '#{key}' must be a non-empty string"}

      :error ->
        {:error, "missing required field: #{key}"}
    end
  end

  defp required_map(map, key) do
    case Map.fetch(map, key) do
      {:ok, value} when is_map(value) ->
        {:ok, value}

      {:ok, _} ->
        {:error, "field '#{key}' must be an object"}

      :error ->
        {:error, "missing required field: #{key}"}
    end
  end

  defp validate_digest(digest) do
    if String.starts_with?(digest, "sha256:") and String.length(digest) == 71 do
      :ok
    else
      {:error, "image_digest must be in format 'sha256:<64-hex-chars>'"}
    end
  end

  defp parse_limits(nil), do: nil

  defp parse_limits(limits) when is_map(limits) do
    limits
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
  end

  defp parse_docker_config(nil), do: nil

  defp parse_docker_config(config) when is_map(config) do
    config
    |> Map.new(fn {k, v} -> {String.to_atom(k), v} end)
  end
end
