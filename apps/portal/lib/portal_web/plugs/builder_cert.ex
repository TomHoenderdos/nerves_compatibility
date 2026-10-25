defmodule PortalWeb.Plugs.BuilderCert do
  @moduledoc """
  Turns the peer certificate into `conn.assigns.builder`, or refuses the
  request: 401 without a certificate, 403 for one no builder holds or one
  whose builder is revoked. The TLS handshake has already checked the chain
  against the CA; this checks the certificate is one the portal still
  honours.
  """
  import Plug.Conn
  alias Portal.Builders
  alias Portal.Builders.CA

  def init(opts), do: opts

  def call(conn, _opts) do
    case get_peer_data(conn) do
      %{ssl_cert: der} when is_binary(der) ->
        case Builders.by_fingerprint(CA.fingerprint_der(der)) do
          {:ok, builder} ->
            version = conn |> get_req_header("x-ncc-agent-version") |> List.first()
            assign(conn, :builder, Builders.touch(builder, version))

          {:error, :revoked} ->
            refuse(conn, 403, "builder_revoked")

          {:error, :unknown} ->
            refuse(conn, 403, "unknown_builder")
        end

      _ ->
        refuse(conn, 401, "client_certificate_required")
    end
  end

  defp refuse(conn, status, error) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: error}))
    |> halt()
  end
end
