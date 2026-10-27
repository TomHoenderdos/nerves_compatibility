defmodule PortalWeb.PageController do
  use PortalWeb, :controller

  @package_regex ~r/^[a-z][a-z0-9_]*$/
  @max_anonymous_packages 25

  def request_scan(conn, _params) do
    render_request_scan(conn)
  end

  def oban_embed(conn, _params) do
    case require_admin(conn) do
      {:ok, conn, user} -> render(conn, :oban_embed, current_user: user)
      {:error, conn} -> conn
    end
  end

  def admin(conn, _params), do: admin_section(conn, :overview)
  def admin_failures(conn, _params), do: admin_section(conn, :failures)
  def admin_argus(conn, _params), do: admin_section(conn, :argus)

  defp admin_section(conn, section) do
    case require_admin(conn) do
      {:ok, conn, user} -> render_admin(conn, user, section)
      {:error, conn} -> conn
    end
  end

  def admin_revoke_run(conn, params) do
    case require_admin(conn) do
      {:ok, conn, _user} ->
        run_id = params["run_id"]

        conn =
          case run_id && Portal.Catalog.revoke_run(run_id) do
            {:ok, _run} ->
              put_flash(conn, :info, "Run #{run_id} revoked; the next batch drops its files.")

            _ ->
              put_flash(conn, :error, "No run #{run_id}.")
          end

        redirect(conn, to: ~p"/admin/maintenance")

      {:error, conn} ->
        conn
    end
  end

  # Redirects rather than renders: a refreshed rendered POST would queue the
  # sweep again.
  def admin_toolchain_sweep(conn, _params) do
    case require_admin(conn) do
      {:ok, conn, _user} ->
        conn
        |> put_toolchain_sweep_flash(Portal.Workers.ToolchainSweep.enqueue())
        |> redirect(to: ~p"/admin/maintenance")

      {:error, conn} ->
        conn
    end
  end

  defp put_toolchain_sweep_flash(conn, {:ok, _job}),
    do: put_flash(conn, :info, "Toolchain sweep queued.")

  defp put_toolchain_sweep_flash(conn, {:error, :already_queued}),
    do: put_flash(conn, :info, "A toolchain sweep is already queued.")

  defp put_toolchain_sweep_flash(conn, {:error, reason}),
    do: put_flash(conn, :error, PortalWeb.AdminMessages.error(reason))

  # Redirects like the toolchain sweep, so a refresh does not queue it again.
  def admin_repair_file_modes(conn, _params) do
    case require_admin(conn) do
      {:ok, conn, _user} ->
        conn
        |> put_repair_file_modes_flash(Portal.Workers.ManifestModeRepair.enqueue())
        |> redirect(to: ~p"/admin/maintenance")

      {:error, conn} ->
        conn
    end
  end

  defp put_repair_file_modes_flash(conn, {:ok, _job}),
    do: put_flash(conn, :info, "File mode repair queued; the next batch publishes it.")

  defp put_repair_file_modes_flash(conn, {:error, :already_queued}),
    do: put_flash(conn, :info, "A file mode repair is already queued.")

  defp put_repair_file_modes_flash(conn, {:error, reason}),
    do: put_flash(conn, :error, PortalWeb.AdminMessages.error(reason))

  def admin_argus_settings(conn, params) do
    case require_admin(conn) do
      {:ok, conn, user} ->
        case Portal.Admin.update_argus_settings(params["argus"] || %{}) do
          {:ok, _setting} ->
            conn
            |> put_flash(:info, "Saved argus settings.")
            |> render_admin(user, :argus)

          {:error, reason} ->
            conn
            |> put_flash(:error, PortalWeb.AdminMessages.error(reason))
            |> render_admin(user, :argus)
        end

      {:error, conn} ->
        conn
    end
  end

  def register(conn, _params) do
    render_auth(conn, :register, username: "")
  end

  def create_account(conn, %{"username" => username, "password" => password}) do
    case Portal.Accounts.register_user(username, password) do
      {:ok, user} ->
        conn
        |> PortalWeb.UserAuth.complete_login(user, :password)
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
        # The password alone no longer produces a session. A confirmed TOTP
        # means the user is parked under `:pending_user_id`, which grants
        # nothing, until they clear `/login/totp`.
        if Portal.Accounts.Mfa.second_factor_required?(user) do
          conn
          |> PortalWeb.UserAuth.start_pending(user)
          |> redirect(to: ~p"/login/totp")
        else
          conn
          |> PortalWeb.UserAuth.complete_login(user, :password)
          |> put_flash(:info, "Signed in.")
          |> redirect(to: PortalWeb.UserAuth.landing_path(user, :password))
        end

      {:error, reason} ->
        conn
        |> PortalWeb.UserAuth.drop_pending()
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
        |> keep_session_after_password_change(user, updated)
        |> put_flash(:info, "Account settings updated.")
        |> render_settings(updated)

      {:error, reason} ->
        conn
        |> put_flash(:error, settings_error_message(reason))
        |> render_settings(user)
    end
  end

  def set_password(conn, params) do
    user = settings_user(conn)

    cond do
      user.password_set ->
        conn
        |> put_flash(:error, "Change your password with your current one.")
        |> redirect(to: ~p"/settings")

      not Portal.Accounts.Mfa.reauth_fresh?(
        user,
        PortalWeb.UserAuth.reauth_method(conn),
        PortalWeb.UserAuth.reauth_at(conn)
      ) ->
        conn
        |> put_flash(:error, "Confirm it is you first.")
        |> redirect(to: ~p"/settings/security")

      true ->
        case Portal.Accounts.set_password(user, string_param(params, "new_password")) do
          {:ok, _} ->
            conn |> put_flash(:info, "Password set.") |> redirect(to: ~p"/settings")

          {:error, :invalid_password} ->
            conn
            |> put_flash(:error, "Use at least 12 characters.")
            |> redirect(to: ~p"/settings")

          {:error, _} ->
            conn
            |> put_flash(:error, "Setting the password failed. Try again.")
            |> redirect(to: ~p"/settings")
        end
    end
  end

  # Clearing the cookie ends the session for the next request, not for a
  # LiveView already connected on it: that keeps working on the user it
  # mounted with. The disconnect makes those sockets reconnect, and without
  # this session's cookie the reconnect is refused and the page reloads.
  # A session from before live socket ids has none to disconnect.
  #
  # Sign-out ends this browser's session only, on purpose: the user's other
  # browsers stay signed in. It does not revoke, so a copy of this cookie
  # taken earlier stays valid until the user's sessions are next revoked;
  # "Sign out everywhere" at `/settings/security` is the revoke.
  def logout(conn, _params) do
    if live_socket_id = get_session(conn, :live_socket_id) do
      PortalWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
    end

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

    case Portal.HexPm.complete_owner_requests(packages, device_code, current_user(conn)) do
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

    case Portal.GitHub.complete_repo_requests(packages, device_code, current_user(conn)) do
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

      # Each name may cost a CDN request, so the list is bounded before any
      # lookup runs.
      length(packages) > @max_anonymous_packages ->
        conn
        |> put_flash(:error, "Request at most #{@max_anonymous_packages} packages at a time.")
        |> render_request_scan(packages: packages)

      true ->
        submit_anonymous_requests(conn, packages)
    end
  end

  # A name that only looks like a package -- a typo, something from another
  # ecosystem -- used to become a pending request an admin had to read and
  # reject by hand, and a public package page in the meantime. The whole
  # submission is refused, as for a malformed name, so nobody ends up with half
  # their list requested and the other half silently dropped.
  defp submit_anonymous_requests(conn, packages) do
    case unknown_hex_packages(packages) do
      {:ok, []} ->
        create_and_render_anonymous_requests(conn, packages)

      {:ok, unknown} ->
        conn
        |> put_flash(:error, "Not a Hex package: #{Enum.join(unknown, ", ")}.")
        |> render_request_scan(packages: packages)

      {:error, :hex_api_unavailable} ->
        conn
        |> put_flash(
          :error,
          "Could not reach hex.pm to check the package names. Try again in a moment."
        )
        |> render_request_scan(packages: packages)
    end
  end

  defp create_and_render_anonymous_requests(conn, packages) do
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

  # Sequential, and stops at the first lookup that fails: one unreachable answer
  # already decides the outcome, so asking about the rest only adds waiting.
  defp unknown_hex_packages(packages) do
    lookup = Application.get_env(:portal, :hex_package_lookup, Portal.HexPackageLookup)

    packages
    |> Enum.reduce_while({:ok, []}, fn package, {:ok, unknown} ->
      case lookup.package_exists?(package) do
        {:ok, true} -> {:cont, {:ok, unknown}}
        {:ok, false} -> {:cont, {:ok, [package | unknown]}}
        {:error, _reason} -> {:halt, {:error, :hex_api_unavailable}}
      end
    end)
    |> case do
      {:ok, unknown} -> {:ok, Enum.reverse(unknown)}
      error -> error
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
      with {:ok, user} <- maybe_change_username(user, username) do
        maybe_change_password(user, current_password, new_password)
      end
    end
  end

  defp string_param(params, key) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _other -> ""
    end
  end

  # A password change signs out every session on the account
  # (`Portal.Accounts.change_password/3`), which would include this one. The
  # person who just proved the current password stays signed in here.
  defp keep_session_after_password_change(conn, before, updated) do
    if updated.sessions_valid_after != before.sessions_valid_after,
      do: PortalWeb.UserAuth.restamp_session(conn, updated),
      else: conn
  end

  defp maybe_change_username(user, ""), do: {:ok, user}

  defp maybe_change_username(user, username),
    do: Portal.Accounts.change_username(user, username)

  defp maybe_change_password(user, "", ""), do: {:ok, user}

  defp maybe_change_password(user, current_password, new_password),
    do: Portal.Accounts.change_password(user, current_password, new_password)

  # One template per admin section, each loading only what it shows. The
  # section's id doubles as the active tab.
  defp render_admin(conn, user, section) do
    conn
    |> render(
      admin_template(section),
      [
        page_title: "Admin",
        page_description: "Administration.",
        current_user: user,
        admin_section: section
      ] ++ admin_assigns(section)
    )
  end

  defp admin_template(:overview), do: :admin
  defp admin_template(:failures), do: :admin_failures
  defp admin_template(:argus), do: :admin_argus

  defp admin_assigns(:failures) do
    [
      recent_failures: Portal.ScanRequests.recent_failures(50),
      version_streaks: Portal.Catalog.failing_version_streaks()
    ]
  end

  defp admin_assigns(:argus) do
    [
      argus: Portal.Settings.get(),
      argus_analysis_names: Portal.Settings.Setting.analysis_names(),
      triage_counts: Portal.Catalog.triage_counts()
    ]
  end

  defp admin_assigns(:overview) do
    [
      review_total: Portal.ScanRequests.pending_anonymous_page(1).total,
      queue_total: Portal.ScanRequests.queue_page(1).total,
      failures: Portal.ScanRequests.recent_failures(5),
      triage_counts: Portal.Catalog.triage_counts(),
      update_check: Portal.Admin.update_check_status(),
      admin_count: length(Portal.Admin.list_admins())
    ]
  end

  # These admin actions carry the same privilege as the Oban dashboard behind
  # `PortalWeb.Plugs.RequireAdmin`, so they answer to the same policy rather
  # than a copy of it. They are routed through `:browser` and not `:admin`
  # because they render this controller's own admin page, which the plug's
  # scope has no alias for.
  defp require_admin(conn), do: PortalWeb.Plugs.RequireAdmin.authorise(conn)

  defp current_user(conn), do: PortalWeb.UserAuth.current_user(conn)

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
end
