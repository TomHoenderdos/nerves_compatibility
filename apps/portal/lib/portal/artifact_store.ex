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
  def blob_path(sha256), do: Path.join(path(), sha256)

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
    File.mkdir_p!(path())
    dest = blob_path(sha256)

    cond do
      File.exists?(dest) ->
        _ = File.rm(source_path)
        {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}

      File.exists?(source_path) ->
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

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end
end
