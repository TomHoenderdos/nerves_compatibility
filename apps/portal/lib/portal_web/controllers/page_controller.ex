defmodule PortalWeb.PageController do
  use PortalWeb, :controller

  @package_regex ~r/^[a-z][a-z0-9_]*$/

  def request_scan(conn, _params) do
    render_request_scan(conn)
  end

  def oban_embed(conn, _params) do
    case require_admin(conn) do
      {:ok, conn, user} -> render(conn, :oban_embed, current_user: user)
      {:error, conn} -> conn
    end
  end

  def admin(conn, _params) do
    case require_admin(conn) do
      {:ok, conn, user} -> render_admin(conn, user)
      {:error, conn} -> conn
    end
  end

  def approve_anonymous_request(conn, %{"id" => id}) do
    case require_admin(conn) do
      {:ok, conn, user} -> review_anonymous_request(conn, user, id, :approve)
      {:error, conn} -> conn
    end
  end

  def reject_anonymous_request(conn, %{"id" => id}) do
    case require_admin(conn) do
      {:ok, conn, user} -> review_anonymous_request(conn, user, id, :reject)
      {:error, conn} -> conn
    end
  end

  def register(conn, _params) do
    render_auth(conn, :register, username: "")
  end

  def create_account(conn, %{"username" => username, "password" => password}) do
    case Portal.Accounts.register_user(username, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Account created.")
        |> redirect(to: ~p"/request-scan")

      {:error, reason} ->
        conn
        |> put_flash(:error, account_error_message(reason))
        |> render_auth(:register, username: username)
    end
  end

  def login(conn, _params) do
    render_auth(conn, :login, username: "")
  end

  def create_session(conn, %{"username" => username, "password" => password}) do
    case Portal.Accounts.authenticate_user(username, password) do
      {:ok, user} ->
        conn
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in.")
        |> redirect(to: ~p"/request-scan")

      {:error, reason} ->
        conn
        |> put_flash(:error, account_error_message(reason))
        |> render_auth(:login, username: username)
    end
  end

  def settings(conn, _params) do
    render_settings(conn, settings_user(conn))
  end

  def update_settings(conn, params) do
    user = settings_user(conn)

    case apply_settings_changes(user, params) do
      {:ok, updated} ->
        conn
        |> put_flash(:info, "Account settings updated.")
        |> render_settings(updated)

      {:error, reason} ->
        conn
        |> put_flash(:error, settings_error_message(reason))
        |> render_settings(user)
    end
  end

  def logout(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Signed out.")
    |> redirect(to: ~p"/request-scan")
  end

  def hex_package_search(conn, %{"query" => query}) do
    packages =
      query
      |> Portal.HexPm.search_packages()
      |> case do
        {:ok, packages} -> packages
        {:error, _reason} -> []
      end

    json(conn, %{packages: packages})
  end

  def hex_package_search(conn, _params), do: json(conn, %{packages: []})

  def hex_start(conn, params) do
    {packages, invalid_packages} = normalize_packages(params)

    cond do
      invalid_packages != [] ->
        conn
        |> put_flash(
          :error,
          "Remove invalid package names: #{Enum.join(invalid_packages, ", ")}."
        )
        |> render_request_scan(packages: packages)

      packages == [] ->
        conn
        |> put_flash(:error, "Enter at least one Hex package name.")
        |> render_request_scan()

      true ->
        case Portal.HexPm.start_device_flow() do
          {:ok, flow} ->
            conn
            |> put_session(:hex_device_code, flow.device_code)
            |> put_session(:hex_packages, packages)
            |> render_request_scan(packages: packages, hex_flow: flow)

          {:error, reason} ->
            conn
            |> put_flash(:error, error_message(reason))
            |> render_request_scan(packages: packages)
        end
    end
  end

  def hex_complete(conn, _params) do
    packages = get_session(conn, :hex_packages) || legacy_session_package(conn)
    device_code = get_session(conn, :hex_device_code)

    case Portal.HexPm.complete_owner_requests(packages, device_code) do
      {:ok, requests} ->
        count = length(requests)

        conn
        |> delete_session(:hex_device_code)
        |> delete_session(:hex_package)
        |> delete_session(:hex_packages)
        |> put_flash(:info, "Verified Hex.pm owner and accepted #{pluralize(count, "package")}.")
        |> render_request_scan(
          packages: Enum.map(requests, & &1.package_name),
          submitted_requests: requests
        )

      {:pending, _reason} ->
        conn
        |> put_flash(:info, "Still waiting for Hex.pm approval.")
        |> render_request_scan(packages: packages, polling?: true)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> render_request_scan(packages: packages)
    end
  end

  def github_start(conn, params) do
    {packages, invalid_packages} = normalize_packages(params)

    cond do
      invalid_packages != [] ->
        conn
        |> put_flash(
          :error,
          "Remove invalid package names: #{Enum.join(invalid_packages, ", ")}."
        )
        |> render_request_scan(packages: packages)

      packages == [] ->
        conn
        |> put_flash(:error, "Enter at least one Hex package name.")
        |> render_request_scan()

      true ->
        case Portal.GitHub.start_device_flow() do
          {:ok, flow} ->
            conn
            |> put_session(:github_device_code, flow.device_code)
            |> put_session(:github_packages, packages)
            |> render_request_scan(packages: packages, github_flow: flow)

          {:error, reason} ->
            conn
            |> put_flash(:error, error_message(reason))
            |> render_request_scan(packages: packages)
        end
    end
  end

  def github_complete(conn, _params) do
    packages = get_session(conn, :github_packages) || []
    device_code = get_session(conn, :github_device_code)

    case Portal.GitHub.complete_repo_requests(packages, device_code) do
      {:ok, requests} ->
        count = length(requests)

        conn
        |> delete_session(:github_device_code)
        |> delete_session(:github_packages)
        |> put_flash(
          :info,
          "Verified GitHub maintainer and accepted #{pluralize(count, "package")}."
        )
        |> render_request_scan(
          packages: Enum.map(requests, & &1.package_name),
          submitted_requests: requests
        )

      {:pending, _reason} ->
        conn
        |> put_flash(:info, "Still waiting for GitHub approval.")
        |> render_request_scan(packages: packages, github_polling?: true)

      {:error, reason} ->
        conn
        |> put_flash(:error, error_message(reason))
        |> render_request_scan(packages: packages)
    end
  end

  def anonymous_request(conn, params) do
    {packages, invalid_packages} = normalize_packages(params)

    cond do
      invalid_packages != [] ->
        conn
        |> put_flash(
          :error,
          "Remove invalid package names: #{Enum.join(invalid_packages, ", ")}."
        )
        |> render_request_scan(packages: packages)

      packages == [] ->
        conn
        |> put_flash(:error, "Enter at least one Hex package name.")
        |> render_request_scan()

      true ->
        case create_anonymous_requests(conn, packages) do
          {:ok, requests} ->
            conn
            |> put_flash(
              :info,
              "Accepted anonymous #{pluralize(length(requests), "request")}; pending human review."
            )
            |> render_request_scan(
              packages: Enum.map(requests, & &1.package_name),
              submitted_requests: requests
            )

          {:error, _reason} ->
            conn
            |> put_flash(:error, "Anonymous request failed.")
            |> render_request_scan(packages: packages)
        end
    end
  end

  defp render_request_scan(conn, assigns \\ []) do
    recent_requests =
      Portal.ScanRequests.ScanRequest
      |> Ash.Query.sort(inserted_at: :desc)
      |> Ash.Query.limit(10)
      |> Ash.read!(domain: Portal.ScanRequests)

    render(conn, :request_scan,
      page_title: "Request a scan",
      page_description:
        "Request a Nerves compatibility build for any Hex package and watch it run.",
      package: Keyword.get(assigns, :package, ""),
      packages: Keyword.get(assigns, :packages, []),
      hex_flow: Keyword.get(assigns, :hex_flow),
      github_flow: Keyword.get(assigns, :github_flow),
      polling?: Keyword.get(assigns, :polling?, false),
      github_polling?: Keyword.get(assigns, :github_polling?, false),
      current_user: current_user(conn),
      recent_requests: recent_requests,
      submitted_requests: Keyword.get(assigns, :submitted_requests, [])
    )
  end

  defp render_auth(conn, template, assigns) do
    render(conn, template,
      page_title: if(template == :register, do: "Create an account", else: "Sign in"),
      page_description:
        if(template == :register,
          do: "Create an account to request Nerves compatibility builds.",
          else: "Sign in to request Nerves compatibility builds."
        ),
      username: Keyword.get(assigns, :username, ""),
      current_user: current_user(conn)
    )
  end

  defp render_settings(conn, user) do
    render(conn, :settings,
      page_title: "Settings",
      page_description: "Account settings.",
      current_user: user,
      username: user.username
    )
  end

  # `PortalWeb.Plugs.RequireLogin` resolves this from the `:user_id` session and
  # halts otherwise, so settings actions never read a user id from params.
  defp settings_user(conn), do: conn.assigns.current_user

  defp apply_settings_changes(user, params) do
    username = params |> string_param("username") |> String.trim()
    current_password = string_param(params, "current_password")
    new_password = string_param(params, "new_password")

    if username == "" and current_password == "" and new_password == "" do
      {:error, :no_changes}
    else
      with {:ok, user} <- maybe_change_username(user, username),
           {:ok, user} <- maybe_change_password(user, current_password, new_password) do
        {:ok, user}
      end
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  defp maybe_change_username(user, ""), do: {:ok, user}

  defp maybe_change_username(user, username),
    do: Portal.Accounts.change_username(user, username)

  defp maybe_change_password(user, "", ""), do: {:ok, user}

  defp maybe_change_password(user, current_password, new_password),
    do: Portal.Accounts.change_password(user, current_password, new_password)

  defp render_admin(conn, user) do
    render(conn, :admin,
      page_title: "Admin",
      page_description: "Administration.",
      current_user: user,
      pending_anonymous_requests: Portal.ScanRequests.pending_anonymous_requests(),
      queue_requests: Portal.ScanRequests.queue_requests()
    )
  end

  defp review_anonymous_request(conn, user, id, :approve) do
    case Portal.ScanRequests.approve_anonymous_request(id, user) do
      {:ok, request} ->
        conn
        |> put_flash(:info, "Approved anonymous request for #{request.package_name}.")
        |> render_admin(user)

      {:error, reason} ->
        conn
        |> put_flash(:error, admin_error_message(reason))
        |> render_admin(user)
    end
  end

  defp review_anonymous_request(conn, user, id, :reject) do
    case Portal.ScanRequests.reject_anonymous_request(id, user) do
      {:ok, request} ->
        conn
        |> put_flash(:info, "Rejected anonymous request for #{request.package_name}.")
        |> render_admin(user)

      {:error, reason} ->
        conn
        |> put_flash(:error, admin_error_message(reason))
        |> render_admin(user)
    end
  end

  defp require_admin(conn) do
    user = current_user(conn)

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "Sign in with an admin account.")
        |> redirect(to: ~p"/login")
        |> then(&{:error, &1})

      Portal.Accounts.admin?(user) ->
        {:ok, conn, user}

      true ->
        conn
        |> put_flash(:error, "Admin access is required.")
        |> redirect(to: ~p"/request-scan")
        |> then(&{:error, &1})
    end
  end

  defp current_user(conn) do
    conn
    |> get_session(:user_id)
    |> Portal.Accounts.get_user()
    |> case do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp create_anonymous_requests(conn, packages) do
    user = current_user(conn)

    packages
    |> Enum.reduce_while({:ok, []}, fn package, {:ok, requests} ->
      %{
        package_name: package,
        source: :anonymous_manual,
        status: :pending,
        user_id: user && user.id,
        subject: if(user, do: user.username, else: "anonymous"),
        verification_provider: "manual_review"
      }
      |> Portal.ScanRequests.create_once()
      |> case do
        {:ok, request} -> {:cont, {:ok, [request | requests]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, requests} ->
        {:ok, Enum.reverse(requests)}

      error ->
        error
    end
  end

  defp normalize_packages(params) do
    params
    |> Map.get("packages", "")
    |> case do
      "" -> Map.get(params, "package", "")
      packages -> packages
    end
    |> package_tokens()
    |> Enum.reduce({[], []}, fn package, {valid, invalid} ->
      normalized = normalize_package(package)

      if Regex.match?(@package_regex, normalized) do
        {[normalized | valid], invalid}
      else
        {valid, [package | invalid]}
      end
    end)
    |> then(fn {valid, invalid} ->
      {valid |> Enum.reverse() |> Enum.uniq(), Enum.reverse(invalid)}
    end)
  end

  defp package_tokens(packages) when is_binary(packages) do
    packages
    |> String.split(~r/[\s,;]+/, trim: true)
  end

  defp package_tokens(_), do: []

  defp legacy_session_package(conn) do
    conn
    |> get_session(:hex_package)
    |> normalize_package()
    |> case do
      "" -> []
      package -> [package]
    end
  end

  defp normalize_package(package) when is_binary(package) do
    package |> String.trim() |> String.downcase()
  end

  defp normalize_package(_), do: ""

  defp pluralize(1, word), do: "1 #{word}"
  defp pluralize(count, word), do: "#{count} #{word}s"

  defp error_message({:not_package_owner, package}),
    do: "The logged-in Hex.pm user is not an owner of #{package}."

  defp error_message(:not_package_owner),
    do: "The logged-in Hex.pm user is not an owner of this package."

  defp error_message(:authorization_pending), do: "Still waiting for Hex.pm approval."
  defp error_message(:expired_token), do: "Hex.pm login expired. Start again."
  defp error_message(:access_denied), do: "Hex.pm login was denied."
  defp error_message(:unknown_package), do: "Package was not found on Hex.pm."
  defp error_message(:hex_oauth_unavailable), do: "Hex.pm login is unavailable."
  defp error_message(:hex_api_unavailable), do: "Hex.pm API is unavailable."
  defp error_message(:github_oauth_unavailable), do: "GitHub login is unavailable."
  defp error_message(:github_api_unavailable), do: "GitHub API is unavailable."

  defp error_message({:missing_github_repo, package}),
    do: "#{package} does not list a GitHub repository on Hex.pm."

  defp error_message({:not_repo_maintainer, package}),
    do: "The logged-in GitHub user does not have write access for #{package}."

  defp error_message(_), do: "Hex.pm owner verification failed."

  defp account_error_message(:invalid_username),
    do: "Use a username with 3-40 letters, numbers, dots, dashes, or underscores."

  defp account_error_message(:invalid_password), do: "Use a password of at least 12 characters."
  defp account_error_message(:username_taken), do: "That username is already registered."
  defp account_error_message(:invalid_credentials), do: "Invalid username or password."
  defp account_error_message(_), do: "Account request failed."

  defp settings_error_message(:invalid_current_password), do: "Current password is incorrect."

  defp settings_error_message(:invalid_password),
    do: "New password must be at least 12 characters."

  defp settings_error_message(:no_changes), do: "Enter a new username or password."

  defp settings_error_message(reason)
       when reason in [:invalid_username, :username_taken],
       do: account_error_message(reason)

  defp settings_error_message(_reason), do: "Account settings update failed."

  defp admin_error_message(:not_found), do: "Request was not found."
  defp admin_error_message(:not_pending_anonymous), do: "Request is no longer pending review."
  defp admin_error_message(_), do: "Admin action failed."
end
