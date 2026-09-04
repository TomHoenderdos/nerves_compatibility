defmodule Portal.GitHub do
  @moduledoc """
  GitHub OAuth device flow and repository permission checks.
  """

  require Logger

  @github_url "https://github.com"
  @api_url "https://api.github.com"
  # No OAuth scope is requested. GitHub grants unscoped tokens read-only access
  # to public information, which covers both authenticated calls this module
  # makes: `GET /user` (we read only `login`) and `GET /repos/:owner/:repo` (we
  # read only the `permissions` block describing the caller's own access).
  # Verified against a zero-scope token: both return exactly what we need.
  #
  # The previous `read:user public_repo` grant is deliberately gone.
  # `public_repo` is read *and write* to every public repository the maintainer
  # can touch — an unreasonable ask for a flow that only ever reads.
  @scope ""
  @writable_permissions ~w(admin maintain push)

  def start_device_flow do
    with {:ok, client_id} <- client_id() do
      body = URI.encode_query(device_flow_params(client_id))

      case post_form("#{@github_url}/login/device/code", body) do
        {:ok, %{status: 200, body: body}} when is_map(body) ->
          {:ok,
           %{
             device_code: body["device_code"],
             user_code: body["user_code"],
             verification_uri: body["verification_uri"],
             expires_in: body["expires_in"],
             interval: body["interval"] || 5
           }}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("GitHub OAuth start failed: HTTP #{status} #{inspect(body)}")
          {:error, :github_oauth_unavailable}

        {:error, reason} ->
          Logger.warning("GitHub OAuth start failed: #{inspect(reason)}")
          {:error, :github_oauth_unavailable}
      end
    end
  end

  def complete_repo_requests(package_names, device_code) when is_list(package_names) do
    package_names = package_names |> Enum.reject(&is_nil/1) |> Enum.uniq()

    with {:ok, token} <- poll_device_flow(device_code),
         access_token when is_binary(access_token) <- token["access_token"],
         {:ok, %{"login" => login} = github_profile} <- current_user(access_token),
         {:ok, user} <- upsert_github_user(github_profile),
         {:ok, requests} <- create_repo_requests(package_names, login, access_token, user) do
      {:ok, requests}
    else
      {:pending, reason} -> {:pending, reason}
      nil -> {:error, :missing_access_token}
      {:error, reason} -> {:error, reason}
    end
  end

  def complete_repo_requests(_package_names, _device_code), do: {:error, :missing_package}

  @doc """
  OAuth scope requested from GitHub. Empty on purpose; see `@scope`.
  """
  def scope, do: @scope

  # `scope` is optional in the device flow. Omit the key entirely rather than
  # sending an empty value, so the consent screen reads as public data only.
  defp device_flow_params(client_id) do
    case scope() do
      "" -> %{client_id: client_id}
      scope -> %{client_id: client_id, scope: scope}
    end
  end

  defp client_id do
    Application.get_env(:portal, :github_client_id)
    |> case do
      client_id when is_binary(client_id) and client_id != "" -> {:ok, client_id}
      _ -> {:error, :github_oauth_unavailable}
    end
  end

  defp poll_device_flow(device_code) when is_binary(device_code) do
    with {:ok, client_id} <- client_id() do
      body =
        URI.encode_query(%{
          grant_type: "urn:ietf:params:oauth:grant-type:device_code",
          client_id: client_id,
          device_code: device_code
        })

      case post_form("#{@github_url}/login/oauth/access_token", body) do
        {:ok, %{status: 200, body: %{"access_token" => _access_token} = body}} ->
          {:ok, body}

        {:ok, %{status: 200, body: %{"error" => error}}}
        when error in ["authorization_pending", "slow_down"] ->
          {:pending, String.to_atom(error)}

        {:ok, %{status: 200, body: %{"error" => "expired_token"}}} ->
          {:error, :expired_token}

        {:ok, %{status: 200, body: %{"error" => "access_denied"}}} ->
          {:error, :access_denied}

        {:ok, %{status: status, body: body}} ->
          Logger.warning("GitHub OAuth poll failed: HTTP #{status} #{inspect(body)}")
          {:error, :github_oauth_unavailable}

        {:error, reason} ->
          Logger.warning("GitHub OAuth poll failed: #{inspect(reason)}")
          {:error, :github_oauth_unavailable}
      end
    end
  end

  defp poll_device_flow(_device_code), do: {:error, :github_oauth_unavailable}

  defp current_user(access_token) do
    case github_get("/user", access_token) do
      {:ok, %{status: 200, body: %{"login" => login} = body}} when is_binary(login) ->
        {:ok, body}

      {:ok, %{status: 401}} ->
        {:error, :invalid_token}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("GitHub /user failed: HTTP #{status} #{inspect(body)}")
        {:error, :github_api_unavailable}

      {:error, reason} ->
        Logger.warning("GitHub /user failed: #{inspect(reason)}")
        {:error, :github_api_unavailable}
    end
  end

  defp create_repo_requests(package_names, login, access_token, user) do
    package_names
    |> Enum.reduce_while({:ok, []}, fn package_name, {:ok, requests} ->
      with {:ok, repo} <- package_github_repo(package_name),
           {:ok, permissions} <- repo_permission(repo, login, access_token),
           true <- writable_permission?(permissions),
           {:ok, request} <- create_scan_request(package_name, repo, user) do
        {:cont, {:ok, [request | requests]}}
      else
        false -> {:halt, {:error, {:not_repo_maintainer, package_name}}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requests} -> {:ok, Enum.reverse(requests)}
      error -> error
    end
  end

  defp package_github_repo(package_name) do
    case Req.get("https://hex.pm/api/packages/#{package_name}", headers: json_headers()) do
      {:ok, %{status: 200, body: package}} when is_map(package) ->
        package
        |> github_url_from_package()
        |> repo_from_url()
        |> case do
          {:ok, repo} -> {:ok, repo}
          :error -> {:error, {:missing_github_repo, package_name}}
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

  defp github_url_from_package(package) do
    links = get_in(package, ["meta", "links"]) || %{}

    links
    |> Enum.find_value(fn {label, url} ->
      if is_binary(label) and is_binary(url) and
           String.contains?(String.downcase(url), "github.com") do
        url
      end
    end)
  end

  defp repo_from_url(url) when is_binary(url) do
    uri = URI.parse(url)

    cond do
      uri.host in ["github.com", "www.github.com"] ->
        uri.path
        |> String.trim_leading("/")
        |> String.split("/", trim: true)
        |> repo_from_parts()

      String.starts_with?(url, "git@github.com:") ->
        url
        |> String.replace_prefix("git@github.com:", "")
        |> String.split("/", trim: true)
        |> repo_from_parts()

      true ->
        :error
    end
  end

  defp repo_from_url(_url), do: :error

  defp repo_from_parts([owner, repo | _]) do
    repo = String.replace_suffix(repo, ".git", "")
    {:ok, %{owner: owner, repo: repo, full_name: "#{owner}/#{repo}"}}
  end

  defp repo_from_parts(_parts), do: :error

  # Reads the authenticated user's own access off the repository record rather
  # than `/collaborators/:login/permission`. That endpoint answers "what access
  # does user X have", so GitHub gates it behind *push access of the caller* and
  # returns 403 "Must have push access to view collaborator permission" for the
  # exact population we need to reject cleanly. `GET /repos/:owner/:repo`
  # answers "what access do *I* have", which is the only question we ask.
  defp repo_permission(repo, _login, access_token) do
    case github_get("/repos/#{repo.owner}/#{repo.repo}", access_token) do
      {:ok, %{status: 200, body: %{"permissions" => permissions}}} when is_map(permissions) ->
        {:ok, permissions}

      # A repo readable without a `permissions` block means the token was not
      # accepted as an identity for it. Fail loudly instead of silently
      # rejecting a real maintainer.
      {:ok, %{status: 200, body: body}} ->
        Logger.warning("GitHub repo response had no permissions block: #{inspect(body)}")
        {:error, :github_api_unavailable}

      {:ok, %{status: status}} when status in [403, 404] ->
        {:error, {:not_repo_maintainer, repo.full_name}}

      {:ok, %{status: status, body: body}} ->
        Logger.warning("GitHub repo permission failed: HTTP #{status} #{inspect(body)}")
        {:error, :github_api_unavailable}

      {:error, reason} ->
        Logger.warning("GitHub repo permission failed: #{inspect(reason)}")
        {:error, :github_api_unavailable}
    end
  end

  @doc """
  True when the repository `permissions` block grants write or better.

  Mirrors the role strings the collaborator-permission endpoint used to return:
  `push` is the boolean form of the "write" role.
  """
  def writable_permission?(permissions) when is_map(permissions) do
    Enum.any?(@writable_permissions, &(permissions[&1] == true))
  end

  def writable_permission?(_permissions), do: false

  defp github_get(path, access_token) do
    Req.get("#{@api_url}#{path}",
      headers: [
        {"authorization", "Bearer #{access_token}"},
        {"accept", "application/vnd.github+json"},
        {"x-github-api-version", "2022-11-28"}
      ]
    )
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

  defp json_headers, do: [{"accept", "application/json"}]

  defp upsert_github_user(%{"login" => login} = github_profile) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case get_github_user(login) do
      {:ok, nil} ->
        Portal.Accounts.User
        |> Ash.Changeset.for_create(:create, %{
          username: login,
          github_username: login,
          github_profile: encode_profile(github_profile),
          password_hash: hash_generated_password(),
          last_github_login_at: now
        })
        |> Ash.create(domain: Portal.Accounts)

      {:ok, user} ->
        user
        |> Ash.Changeset.for_update(:record_github_login, %{
          github_username: login,
          github_profile: encode_profile(github_profile),
          last_github_login_at: now
        })
        |> Ash.update(domain: Portal.Accounts)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_github_user(login) do
    with {:ok, users} <- Ash.read(Portal.Accounts.User, domain: Portal.Accounts) do
      {:ok, Enum.find(users, &(&1.github_username == login))}
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

  defp create_scan_request(package_name, repo, user) do
    %{
      package_name: package_name,
      source: :github_repo,
      status: :accepted,
      user_id: user.id,
      subject: "#{user.github_username}:#{repo.full_name}",
      verification_provider: "github_oauth_device"
    }
    |> Portal.ScanRequests.create_once()
  end
end
