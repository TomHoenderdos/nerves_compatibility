defmodule Portal.Precompiled.Batches do
  @moduledoc """
  Builds and signs batch indexes. A batch names every package that has
  precompiled files and the SHA-256 of its manifest bytes; the client uses a
  manifest only if the newest valid batch names its hash.
  """
  require Ash.Query
  require Logger
  alias Portal.Catalog
  alias Portal.Precompiled.{Batch, Envelope, Keys, Manifests}

  @ttl_days 7

  @spec build_and_sign() ::
          {:ok, Batch.t()} | {:error, :no_signing_key | :signing_key_unreadable | term()}
  def build_and_sign do
    case Keys.load() do
      {:ok, key} ->
        do_build(key)

      {:error, :no_key} ->
        {:error, :no_signing_key}

      {:error, :unreadable} ->
        Logger.error(
          "Precompiled signing key at #{inspect(Keys.key_path())} is configured but unreadable"
        )

        {:error, :signing_key_unreadable}
    end
  end

  defp do_build(key) do
    {manifests, manifests_v2} =
      Catalog.packages_with_precompiled_files()
      |> Enum.reduce({%{}, %{}}, fn name, acc -> add_package(acc, name) end)

    issued = DateTime.utc_now()
    expires = DateTime.add(issued, @ttl_days, :day)
    # No locking: this runs from one Oban cron job with a uniqueness
    # constraint (Task 7), so concurrent calls do not occur in production,
    # and `unique_sequence` turns any race into an error, not duplicate data.
    sequence =
      case latest() do
        nil -> 1
        batch -> batch.sequence + 1
      end

    payload =
      JSON.encode!(%{
        "version" => 1,
        "sequence" => sequence,
        "issued" => DateTime.to_iso8601(issued),
        "expires" => DateTime.to_iso8601(expires),
        "manifests" => manifests,
        "manifests_v2" => manifests_v2
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

  # Both formats of one package from one catalog load. A package can have one
  # format and not the other (a run without toolchain keys is format 1 only, a
  # toolchain build format 2 only), so only a package with neither, or a
  # manifest that fails to store, is worth a warning.
  defp add_package({v1_acc, v2_acc}, name) do
    case Manifests.render_both(name) do
      %{v1: :none, v2: :none} ->
        Logger.warning("Dropping #{name} from precompiled batch: :none")
        {v1_acc, v2_acc}

      %{v1: v1, v2: v2} ->
        {store_into(v1_acc, name, v1, "format 1"), store_into(v2_acc, name, v2, "format 2")}
    end
  end

  defp store_into(acc, _name, :none, _format), do: acc

  defp store_into(acc, name, {:ok, bytes}, format) do
    case Manifests.store(bytes) do
      {:ok, sha} ->
        Map.put(acc, name, sha)

      reason ->
        Logger.warning("Dropping #{name} (#{format}) from precompiled batch: #{inspect(reason)}")
        acc
    end
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

  @doc "Format-2 manifest shas of a batch; `%{}` for a batch made before format 2."
  @spec manifests_v2(Batch.t()) :: %{String.t() => String.t()}
  def manifests_v2(%Batch{payload: payload}), do: JSON.decode!(payload)["manifests_v2"] || %{}
end
