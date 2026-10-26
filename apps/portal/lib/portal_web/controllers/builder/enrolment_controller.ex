defmodule PortalWeb.Builder.EnrolmentController do
  @moduledoc """
  Builder enrolment on `PortalWeb.BuilderEndpoint`: the CA certificate and
  the token-for-certificate exchange (both open, enrolment rate limited per
  address), renewal and the status heartbeat (both behind
  `PortalWeb.Plugs.BuilderCert`).
  """
  use PortalWeb, :controller

  alias Portal.Builders
  alias Portal.Builders.{CA, RateLimit}

  @enrol_per_minute 10
  # One fetch per agent boot; the limit only keeps an open route from
  # being a free file server.
  @ca_per_minute 30

  def ca(conn, _params) do
    cond do
      not RateLimit.allow?({:ca, conn.remote_ip}, @ca_per_minute, :timer.minutes(1)) ->
        error(conn, 429, "rate_limited")

      true ->
        case CA.cert_pem() do
          {:ok, pem} ->
            conn |> put_resp_content_type("application/x-pem-file") |> send_resp(200, pem)

          {:error, _} ->
            error(conn, 503, "no_ca")
        end
    end
  end

  def enroll(conn, %{"token" => token, "csr_pem" => csr} = params)
      when is_binary(token) and is_binary(csr) do
    if RateLimit.allow?({:enrol, conn.remote_ip}, @enrol_per_minute, :timer.minutes(1)) do
      attrs = %{agent_version: string(params["agent_version"]), slots: slots(params["slots"])}

      case Builders.enrol(token, csr, attrs) do
        {:ok, %{builder: builder, cert_pem: pem, expires_at: expires}} ->
          conn
          |> put_status(201)
          |> json(%{
            certificate_pem: pem,
            builder_id: builder.id,
            name: builder.name,
            expires_at: DateTime.to_iso8601(expires)
          })

        {:error, reason} ->
          {status, code} = enrol_error(reason)
          error(conn, status, code)
      end
    else
      error(conn, 429, "rate_limited")
    end
  end

  def enroll(conn, _params), do: error(conn, 400, "bad_request")

  defp enrol_error(reason) when reason in [:invalid_token, :token_used, :token_expired],
    do: {401, reason}

  defp enrol_error(:invalid_csr), do: {422, "invalid_csr"}
  # The token's name is checked when it is created, so this means a name the
  # CA has since stopped accepting.
  defp enrol_error(:invalid_name), do: {422, "invalid_name"}
  defp enrol_error(:name_taken), do: {409, "name_taken"}
  defp enrol_error(:no_ca), do: {503, "no_ca"}
  defp enrol_error(_), do: {500, "enrolment_failed"}

  def renew(conn, %{"csr_pem" => csr}) when is_binary(csr) do
    case Builders.renew(conn.assigns.builder, csr) do
      {:ok, %{cert_pem: pem, expires_at: expires}} ->
        json(conn, %{certificate_pem: pem, expires_at: DateTime.to_iso8601(expires)})

      {:error, :too_early} ->
        error(conn, 425, "too_early")

      {:error, :revoked} ->
        error(conn, 403, "revoked")

      {:error, :invalid_csr} ->
        error(conn, 422, "invalid_csr")

      {:error, :no_ca} ->
        error(conn, 503, "no_ca")

      {:error, _} ->
        error(conn, 500, "renewal_failed")
    end
  end

  def renew(conn, _params), do: error(conn, 400, "bad_request")

  def status(conn, params) do
    egress = if params["egress"] in ["ok", "missing"], do: params["egress"], else: "unknown"

    # The plug records the header's version; a body-only agent version counts too.
    builder =
      case string(params["agent_version"]) do
        nil -> conn.assigns.builder
        version -> Builders.touch(conn.assigns.builder, version)
      end

    case Builders.set_egress(builder, egress) do
      {:ok, _} -> json(conn, %{ok: true})
      {:error, _} -> error(conn, 500, "status_failed")
    end
  end

  defp slots(n) when is_integer(n) and n in 1..16, do: n

  defp slots(n) when is_binary(n) do
    case Integer.parse(n) do
      {i, ""} when i in 1..16 -> i
      _ -> nil
    end
  end

  defp slots(_), do: nil

  defp string(v) when is_binary(v), do: String.slice(v, 0, 64)
  defp string(_), do: nil

  defp error(conn, status, reason),
    do: conn |> put_status(status) |> json(%{error: to_string(reason)})
end
