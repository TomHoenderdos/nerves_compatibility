defmodule PortalWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` hooks for assigning auth-derived state.

  Controllers derive `current_user` from `get_session(conn, :user_id)` via
  `Portal.Accounts.get_user/1`. LiveViews mounted outside a controller need
  the same assign so `<Layouts.app current_user={@current_user} ...>` shows
  the signed-in nav state instead of always rendering Login/Register.
  """

  import Phoenix.Component, only: [assign: 3]

  def on_mount(:assign_current_user, _params, session, socket) do
    {:cont, assign(socket, :current_user, current_user_from_session(session))}
  end

  defp current_user_from_session(%{"user_id" => user_id}) when is_binary(user_id) do
    case Portal.Accounts.get_user(user_id) do
      {:ok, user} -> user
      _ -> nil
    end
  end

  defp current_user_from_session(_session), do: nil
end
