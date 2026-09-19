defmodule PortalWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the connection unless the current session belongs to an admin user
  who holds a passkey.

  Used to gate the Oban Web dashboard and, through `authorise/1`, every admin
  action `PortalWeb.PageController` serves. Both entry points share the one
  `cond` below on purpose: the dashboard and the buttons that approve scan
  requests, reorder the queue and start update checks are the same privilege,
  so a second hand-maintained copy of this policy would be a second place for
  it to rot.

  The passkey requirement is enforced here rather than site-wide on purpose:
  an admin without one keeps full use of the rest of the portal and is sent to
  `/settings/security` to enrol, and a non-admin never sees the requirement at
  all. An authenticator app does not substitute. A TOTP code can be read out
  over the phone to someone claiming to be from the project; a passkey
  assertion is bound to the origin and cannot leave the browser.
  """

  import Plug.Conn
  import Phoenix.Controller

  use PortalWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
    case authorise(conn) do
      {:ok, conn, user} -> assign(conn, :current_user, user)
      {:error, conn} -> halt(conn)
    end
  end

  @doc """
  The admin policy, for call sites that are controller actions rather than
  plugs.

  Returns the admin on success. On refusal the returned conn already carries
  the flash and the redirect; a controller returns it as-is, the plug halts it.
  """
  @spec authorise(Plug.Conn.t()) ::
          {:ok, Plug.Conn.t(), Portal.Accounts.User.t()} | {:error, Plug.Conn.t()}
  def authorise(conn) do
    user =
      conn
      |> get_session(:user_id)
      |> Portal.Accounts.get_user()
      |> case do
        {:ok, user} -> user
        _ -> nil
      end

    cond do
      is_nil(user) ->
        conn
        |> put_flash(:error, "Sign in with an admin account.")
        |> redirect(to: ~p"/login")
        |> then(&{:error, &1})

      Portal.Accounts.admin?(user) and not Portal.Accounts.Mfa.admin_satisfied?(user) ->
        conn
        |> put_flash(:error, "Admin access needs a passkey. Add one to continue.")
        |> redirect(to: ~p"/settings/security")
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
end
