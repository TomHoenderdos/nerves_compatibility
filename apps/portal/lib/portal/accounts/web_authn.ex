defmodule Portal.Accounts.WebAuthn do
  @moduledoc """
  WebAuthn configuration and challenge builder for Nerves Compatibility portal.

  Relying-party configuration (rp_id, origin) is explicit and never derived
  from the request. The host header is attacker-supplied, and the portal learns
  the scheme only from X-Forwarded-Proto behind Apache, so a derived origin
  fails closed the moment that header is misconfigured.

  The `wax_` library generates all challenge bytes; we never pass `bytes:` to
  avoid collision risks. User verification is required; attestation is none
  (BYOD passkey attestation, no verification). A 5-minute timeout helps users
  without local Bluetooth or NFC.
  """

  @spec opts(keyword()) :: keyword()
  def opts(extra \\ []) do
    config = Application.fetch_env!(:portal, __MODULE__)

    [
      rp_id: Keyword.fetch!(config, :rp_id),
      origin: Keyword.fetch!(config, :origin),
      user_verification: "required",
      attestation: "none",
      timeout: 300,
      allow_credentials: []
    ]
    |> Keyword.merge(extra)
  end
end
