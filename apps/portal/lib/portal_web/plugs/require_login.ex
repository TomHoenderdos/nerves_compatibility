defmodule PortalWeb.Plugs.RequireLogin do
  @moduledoc """
  Halts the connection unless the session belongs to a portal user.

  Used to gate self-service account pages such as `/settings`. The resolved user
  is assigned as `:current_user` so downstream actions never have to trust a
  client-supplied identifier.
  """

  import Plug.Conn
  import Phoenix.Controller

  use PortalWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
    conn
    |> get_session(:user_id)
    |> Portal.Accounts.get_user()
    |> case do
      {:ok, %Portal.Accounts.User{} = user} ->
        assign(conn, :current_user, user)

      _other ->
        conn
        |> put_flash(:error, "Sign in to manage your account.")
        |> redirect(to: ~p"/login")
        |> halt()
    end
  end
end
