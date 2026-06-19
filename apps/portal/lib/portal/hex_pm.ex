defmodule Portal.HexPm do
  @moduledoc """
  Hex.pm OAuth device flow and package ownership checks.
  """

  require Logger

  @client_id "78ea6566-89fd-481e-a1d6-7d9d78eacca8"
  @scope "api"
  @api_url "https://hex.pm/api"

  def start_device_flow do
    body = URI.encode_query(%{client_id: @client_id, scope: @scope, name: "Nerves Compatibility"})

    case post_form("#{@api_url}/oauth/device_authorization", body) do
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
        Logger.warning("Hex OAuth start failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_oauth_unavailable}

      {:error, reason} ->
        Logger.warning("Hex OAuth start failed: #{inspect(reason)}")
        {:error, :hex_oauth_unavailable}
    end
  end

  def complete_owner_request(package_name, device_code) do
    case complete_owner_requests([package_name], device_code) do
      {:ok, [request]} -> {:ok, request}
      {:ok, []} -> {:error, :missing_package}
      other -> other
    end
  end

  def complete_owner_requests(package_names, device_code) when is_list(package_names) do
    package_names = package_names |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, token} <- poll_device_flow(device_code),
         access_token when is_binary(access_token) <- token["access_token"],
         {:ok, %{"username" => username} = hex_profile} <- current_user(access_token),
         {:ok, user} <- upsert_hex_user(hex_profile),
         {:ok, requests} <- create_owner_requests(package_names, username, user) do
      Enum.each(requests, &forward_to_orchestrator/1)
      {:ok, requests}
    else
      {:pending, reason} -> {:pending, reason}
      nil -> {:error, :missing_access_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def search_packages(query) when is_binary(query) do
    query = String.trim(query)

    if String.length(query) < 2 do
      {:ok, []}
    else
      case Req.get("#{@api_url}/packages", params: [search: query]) do
        {:ok, %{status: 200, body: packages}} when is_list(packages) ->
          packages =
            packages
            |> Enum.flat_map(&package_search_result/1)
            |> Enum.take(8)

          {:ok, packages}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("Hex package search failed: HTTP #{status} #{inspect(body)}")
          {:error, :hex_api_unavailable}

        {:error, reason} ->
          Logger.warning("Hex package search failed: #{inspect(reason)}")
          {:error, :hex_api_unavailable}
      end
    end
  end

  def search_packages(_query), do: {:ok, []}

  defp poll_device_flow(device_code) when is_binary(device_code) do
    body =
      URI.encode_query(%{
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        client_id: @client_id,
        device_code: device_code
      })

    case post_form("#{@api_url}/oauth/token", body) do
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

  defp current_user(access_token) do
    case Req.get("#{@api_url}/users/me", headers: [{"authorization", "Bearer #{access_token}"}]) do
      {:ok, %{status: 200, body: %{"username" => username} = body}} when is_binary(username) ->
        {:ok, body}

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

  defp package_owners(package_name) do
    case Req.get("#{@api_url}/packages/#{package_name}/owners") do
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

  defp package_search_result(%{"name" => name} = package) when is_binary(name) do
    [
      %{
        name: name,
        description: get_in(package, ["meta", "description"]) || "",
        url: package["html_url"] || "https://hex.pm/packages/#{name}"
      }
    ]
  end

  defp package_search_result(_), do: []

  defp post_form(url, body) do
    Req.post(url,
      headers: [
        {"content-type", "application/x-www-form-urlencoded"},
        {"accept", "application/json"}
      ],
      body: body
    )
  end

  defp upsert_hex_user(%{"username" => username} = hex_profile) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_hex_user(username) do
      {:ok, nil} ->
        Portal.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          username: username,
          hex_username: username,
          hex_profile: encode_profile(hex_profile),
          password_hash: hash_generated_password(),
          last_hex_login_at: now
        })
        |> Ash.create(domain: Portal.Accounts)

      {:ok, user} ->
        user
        |> Ash.Changeset.for_update(:record_hex_login, %{
          hex_username: username,
          hex_profile: encode_profile(hex_profile),
          last_hex_login_at: now
        })
        |> Ash.update(domain: Portal.Accounts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_user_by_hex_username(username) do
    with {:ok, users} <- Ash.read(Portal.Accounts.User, domain: Portal.Accounts) do
      {:ok, Enum.find(users, &(&1.hex_username == username))}
    end
  end

  defp get_hex_user(username) do
    case get_user_by_hex_username(username) do
      {:ok, nil} -> Portal.Accounts.get_user_by_username(username)
      result -> result
    end
  end

  defp hash_generated_password do
    32
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> Argon2.hash_pwd_salt()
  end

  defp encode_profile(profile) do
    Jason.encode!(profile)
  end

  defp create_owner_requests(package_names, username, user) do
    package_names
    |> Enum.reduce_while({:ok, []}, fn package_name, {:ok, requests} ->
      with {:ok, owners} <- package_owners(package_name),
           true <- username in owners,
           {:ok, request} <- create_scan_request(package_name, user) do
        {:cont, {:ok, [request | requests]}}
      else
        false -> {:halt, {:error, {:not_package_owner, package_name}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requests} -> {:ok, Enum.reverse(requests)}
      error -> error
    end
  end

  defp create_scan_request(package_name, user) do
    %{
      package_name: package_name,
      source: :hex_owner,
      status: :accepted,
      user_id: user.id,
      subject: user.hex_username,
      verification_provider: "hex_pm_oauth_device"
    }
    |> Portal.ScanRequests.create_once()
  end

  defp forward_to_orchestrator(request) do
    url = Application.get_env(:portal, :orchestrator_scan_request_url)
    secret = Application.get_env(:portal, :scan_request_shared_secret)

    if is_binary(url) and url != "" and is_binary(secret) and secret != "" do
      Req.post(url,
        headers: [
          {"content-type", "application/json"},
          {"authorization", "Bearer #{secret}"}
        ],
        json: %{
          package: request.package_name,
          source: "hex_owner",
          verified: true,
          subject: request.subject
        }
      )
    end
  end
end
