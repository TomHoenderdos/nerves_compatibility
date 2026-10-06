defmodule PortalWeb.ProviderAuthController do
  @moduledoc """
  Hex.pm and GitHub as ways to sign in, link, and confirm it is you.

  All three run the provider's device flow and differ only in what the
  verified identity is used for. The flow's state lives in the session under
  `:provider_flow`, tagged with its purpose, so a code started to link an
  account cannot be completed as a login or the other way round.
  """

  use PortalWeb, :controller

  alias Portal.Accounts.{Identities, Identity, IdentityProvider, Mfa}
  alias PortalWeb.ProviderAuthController.UnknownProvider
  alias PortalWeb.UserAuth

  @pending_ttl_seconds 600

  # --- Sign in ---------------------------------------------------------------

  def start_login(conn, %{"provider" => provider}) do
    with_provider(conn, provider, &start_flow(conn, &1, "login", ~p"/login"))
  end

  def complete_login(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      case verify_flow(conn, provider, "login", ~p"/login") do
        {:ok, identity, conn} -> sign_in(conn, identity)
        {:render, conn} -> conn
      end
    end)
  end

  defp sign_in(conn, identity) do
    case Identities.sign_in(identity) do
      {:ok, user} ->
        finish_login(conn, user, identity.provider)

      {:error, :choose_username} ->
        conn
        |> put_session(:pending_identity, Map.put(Identity.to_session(identity), "at", now()))
        |> redirect(to: ~p"/auth/choose-username")

      {:error, _} ->
        conn
        |> put_flash(:error, "Signing in failed. Try again.")
        |> redirect(to: ~p"/login")
    end
  end

  # Same fork as the password sign-in in `PageController.create_session/2`.
  # Also clears `:pending_identity` -- a stray submit to `/auth/choose-username`
  # replaying an old cookie must not be able to create a second account once
  # this identity has already signed somebody in. `UserAuth.complete_login/3`
  # clears it too, but the second-factor branch never reaches that.
  defp finish_login(conn, user, method) do
    conn = delete_session(conn, :pending_identity)

    if Mfa.second_factor_required?(user) do
      conn
      |> UserAuth.start_pending(user)
      |> redirect(to: ~p"/login/totp")
    else
      conn
      |> UserAuth.complete_login(user, method)
      |> put_flash(:info, "Signed in.")
      |> redirect(to: UserAuth.landing_path(user, method))
    end
  end

  # --- Choose a username -----------------------------------------------------

  def choose_username(conn, _params) do
    case pending_identity(conn) do
      {:ok, identity} -> render_choose(conn, identity, identity.username)
      :error -> expired(conn)
    end
  end

  def create_with_username(conn, %{"username" => username}) do
    case pending_identity(conn) do
      {:ok, identity} ->
        case Identities.create_with_username(identity, username) do
          {:ok, user} ->
            finish_login(conn, user, identity.provider)

          {:error, :identity_taken} ->
            conn |> delete_session(:pending_identity) |> expired()

          {:error, reason} ->
            conn
            |> put_flash(:error, username_error(reason))
            |> render_choose(identity, username)
        end

      :error ->
        expired(conn)
    end
  end

  def create_with_username(conn, _params), do: create_with_username(conn, %{"username" => ""})

  defp pending_identity(conn) do
    with %{"at" => at} = stored when is_integer(at) <- get_session(conn, :pending_identity),
         true <- (now() - at) in 0..@pending_ttl_seconds,
         {:ok, identity} <- Identity.from_session(stored) do
      {:ok, identity}
    else
      _ -> :error
    end
  end

  defp render_choose(conn, identity, username) do
    render(conn, :choose_username,
      page_title: "Choose a username",
      current_user: conn.assigns[:current_user],
      provider_label: provider_label(identity.provider),
      suggested: identity.username,
      reason: choose_reason(identity),
      username: username
    )
  end

  # Why the provider name could not simply become the username: the page
  # should not claim a name is taken when it was never usable here at all.
  defp choose_reason(identity) do
    if Portal.Accounts.valid_username?(String.downcase(identity.username)),
      do: :taken,
      else: :invalid
  end

  defp expired(conn) do
    conn
    |> delete_session(:pending_identity)
    |> put_flash(:error, "That sign-in expired. Start again.")
    |> redirect(to: ~p"/login")
  end

  defp username_error(:username_taken), do: "That username is taken. Pick another."

  defp username_error(:invalid_username),
    do: "Use 3 to 40 letters, digits, dots, dashes or underscores."

  defp username_error(_reason), do: "Creating the account failed. Try again."

  # --- Link, unlink, confirm (signed in) -------------------------------------

  defp security, do: ~p"/settings/security"

  def start_link(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn -> start_flow(conn, provider, "link", security()) end)
    end)
  end

  def complete_link(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn -> finish_link(conn, provider) end)
    end)
  end

  defp finish_link(conn, provider) do
    case verify_flow(conn, provider, "link", security()) do
      {:ok, identity, conn} -> link(conn, identity)
      {:render, conn} -> conn
    end
  end

  defp link(conn, identity) do
    label = provider_label(identity.provider)

    message =
      case Identities.link(conn.assigns.current_user, identity) do
        {:ok, _} ->
          {:info, "#{label} linked. You can sign in with it now."}

        {:error, :linked_elsewhere} ->
          {:error, "This #{label} account is linked to another user."}

        {:error, :provider_already_linked} ->
          {:error, "Unlink your current #{label} account first."}

        {:error, _} ->
          {:error, "Linking #{label} failed. Try again."}
      end

    {kind, text} = message
    conn |> put_flash(kind, text) |> redirect(to: security())
  end

  def unlink(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      with_step_up(conn, fn -> finish_unlink(conn, provider) end)
    end)
  end

  defp finish_unlink(conn, provider) do
    label = provider_label(provider)

    {kind, text} =
      case Identities.unlink(conn.assigns.current_user, provider) do
        {:ok, _} ->
          {:info, "#{label} unlinked."}

        {:error, :last_way_in} ->
          {:error, "#{label} is your only way to sign in. Set a password or add a passkey first."}

        {:error, :not_linked} ->
          {:error, "#{label} is not linked."}

        {:error, _} ->
          {:error, "Unlinking #{label} failed. Try again."}
      end

    conn |> put_flash(kind, text) |> redirect(to: security())
  end

  # Step-up for accounts with no passkey or TOTP: prove it again with the
  # provider that is linked. The identity must be *the* linked one -- anyone
  # can approve a device code with an account of their own.
  def start_confirm(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider ->
      if provider in Mfa.accepted_reauth_methods(conn.assigns.current_user) do
        start_flow(conn, provider, "reauth", security())
      else
        conn |> put_flash(:error, "Confirm another way.") |> redirect(to: security())
      end
    end)
  end

  def complete_confirm(conn, %{"provider" => provider}) do
    with_provider(conn, provider, fn provider -> finish_confirm(conn, provider) end)
  end

  defp finish_confirm(conn, provider) do
    user = conn.assigns.current_user

    case verify_flow(conn, provider, "reauth", security()) do
      {:ok, identity, conn} -> confirm_result(conn, provider, user, identity)
      {:render, conn} -> conn
    end
  end

  defp confirm_result(conn, provider, user, identity) do
    if provider in Mfa.accepted_reauth_methods(user) and Identities.matches?(user, identity) do
      conn
      |> UserAuth.mark_reauth(provider)
      |> put_flash(
        :info,
        "Confirmed. You have #{div(Mfa.reauth_window_seconds(), 60)} minutes to make changes."
      )
      |> redirect(to: security())
    else
      conn
      |> put_flash(:error, "That is not the #{provider_label(provider)} account linked here.")
      |> redirect(to: security())
    end
  end

  defp with_step_up(conn, fun) do
    user = conn.assigns.current_user

    if Mfa.reauth_fresh?(user, UserAuth.reauth_method(conn), UserAuth.reauth_at(conn)) do
      fun.()
    else
      conn
      |> put_flash(:error, "Confirm it is you first.")
      |> redirect(to: security())
    end
  end

  # --- Device flow, shared by every purpose ----------------------------------

  defp with_provider(_conn, provider, fun) do
    case parse_provider(provider) do
      {:ok, provider} -> fun.(provider)
      :error -> raise UnknownProvider
    end
  end

  defp parse_provider("hex"), do: {:ok, :hex}
  defp parse_provider("github"), do: {:ok, :github}
  defp parse_provider(_), do: :error

  defp start_flow(conn, provider, purpose, back) do
    case IdentityProvider.module(provider).start_device_flow() do
      {:ok, flow} ->
        flow = %{
          "provider" => Atom.to_string(provider),
          "purpose" => purpose,
          "device_code" => flow.device_code,
          "user_code" => flow.user_code,
          "verification_uri" => flow.verification_uri,
          "verification_uri_complete" => Map.get(flow, :verification_uri_complete)
        }

        conn
        |> put_session(:provider_flow, flow)
        |> render_device(flow, polling?: false)

      {:error, _} ->
        conn
        |> put_flash(
          :error,
          "#{provider_label(provider)} is not reachable right now. Try again later."
        )
        |> redirect(to: back)
    end
  end

  defp verify_flow(conn, provider, purpose, back) do
    provider_name = Atom.to_string(provider)

    case get_session(conn, :provider_flow) do
      %{"provider" => ^provider_name, "purpose" => ^purpose, "device_code" => code} = flow ->
        case IdentityProvider.module(provider).verify_device(code) do
          {:ok, identity} ->
            {:ok, identity, delete_session(conn, :provider_flow)}

          {:pending, _} ->
            {:render, render_device(conn, flow, polling?: true)}

          {:error, reason} ->
            {:render,
             conn
             |> delete_session(:provider_flow)
             |> put_flash(:error, flow_error(provider, reason))
             |> redirect(to: back)}
        end

      _ ->
        {:render, conn |> put_flash(:error, "Start again.") |> redirect(to: back)}
    end
  end

  defp render_device(conn, flow, opts) do
    provider = if flow["provider"] == "github", do: :github, else: :hex

    render(conn, :device,
      page_title: "Confirm with #{provider_label(provider)}",
      current_user: conn.assigns[:current_user],
      provider_label: provider_label(provider),
      flow: flow,
      complete_path: complete_path(flow["provider"], flow["purpose"]),
      polling?: Keyword.fetch!(opts, :polling?)
    )
  end

  defp complete_path(provider, "login"), do: ~p"/auth/#{provider}/login/complete"
  defp complete_path(provider, "link"), do: ~p"/settings/providers/#{provider}/link/complete"
  defp complete_path(provider, "reauth"), do: ~p"/settings/providers/#{provider}/confirm/complete"

  defp flow_error(provider, :access_denied),
    do: "You denied the request at #{provider_label(provider)}."

  defp flow_error(_provider, :expired_token), do: "The code expired. Start again."

  defp flow_error(provider, _),
    do: "#{provider_label(provider)} is not reachable right now. Try again later."

  defp provider_label(:hex), do: "Hex.pm"
  defp provider_label(:github), do: "GitHub"

  defp now, do: System.system_time(:second)
end
