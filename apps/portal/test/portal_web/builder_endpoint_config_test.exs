defmodule PortalWeb.BuilderEndpointConfigTest do
  use ExUnit.Case, async: false

  alias Portal.Builders.{CA, Listener}

  test "the listener is off without a CA and on with one" do
    refute Listener.enabled?()
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key = Path.join(dir, "ca-key.pem")
    previous_ca = Application.get_env(:portal, CA, [])
    previous_ep = Application.get_env(:portal, PortalWeb.BuilderEndpoint, [])

    on_exit(fn ->
      Application.put_env(:portal, CA, previous_ca)
      Application.put_env(:portal, PortalWeb.BuilderEndpoint, previous_ep)
      File.rm_rf(dir)
    end)

    {:ok, _} = CA.init(key)
    Application.put_env(:portal, CA, key_path: key)
    # A CA alone does not start the listener; `server: true` is needed too.
    refute Listener.enabled?()

    Application.put_env(
      :portal,
      PortalWeb.BuilderEndpoint,
      Keyword.put(previous_ep, :server, true)
    )

    assert Listener.enabled?()

    opts = Listener.https_options("portal.test")
    transport = opts[:thousand_island_options][:transport_options]
    assert transport[:verify] == :verify_peer
    assert transport[:fail_if_no_peer_cert] == false
    assert transport[:cacertfile] == CA.cert_path()

    for key <- [:verify, :fail_if_no_peer_cert, :cacertfile],
        do: refute(Keyword.has_key?(opts, key))

    assert File.exists?(opts[:certfile]) and File.exists?(opts[:keyfile])
    assert opts[:http_2_options][:enabled] == false
    assert opts[:cipher_suite] == :strong
    assert opts[:port] == 8443
  end

  test "the builder endpoint does not listen in test" do
    assert Application.fetch_env!(:portal, PortalWeb.BuilderEndpoint)[:server] == false
  end
end
