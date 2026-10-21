defmodule Portal.Precompiled.Envelope do
  @moduledoc """
  Signed document envelope: `{"payload": base64url(bytes), "signatures":
  [{"keyid", "sig"}]}`, Ed25519 over the raw payload bytes. Nothing is
  canonicalised; the client decodes the payload only after `verify/3`.
  """

  @spec sign(binary(), [{String.t(), binary()}]) :: map()
  def sign(payload, signers) when is_binary(payload) do
    %{
      "payload" => Base.url_encode64(payload, padding: false),
      "signatures" =>
        for {keyid, private} <- signers do
          %{
            "keyid" => keyid,
            "sig" =>
              Base.url_encode64(:crypto.sign(:eddsa, :none, payload, [private, :ed25519]),
                padding: false
              )
          }
        end
    }
  end

  @spec verify(map() | binary(), %{String.t() => binary()}, pos_integer()) ::
          {:ok, binary()} | {:error, :bad_envelope | :below_threshold}
  def verify(envelope, keys, threshold) when is_binary(envelope) do
    case JSON.decode(envelope) do
      {:ok, map} when is_map(map) -> verify(map, keys, threshold)
      _ -> {:error, :bad_envelope}
    end
  end

  def verify(%{"payload" => p, "signatures" => sigs}, keys, threshold)
      when is_binary(p) and is_list(sigs) and is_integer(threshold) and threshold > 0 do
    with {:ok, payload} <- Base.url_decode64(p, padding: false) do
      valid =
        sigs
        |> Enum.filter(&valid_signature?(&1, payload, keys))
        |> Enum.map(& &1["keyid"])
        |> Enum.uniq()

      if length(valid) >= threshold, do: {:ok, payload}, else: {:error, :below_threshold}
    else
      _ -> {:error, :bad_envelope}
    end
  end

  def verify(_, _, _), do: {:error, :bad_envelope}

  defp valid_signature?(%{"keyid" => keyid, "sig" => sig}, payload, keys)
       when is_binary(keyid) and is_binary(sig) do
    with {:ok, public} <- Map.fetch(keys, keyid),
         {:ok, raw} <- Base.url_decode64(sig, padding: false),
         true <- byte_size(public) == 32,
         true <- byte_size(raw) == 64 do
      :crypto.verify(:eddsa, :none, payload, raw, [public, :ed25519])
    else
      _ -> false
    end
  end

  defp valid_signature?(_, _, _), do: false
end
