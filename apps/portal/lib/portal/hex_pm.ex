defmodule Portal.HexPm do
  @moduledoc """
  Hex.pm OAuth device flow and package ownership checks.
  """

  require Logger

  @client_id "78ea6566-89fd-481e-a1d6-7d9d78eacca8"
  @scope "api:read"
  @api_url "https://hex.pm/api"

  @doc """
  OAuth scope requested from Hex.pm.

  Read-only on purpose. The only authenticated call this module makes is
  `GET /api/users/me`; package and owner lookups are unauthenticated. Hex.pm
  expands the bare `api` scope into `api:read` + `api:write` on its consent
  screen, which shows a write permission we never use and requires the user to
  have 2FA enabled.
  """
  def scope, do: @scope

  def start_device_flow do
    body =
      URI.encode_query(%{client_id: @client_id, scope: scope(), name: "Nerves Compatibility"})

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

  def latest_version(package_name) when is_binary(package_name) do
    case Req.get("#{@api_url}/packages/#{package_name}") do
      {:ok, %{status: 200, body: package}} when is_map(package) ->
        package
        |> latest_version_from_package()
        |> case do
          version when is_binary(version) and version != "" -> {:ok, version}
          _ -> {:error, :unknown_package_version}
        end

      {:ok, %{status: 404}} ->
        {:error, :unknown_package}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex package metadata failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_api_unavailable}

      {:error, reason} ->
        Logger.warning("Hex package metadata failed: #{inspect(reason)}")
        {:error, :hex_api_unavailable}
    end
  end

  def latest_version(_package_name), do: {:error, :unknown_package}

  # A package's `meta.links` is a free-form map the package author writes in
  # their own mix.exs, and it arrives here as whatever they put there. Both
  # halves of that are load-bearing:
  #
  #   * the values become `href`s on a public page, so a `javascript:` or
  #     `data:` URL would be a stored XSS delivered through hex.pm
  #   * there is no size limit upstream, so the caps below are what stop one
  #     package from writing an unbounded blob into every row of our table
  @max_links 20
  @max_link_label 60
  @max_url_bytes 300
  @max_owners 25

  @doc """
  Public metadata for one package: its author-declared links and its owners.

  Only the pieces this site renders, and deliberately not everything hex.pm
  returns. `GET /api/packages/<name>` includes an `email` for every owner;
  those are dropped here, at the boundary, so no caller can persist or display
  one by accident. Only `username` leaves this function.

  Links are filtered to absolute `http`/`https` URLs -- see the comment above.
  """
  @spec package_metadata(String.t()) ::
          {:ok, %{links: %{String.t() => String.t()}, owners: [String.t()]}} | {:error, term()}
  def package_metadata(package_name) when is_binary(package_name) do
    case Req.get("#{@api_url}/packages/#{package_name}") do
      {:ok, %{status: 200, body: package}} when is_map(package) ->
        {:ok, metadata_from_body(package)}

      {:ok, %{status: 404}} ->
        {:error, :unknown_package}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("Hex package metadata failed: HTTP #{status} #{inspect(body)}")
        {:error, :hex_api_unavailable}

      {:error, reason} ->
        Logger.warning("Hex package metadata failed: #{inspect(reason)}")
        {:error, :hex_api_unavailable}
    end
  end

  def package_metadata(_package_name), do: {:error, :unknown_package}

  @doc """
  The metadata boundary itself, split out from the request so it can be tested
  without one. Takes a decoded `GET /api/packages/<name>` body.
  """
  @spec metadata_from_body(map()) :: %{links: %{String.t() => String.t()}, owners: [String.t()]}
  def metadata_from_body(package) when is_map(package) do
    %{
      links: sane_links(get_in(package, ["meta", "links"])),
      owners:
        package
        |> Map.get("owners")
        |> List.wrap()
        |> Enum.flat_map(&owner_username/1)
        |> Enum.uniq()
        |> Enum.take(@max_owners)
    }
  end

  def metadata_from_body(_package), do: %{links: %{}, owners: []}

  defp sane_links(links) when is_map(links) do
    links
    |> Enum.filter(fn {label, url} -> is_binary(label) and label != "" and http_url?(url) end)
    |> Enum.map(fn {label, url} -> {String.slice(label, 0, @max_link_label), url} end)
    |> Enum.sort()
    |> Enum.take(@max_links)
    |> Map.new()
  end

  defp sane_links(_), do: %{}

  defp http_url?(url) when is_binary(url) do
    byte_size(url) <= @max_url_bytes and
      case URI.new(url) do
        {:ok, %URI{scheme: scheme, host: host}} ->
          scheme in ["http", "https"] and is_binary(host) and host != ""

        _ ->
          false
      end
  end

  defp http_url?(_), do: false

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

  defp latest_version_from_package(package) do
    package["latest_version"] ||
      get_in(package, ["meta", "latest_version"]) ||
      package
      |> Map.get("releases", [])
      |> Enum.find_value(fn
        %{"version" => version} when is_binary(version) -> version
        _ -> nil
      end)
  end

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
end
