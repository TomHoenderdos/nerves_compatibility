defmodule Portal.Precompiled.Batches do
  @moduledoc """
  Builds and signs batch indexes. A batch names every package that has
  precompiled files and the SHA-256 of its manifest bytes; the client uses a
  manifest only if the newest valid batch names its hash.
  """
  require Ash.Query
  alias Portal.Catalog
  alias Portal.Precompiled.{Batch, Envelope, Keys, Manifests}

  @ttl_days 7

  @spec build_and_sign() :: {:ok, Batch.t()} | {:error, :no_signing_key | term()}
  def build_and_sign do
    case Keys.load() do
      {:ok, key} -> do_build(key)
      {:error, _} -> {:error, :no_signing_key}
    end
  end

  defp do_build(key) do
    manifests =
      Catalog.packages_with_precompiled_files()
      |> Enum.reduce(%{}, fn name, acc ->
        with {:ok, bytes} <- Manifests.render(name),
             {:ok, sha} <- Manifests.store(bytes) do
          Map.put(acc, name, sha)
        else
          _ -> acc
        end
      end)

    issued = DateTime.utc_now()
    expires = DateTime.add(issued, @ttl_days, :day)
    sequence = (latest() && latest().sequence + 1) || 1

    payload =
      JSON.encode!(%{
        "version" => 1,
        "sequence" => sequence,
        "issued" => DateTime.to_iso8601(issued),
        "expires" => DateTime.to_iso8601(expires),
        "manifests" => manifests
      })

    %{"signatures" => signatures} = Envelope.sign(payload, [{key.keyid, key.private}])

    Batch
    |> Ash.Changeset.for_create(:create, %{
      sequence: sequence,
      issued_at: issued,
      expires_at: expires,
      payload: payload,
      signatures: signatures,
      manifest_count: map_size(manifests)
    })
    |> Ash.create(domain: Portal.Precompiled)
  end

  @spec latest() :: Batch.t() | nil
  def latest do
    Batch
    |> Ash.Query.sort(sequence: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read!(domain: Portal.Precompiled)
    |> List.first()
  end

  @spec get(integer()) :: Batch.t() | nil
  def get(sequence) do
    Batch |> Ash.Query.filter(sequence == ^sequence) |> Ash.read_one!(domain: Portal.Precompiled)
  end

  @spec envelope(Batch.t()) :: binary()
  def envelope(%Batch{payload: payload, signatures: signatures}) do
    JSON.encode!(%{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" => signatures
    })
  end

  @spec manifests(Batch.t()) :: %{String.t() => String.t()}
  def manifests(%Batch{payload: payload}), do: JSON.decode!(payload)["manifests"]
end
