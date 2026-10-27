defmodule Portal.Accounts.LiveSocketsTest do
  use ExUnit.Case, async: true

  # An endpoint that is compiled but never started: what `PortalWeb.Endpoint`
  # is under `bin/portal eval` or `mix run --no-start`, where the break-glass
  # `Portal.Accounts.Recovery.clear_factors!/1` deletes passkeys.
  defmodule NeverStartedEndpoint do
    use Phoenix.Endpoint, otp_app: :portal
  end

  test "disconnecting with no running endpoint is a no-op, not a crash" do
    assert :ok =
             Portal.Accounts.disconnect_live_sockets(Ecto.UUID.generate(), NeverStartedEndpoint)
  end

  test "disconnecting with the running endpoint broadcasts" do
    user_id = Ecto.UUID.generate()
    topic = Portal.Accounts.live_socket_id(user_id)
    PortalWeb.Endpoint.subscribe(topic)

    assert :ok = Portal.Accounts.disconnect_live_sockets(user_id)
    assert_receive %Phoenix.Socket.Broadcast{topic: ^topic, event: "disconnect"}
  end
end
