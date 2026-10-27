defmodule PortalWeb.Plugs.RequireLogin do
  @moduledoc """
  Halts the connection unless the session belongs to a portal user.

  Used to gate self-service account pages such as `/settings`. The resolved user
  is assigned as `:current_user` so downstream actions never have to trust a
  client-supplied identifier. A revoked session
  (`Portal.Accounts.session_user/2`) is refused like no session, and its
  sign-in keys are dropped from the cookie on the way to `/login`.
  """

  import Plug.Conn
  import Phoenix.Controller

  use PortalWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
    case PortalWeb.UserAuth.current_user(conn) do
      %Portal.Accounts.User{} = user ->
        assign(conn, :current_user, user)

      nil ->
        conn
        |> PortalWeb.UserAuth.drop_login()
        |> put_flash(:error, "Sign in to manage your account.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end
end
