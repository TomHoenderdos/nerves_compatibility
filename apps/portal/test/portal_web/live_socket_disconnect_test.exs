defmodule PortalWeb.LiveSocketDisconnectTest do
  @moduledoc """
  A live socket outlives the HTTP request that opened it: an admin LiveView
  keeps paging and refreshing on the actor it mounted with until the socket
  closes. Every login therefore names the session's live socket, and signing
  out disconnects it, so the client reconnects and the `/admin` gate runs
  again on whatever session is left.
  """
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  @password "correct horse battery staple"

  defp log_in(conn, user) do
    post(conn, ~p"/login", %{"username" => user.username, "password" => @password})
  end

  test "the socket id LiveView derives from the session is the one login stored", %{conn: conn} do
    user = user_fixture(%{password: @password})
    conn = log_in(conn, user)

    # What `Phoenix.LiveView.Socket.id/1` reads off the cookie session when a
    # socket connects: the topic a broadcast must use to reach it.
    socket = %Phoenix.Socket{private: %{connect_info: %{session: get_session(conn)}}}
    assert Phoenix.LiveView.Socket.id(socket) == "users_socket:#{user.id}"
  end

  test "logging out disconnects that user's live sockets", %{conn: conn} do
    user = user_fixture(%{password: @password})
    topic = "users_socket:#{user.id}"
    PortalWeb.Endpoint.subscribe(topic)

    conn = conn |> log_in(user) |> recycle() |> post(~p"/logout")

    assert redirected_to(conn) == ~p"/request-scan"
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end

  # Sessions signed in before live socket ids existed carry none. They sign
  # out as before; there is simply no socket topic to broadcast on.
  test "logging out a session without a live socket id still signs out", %{conn: conn} do
    user = user_fixture(%{password: @password})
    PortalWeb.Endpoint.subscribe("users_socket:#{user.id}")

    conn =
      conn
      |> init_test_session(user_id: user.id, login_method: :password)
      |> post(~p"/logout")

    assert redirected_to(conn) == ~p"/request-scan"
    refute get_session(conn, :user_id)
    refute_receive %Phoenix.Socket.Broadcast{event: "disconnect"}, 50
  end
end
