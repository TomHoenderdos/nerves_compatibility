defmodule PortalWeb.SecurityHTML do
  @moduledoc """
  Templates for the security settings page.
  """

  use PortalWeb, :html

  embed_templates("security_html/*")

  @doc """
  The enrolment URI as an inline SVG QR code.

  Rendered server-side and inlined rather than served as an image: the
  `otpauth://` URI carries a live TOTP seed, and a separate `<img src>` would
  put it in a second request with its own URL, its own logs and its own cache
  entry. Inline, it reaches exactly the one response it belongs to.

  `raw/1` is safe here because nothing from the URI survives into the output.
  `EQRCode.svg/2` emits a fixed grid of `<rect>` elements derived from the
  encoded bit matrix; the input string itself is never interpolated.

  The leading `<?xml ...?>` declaration is stripped. It is correct for a
  standalone SVG document and a bogus comment inside an HTML body.
  """
  @spec totp_qr(String.t()) :: Phoenix.HTML.safe()
  def totp_qr(uri) when is_binary(uri) do
    uri
    |> EQRCode.encode()
    |> EQRCode.svg(width: 200, background_color: "#FFF", color: "#000", class: "h-48 w-48")
    |> String.replace(~r/\A<\?xml[^>]*\?>\s*/, "")
    |> raw()
  end

  @doc """
  The bare base32 secret, in groups of four.

  This, not the `otpauth://` URI, is what an authenticator's manual-entry
  field accepts -- the URI buries the secret in a query parameter. Manual
  entry is the only route for anyone who cannot scan, which is the same
  population TOTP exists to serve.
  """
  @spec totp_manual_key(binary()) :: String.t()
  def totp_manual_key(secret) when is_binary(secret) do
    secret
    |> Base.encode32(padding: false)
    |> String.to_charlist()
    |> Enum.chunk_every(4)
    |> Enum.map_join(" ", &List.to_string/1)
  end
end
