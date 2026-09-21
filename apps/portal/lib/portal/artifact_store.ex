defmodule Portal.ArtifactStore do
  @moduledoc """
  Content-addressed blob store on disk. Blobs are named by their SHA256 hash;
  the database (`Portal.Catalog.Artifact`) holds only metadata pointing here.

  Serving blobs over HTTP is Phase 5 — this module only stores them.
  """

  @doc "Configured root directory for the blob store."
  @spec path() :: Path.t()
  def path do
    :portal
    |> Application.get_env(:artifact_store, [])
    |> Keyword.get(:path, Path.expand("~/.ncc-artifacts"))
  end

  @doc "Absolute on-disk path for a given sha256 (does not check existence)."
  @spec blob_path(String.t()) :: Path.t()
  def blob_path(sha256) do
    if valid_sha256?(sha256),
      do: Path.join(path(), sha256),
      else: raise(ArgumentError, "invalid sha256")
  end

  @doc "Whether a blob name is a lowercase SHA256 digest, with no path components."
  def valid_sha256?(sha256) when is_binary(sha256), do: Regex.match?(~r/\A[0-9a-f]{64}\z/, sha256)
  def valid_sha256?(_), do: false

  @doc """
  Move a content-addressed file from `source_path` into the store under
  `sha256`. Idempotent: if the blob already exists, the source is removed and
  the existing blob is kept (content-addressed, so identical by definition).

  Returns `{:ok, %{sha256:, disk_path:, byte_size:}}` or `{:error, reason}`.
  """
  @spec put(String.t(), Path.t()) ::
          {:ok, %{sha256: String.t(), disk_path: Path.t(), byte_size: non_neg_integer()}}
          | {:error, term()}
  def put(sha256, source_path) do
    if valid_sha256?(sha256), do: put_blob(sha256, source_path), else: {:error, :invalid_sha256}
  end

  # The digest is validated in put/2; source_path comes from the runner's files
  # directory. Refuse symlinks before moving any worker-produced file to the host.
  # sobelow_skip ["Traversal.FileModule"]
  defp put_blob(sha256, source_path) do
    File.mkdir_p!(path())
    dest = blob_path(sha256)

    cond do
      symlink?(dest) or symlink?(source_path) ->
        {:error, :invalid_source}

      File.regular?(dest) ->
        _ = File.rm(source_path)
        {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}

      File.regular?(source_path) ->
        case File.rename(source_path, dest) do
          :ok ->
            _ = File.chmod(dest, 0o644)
            {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}

          {:error, :exdev} ->
            # Cross-device: fall back to copy + delete.
            File.cp!(source_path, dest)
            _ = File.chmod(dest, 0o644)
            _ = File.rm(source_path)
            {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}

          {:error, reason} ->
            {:error, reason}
        end

      true ->
        {:error, :source_missing}
    end
  end

  defp symlink?(path) do
    match?({:ok, %File.Stat{type: :symlink}}, File.lstat(path))
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
