defmodule Compatibility.BuildCache.Install do
  @moduledoc """
  The last steps of fetching one L2 build cache object, shared by the portal's
  prefetch (`Portal.BuildCache.L2.Prefetch`) and a remote builder's
  (`NccAgent.BuildCache`): check the downloaded tarball's SHA-256, extract it
  with `Compatibility.BuildCache.Tarball.unpack/3` into a staging dir beside
  the entry, and publish that dir by rename unless the entry arrived
  meanwhile.

  How the tarball is fetched, and from where, is each caller's own. The
  caller builds every path: `dest` is `<slug dir>/<64-hex key>` with the key
  validated (`Compatibility.BuildCache.key?/1`), `staging` and `tar` fresh
  names beside it.
  """

  alias Compatibility.BuildCache.Tarball

  @doc """
  `:ok` when `computed` (the SHA-256 of what arrived) equals `expected`, the
  uploader's `x-amz-meta-sha256` or the portal's listing of it. A missing
  expected value is a refusal, as a mismatch is.
  """
  @spec verify_sha(String.t(), String.t() | nil) ::
          :ok | {:error, :no_sha256_header | {:sha256_mismatch, String.t(), String.t()}}
  def verify_sha(_computed, nil), do: {:error, :no_sha256_header}

  def verify_sha(computed, expected) when is_binary(expected) do
    if computed == String.downcase(expected),
      do: :ok,
      else: {:error, {:sha256_mismatch, computed, expected}}
  end

  @doc """
  Extracts `tar` into `staging` (created here, so it must not exist) and
  renames it to `dest`: `{:ok, extracted}` when published, `{:discarded,
  extracted}` when `dest` existed by then, `{:error, reason}` otherwise. The
  tarball is removed once extracted. The caller removes `staging` and `tar`
  whatever happened.

  Options: `:timeout_ms`, `:max_extracted_bytes`, `:max_heap_bytes` (passed
  to `Tarball.unpack/3`) and `:before_publish`, a `fn staging -> :ok |
  {:error, reason}` run on the extracted tree before the rename (the agent
  hands it to the build user there).
  """
  @spec install(Path.t(), Path.t(), Path.t(), keyword()) ::
          {:ok, non_neg_integer()} | {:discarded, non_neg_integer()} | {:error, term()}
  # `tar`, `staging` and `dest` are caller-built names under its own cache root.
  # sobelow_skip ["Traversal.FileModule"]
  def install(tar, staging, dest, opts \\ []) do
    before_publish = Keyword.get(opts, :before_publish, fn _staging -> :ok end)
    unpack_opts = Keyword.take(opts, [:timeout_ms, :max_extracted_bytes, :max_heap_bytes])

    with :ok <- File.mkdir(staging),
         {:ok, %{extracted_bytes: extracted}} <- Tarball.unpack(tar, staging, unpack_opts),
         :ok <- before_publish.(staging) do
      _ = File.rm(tar)

      case publish(staging, dest) do
        :ok -> {:ok, extracted}
        :discarded -> {:discarded, extracted}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # An entry that exists by now (a local promotion, another fetch of the same
  # key) wins; rename(2) refuses a non-empty directory, which closes the
  # window between the lstat and the rename.
  # sobelow_skip ["Traversal.FileModule"]
  defp publish(staging, dest) do
    case File.lstat(dest) do
      {:ok, _} -> :discarded
      {:error, :enoent} -> rename(staging, dest)
      {:error, reason} -> {:error, {:lstat, reason}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp rename(staging, dest) do
    case File.rename(staging, dest) do
      :ok -> :ok
      {:error, reason} when reason in [:eexist, :enotempty] -> :discarded
      {:error, reason} -> {:error, {:rename, reason}}
    end
  end
end
