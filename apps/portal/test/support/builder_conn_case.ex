defmodule PortalWeb.BuilderConnCase do
  @moduledoc """
  ConnCase for `PortalWeb.BuilderEndpoint`: a throwaway CA per test and
  helpers that put a client certificate (or none) into the peer data, the way
  Bandit reports the TLS handshake.
  """
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint PortalWeb.BuilderEndpoint
      import Plug.Conn
      import Phoenix.ConnTest
      import PortalWeb.BuilderConnCase
      require Ash.Query
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Portal.Repo, shared: not tags[:async])
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, Portal.Builders.CA, [])
    Application.put_env(:portal, Portal.Builders.CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = Portal.Builders.CA.init(key_path)
    Portal.Builders.RateLimit.reset()

    on_exit(fn ->
      Ecto.Adapters.SQL.Sandbox.stop_owner(pid)
      Application.put_env(:portal, Portal.Builders.CA, previous)
      File.rm_rf(dir)
    end)

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Enrol a builder named `name`; returns it with its certificate DER and private key."
  def enrolled_builder!(name, attrs \\ %{}) do
    {:ok, %{token: token}} = Portal.Builders.create_token(name, "test")
    key = X509.PrivateKey.new_ec(:secp256r1)
    csr = X509.CSR.new(key, "/CN=#{name}") |> X509.CSR.to_pem()
    {:ok, %{builder: builder, cert_pem: pem}} = Portal.Builders.enrol(token, csr, attrs)

    %{
      builder: builder,
      cert_der: pem |> X509.Certificate.from_pem!() |> X509.Certificate.to_der(),
      key: key
    }
  end

  def with_cert(conn, der),
    do: Plug.Test.put_peer_data(conn, %{address: {127, 0, 0, 1}, port: 4444, ssl_cert: der})

  def without_cert(conn),
    do: Plug.Test.put_peer_data(conn, %{address: {127, 0, 0, 1}, port: 4444, ssl_cert: nil})
end
