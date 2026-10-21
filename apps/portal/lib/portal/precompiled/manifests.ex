defmodule Portal.Precompiled.Manifests do
  @moduledoc """
  Manifests as bytes. A batch names the SHA-256 of each package's manifest,
  so the manifest a client receives must be the bytes that were hashed, not
  a fresh render. Rendered once per batch, stored in `Portal.ArtifactStore`
  by hash, served from there.
  """
  alias Portal.{ArtifactStore, Catalog}

  @spec render(String.t()) :: {:ok, binary()} | :none
  def render(package_name) do
    case Catalog.precompiled_manifest(package_name) do
      nil -> :none
      manifest -> {:ok, JSON.encode!(manifest)}
    end
  end

  @spec store(binary()) :: {:ok, String.t()} | {:error, term()}
  def store(bytes) do
    sha = Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

    if ArtifactStore.present?(sha) do
      {:ok, sha}
    else
      tmp = Path.join(System.tmp_dir!(), "manifest-#{sha}-#{System.unique_integer([:positive])}")
      File.write!(tmp, bytes)

      case ArtifactStore.put(sha, tmp) do
        {:ok, _} -> {:ok, sha}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec read(String.t()) :: {:ok, binary()} | :error
  def read(sha) do
    if ArtifactStore.present?(sha),
      do: File.read(ArtifactStore.blob_path(sha)) |> ok_or_error(),
      else: :error
  end

  defp ok_or_error({:ok, bin}), do: {:ok, bin}
  defp ok_or_error(_), do: :error
end
