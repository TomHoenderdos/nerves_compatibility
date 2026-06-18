defmodule Orchestrator.ScanRequestRouter do
  @moduledoc """
  Minimal HTTP API for externally submitted package scan requests.
  """

  use Plug.Router

  plug(:match)
  plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
  plug(:dispatch)

  get "/health" do
    send_json(conn, 200, %{ok: true})
  end

  post "/auth/hex/start" do
    with :ok <- authorize(conn),
         {:ok, flow} <- Orchestrator.HexAuth.start_device_flow() do
      send_json(conn, 200, flow)
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{message: "Unauthorized."})
      {:error, reason} -> send_json(conn, 400, %{message: error_message(reason), reason: reason})
    end
  end

  post "/auth/hex/complete" do
    params = conn.body_params
    package = params["package"] || params[:package]
    device_code = params["device_code"] || params[:device_code]

    with :ok <- authorize(conn),
         {:ok, token} <- Orchestrator.HexAuth.poll_device_flow(device_code),
         access_token when is_binary(access_token) <- token["access_token"],
         {:ok, username} <- Orchestrator.HexAuth.verify_package_owner(access_token, package),
         {:ok, request} <-
           Orchestrator.ScanRequest.submit(%{
             package: package,
             source: :hex_owner,
             verified?: true,
             subject: username
           }) do
      send_json(conn, 202, request)
    else
      {:pending, reason} -> send_json(conn, 202, %{status: "pending", reason: reason})
      nil -> send_json(conn, 400, %{message: "Hex token response did not include an access token."})
      {:error, :unauthorized} -> send_json(conn, 401, %{message: "Unauthorized."})
      {:error, reason} -> send_json(conn, 400, %{message: error_message(reason), reason: reason})
    end
  end

  post "/scan-requests" do
    with :ok <- authorize(conn),
         {:ok, request} <- Orchestrator.ScanRequest.submit(conn.body_params) do
      send_json(conn, 202, request)
    else
      {:error, :unauthorized} -> send_json(conn, 401, %{message: "Unauthorized."})
      {:error, reason} -> send_json(conn, 400, %{message: error_message(reason), reason: reason})
    end
  end

  match _ do
    send_json(conn, 404, %{message: "Not found."})
  end

  defp authorize(conn) do
    secret = Application.get_env(:orchestrator, :scan_request_shared_secret)
    expected = "Bearer #{secret}"

    cond do
      not is_binary(secret) or secret == "" ->
        {:error, :unauthorized}

      Plug.Conn.get_req_header(conn, "authorization") == [expected] ->
        :ok

      true ->
        {:error, :unauthorized}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp error_message(:missing_package), do: "Package name is required."
  defp error_message(:invalid_package), do: "Enter a valid Hex package name."
  defp error_message(:unknown_package), do: "Package was not found on Hex.pm."
  defp error_message(:hex_unavailable), do: "Hex.pm is unavailable."
  defp error_message(:invalid_source), do: "Request source is invalid."
  defp error_message(:not_verified), do: "Verified requests require a verified identity."
  defp error_message(:human_check_required), do: "Anonymous requests require a human check."
  defp error_message(:hex_oauth_unavailable), do: "Hex.pm login is unavailable."
  defp error_message(:invalid_token), do: "Hex.pm login token is invalid."
  defp error_message(:not_package_owner), do: "The logged-in Hex.pm user is not an owner of this package."
  defp error_message(:expired_token), do: "Hex.pm login expired. Start again."
  defp error_message(:access_denied), do: "Hex.pm login was denied."
  defp error_message(:hex_api_unavailable), do: "Hex.pm API is unavailable."
  defp error_message(_), do: "The scan request could not be accepted."
end
