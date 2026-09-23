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
  `sha256`. Bytes are copied to a private staging file, verified, then atomically
  published. Retries with an already moved source verify the stored blob.
  A digest mismatch returns `{:error, :checksum_mismatch}`.

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

      File.regular?(source_path) ->
        publish(sha256, source_path, dest)

      File.regular?(dest) ->
        with :ok <- verify_digest(dest, sha256) do
          {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}
        end

      true ->
        {:error, :source_missing}
    end
  end

  # Staging lives on the store filesystem, so publication is one atomic rename
  # even when worker scratch is on another device. Concurrent readers never see
  # a partial copy, and concurrent publishers can only publish verified bytes.
  # Both paths are constructed from the configured store and a validated digest;
  # source_path was checked by put_blob/2 after the worker container stopped.
  # sobelow_skip ["Traversal.FileModule"]
  defp publish(sha256, source_path, dest) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
    staged = Path.join(path(), ".#{sha256}-#{suffix}")

    try do
      with :ok <- File.cp(source_path, staged),
           :ok <- verify_digest(staged, sha256),
           :ok <- File.chmod(staged, 0o644),
           :ok <- File.rename(staged, dest) do
        _ = File.rm(source_path)
        {:ok, %{sha256: sha256, disk_path: dest, byte_size: file_size(dest)}}
      end
    after
      File.rm(staged)
    end
  end

  # Hash in bounded chunks: native artifacts need not fit in the portal heap.
  # Only store paths constructed in put_blob/2 and publish/3 reach this helper.
  # sobelow_skip ["Traversal.FileModule"]
  defp verify_digest(file, expected) do
    actual =
      file
      |> File.stream!(64 * 1024)
      |> Enum.reduce(:crypto.hash_init(:sha256), fn chunk, hash ->
        :crypto.hash_update(hash, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    if actual == expected, do: :ok, else: {:error, :checksum_mismatch}
  rescue
    error in File.Error -> {:error, error.reason}
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
