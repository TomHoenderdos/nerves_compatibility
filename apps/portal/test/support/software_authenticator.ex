defmodule Portal.Test.SoftwareAuthenticator do
  @moduledoc """
  A minimal WebAuthn authenticator, for tests.

  Produces the byte structures a real authenticator returns, so `wax_` does
  genuine verification against it: CBOR attestation objects, raw authenticator
  data, and DER-encoded ECDSA P-256 signatures over
  `authData || SHA256(clientDataJSON)`.

  Everything is ES256 (COSE alg -7) with "none" attestation, which is what the
  portal asks browsers for.
  """

  import Bitwise

  defstruct [:credential_id, :private_key, :rp_id, sign_count: 0]

  @type t :: %__MODULE__{}

  # Flags byte, per the WebAuthn spec.
  @up 0x01
  @uv 0x04
  @at 0x40

  # No attestation means no meaningful AAGUID.
  @aaguid <<0::128>>

  @spec new(String.t(), keyword()) :: t()
  def new(rp_id, opts \\ []) do
    %__MODULE__{
      rp_id: rp_id,
      credential_id: Keyword.get(opts, :credential_id, :crypto.strong_rand_bytes(32)),
      private_key: :public_key.generate_key({:namedCurve, :secp256r1}),
      sign_count: Keyword.get(opts, :sign_count, 0)
    }
  end

  @doc """
  What `navigator.credentials.create` would hand back.
  """
  def create(%__MODULE__{} = auth, challenge_bytes, origin) do
    client_data_json = client_data("webauthn.create", challenge_bytes, origin)

    attestation_object =
      CBOR.encode(%{
        "fmt" => "none",
        "attStmt" => %{},
        "authData" => %CBOR.Tag{tag: :bytes, value: authenticator_data(auth, @up ||| @uv ||| @at)}
      })

    %{
      attestation_object: attestation_object,
      client_data_json: client_data_json,
      credential_id: auth.credential_id
    }
  end

  @doc """
  What `navigator.credentials.get` would hand back.

  `:sign_count` overrides the counter for this one assertion, which is how the
  sign-count tests produce a regression.
  """
  def get(%__MODULE__{} = auth, challenge_bytes, origin, opts \\ []) do
    auth = %{auth | sign_count: Keyword.get(opts, :sign_count, auth.sign_count)}

    client_data_json = client_data("webauthn.get", challenge_bytes, origin)
    auth_data = authenticator_data(auth, @up ||| @uv)

    signature =
      :public_key.sign(
        auth_data <> :crypto.hash(:sha256, client_data_json),
        :sha256,
        auth.private_key
      )

    %{
      credential_id: auth.credential_id,
      authenticator_data: auth_data,
      signature: signature,
      client_data_json: client_data_json
    }
  end

  defp client_data(type, challenge_bytes, origin) do
    Jason.encode!(%{
      "type" => type,
      "challenge" => Base.url_encode64(challenge_bytes, padding: false),
      "origin" => origin,
      "crossOrigin" => false
    })
  end

  # rpIdHash(32) || flags(1) || signCount(4, big endian) [|| attested credential data]
  defp authenticator_data(%__MODULE__{} = auth, flags) do
    head =
      :crypto.hash(:sha256, auth.rp_id) <>
        <<flags::unsigned-8, auth.sign_count::unsigned-big-32>>

    if (flags &&& @at) == 0 do
      head
    else
      head <>
        @aaguid <>
        <<byte_size(auth.credential_id)::unsigned-big-16>> <>
        auth.credential_id <>
        cose_key(auth)
    end
  end

  # COSE_Key for an EC2 P-256 public key:
  #   1 (kty) => 2 (EC2), 3 (alg) => -7 (ES256), -1 (crv) => 1 (P-256),
  #   -2 => x, -3 => y
  defp cose_key(%__MODULE__{private_key: key}) do
    # An OTP ECPrivateKey record: {:ECPrivateKey, version, privateKey,
    # parameters, publicKey, attributes}. The public key is an uncompressed
    # point, 0x04 followed by the two 32-byte coordinates.
    <<4, x::binary-size(32), y::binary-size(32)>> = elem(key, 4)

    CBOR.encode(%{
      1 => 2,
      3 => -7,
      -1 => 1,
      -2 => %CBOR.Tag{tag: :bytes, value: x},
      -3 => %CBOR.Tag{tag: :bytes, value: y}
    })
  end
end
