defmodule PortalWeb.Plugs.RequireAdmin do
  @moduledoc """
  Halts the connection unless the current session belongs to an admin user.
  Used to gate the Oban Web dashboard (and any other admin-only mount).
  """

  import Plug.Conn
  import Phoenix.Controller

  use PortalWeb, :verified_routes

  def init(opts), do: opts

  def call(conn, _opts) do
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
        |> halt()

      Portal.Accounts.admin?(user) ->
        assign(conn, :current_user, user)

      true ->
        conn
        |> put_flash(:error, "Admin access is required.")
        |> redirect(to: ~p"/request-scan")
        |> halt()
    end
  end
end
