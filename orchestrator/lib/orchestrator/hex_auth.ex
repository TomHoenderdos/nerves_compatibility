defmodule Orchestrator.HexAuth do
  @moduledoc """
  Hex.pm OAuth device login and package ownership verification.
  """

  require Logger

  @client_id "78ea6566-89fd-481e-a1d6-7d9d78eacca8"
  @scope "api"
  @api_url "https://hex.pm/api"

  @doc """
  Starts a Hex.pm OAuth device authorization flow.
  """
  @spec start_device_flow() :: {:ok, map()} | {:error, atom() | term()}
  def start_device_flow() do
    body = URI.encode_query(%{client_id: @client_id, scope: @scope, name: "Nerves Compatibility"})

    case Req.post("#{@api_url}/oauth/device_authorization",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok,
         %{
           device_code: body["device_code"],
           user_code: body["user_code"],
           verification_uri: body["verification_uri"],
           verification_uri_complete: body["verification_uri_complete"],
           expires_in: body["expires_in"],
           interval: body["interval"] || 5
         }}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex OAuth device start failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_oauth_unavailable}

      {:error, reason} ->
        Logger.warning("Hex OAuth device start failed: #{inspect(reason)}")
        {:error, :hex_oauth_unavailable}
    end
  end

  @doc """
  Polls Hex.pm for OAuth completion.
  """
  @spec poll_device_flow(String.t()) ::
          {:ok, map()} | {:pending, atom()} | {:error, atom() | term()}
  def poll_device_flow(device_code) when is_binary(device_code) do
    body =
      URI.encode_query(%{
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: @client_id,
        device_code: device_code
      })

    case Req.post("#{@api_url}/oauth/token",
           headers: [{"content-type", "application/x-www-form-urlencoded"}],
           body: body
         ) do
      {:ok, %{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %{status: 400, body: %{"error" => error}}}
      when error in ["authorization_pending", "slow_down"] ->
        {:pending, String.to_atom(error)}

      {:ok, %{status: 400, body: %{"error" => "expired_token"}}} ->
        {:error, :expired_token}

      {:ok, %{status: 403, body: %{"error" => "access_denied"}}} ->
        {:error, :access_denied}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex OAuth poll failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_oauth_unavailable}

      {:error, reason} ->
        Logger.warning("Hex OAuth poll failed: #{inspect(reason)}")
        {:error, :hex_oauth_unavailable}
    end
  end

  @doc """
  Verifies that an OAuth token belongs to an owner of `package`.
  """
  @spec verify_package_owner(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, atom() | term()}
  def verify_package_owner(access_token, package) when is_binary(access_token) and is_binary(package) do
    with {:ok, username} <- current_username(access_token),
         {:ok, owners} <- package_owners(package),
         true <- username in owners do
      {:ok, username}
    else
      false -> {:error, :not_package_owner}
      {:error, reason} -> {:error, reason}
    end
  end

  defp current_username(access_token) do
    case Req.get("#{@api_url}/users/me", headers: auth_headers(access_token)) do
      {:ok, %{status: 200, body: %{"username" => username}}} when is_binary(username) ->
        {:ok, username}

      {:ok, %{status: 401}} ->
        {:error, :invalid_token}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex users/me failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_api_unavailable}

      {:error, reason} ->
        Logger.warning("Hex users/me failed: #{inspect(reason)}")
        {:error, :hex_api_unavailable}
    end
  end

  defp package_owners(package) do
    case Req.get("#{@api_url}/packages/#{package}/owners") do
      {:ok, %{status: 200, body: owners}} when is_list(owners) ->
        {:ok, Enum.flat_map(owners, &owner_username/1)}

      {:ok, %{status: 404}} ->
        {:error, :unknown_package}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex package owners failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_api_unavailable}

      {:error, reason} ->
        Logger.warning("Hex package owners failed: #{inspect(reason)}")
        {:error, :hex_api_unavailable}
    end
  end

  defp owner_username(%{"username" => username}) when is_binary(username), do: [username]
  defp owner_username(_), do: []

  defp auth_headers(access_token), do: [{"authorization", "Bearer #{access_token}"}]
end
