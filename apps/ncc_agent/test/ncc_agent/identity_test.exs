defmodule NccAgent.IdentityTest do
  use ExUnit.Case, async: false

  alias NccAgent.{Config, Identity}
  alias NccAgent.Test.{CA, FakePortal}

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))
    %{url: url} = FakePortal.start(ca, self(), %{})

    config = %{
      Config.defaults()
      | portal_url: url,
        data_dir: Path.join(dir, "data"),
        enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}"
    }

    Config.put(config)
    on_exit(fn -> File.rm_rf(dir) end)
    %{ca: ca, config: config, dir: dir}
  end

  test "first boot fetches and verifies the CA, enrols, and stores the identity", %{
    config: config
  } do
    assert {:ok, %Req.Request{}} = Identity.ensure()
    assert_received {:portal_request, "GET", "/builder/v1/ca.pem", _, nil}

    assert_received {:portal_request, "POST", "/builder/v1/enroll",
                     %{"token" => "id.c2VjcmV0c2VjcmV0." <> _, "csr_pem" => _}, nil}

    assert File.exists?(Config.path(config, :cert)) and File.exists?(Config.path(config, :key)) and
             File.exists?(Config.path(config, :ca))

    assert File.stat!(Config.path(config, :key)).mode |> Bitwise.band(0o777) == 0o600
    assert DateTime.diff(Identity.cert_expires_at(), DateTime.utc_now(), :day) > 300
    # Second call: no enrolment, the existing identity is used.
    assert {:ok, _} = Identity.ensure()
    refute_received {:portal_request, "POST", "/builder/v1/enroll", _, _}
  end

  test "a CA whose hash does not match the token's prefix is refused", %{config: config} do
    Config.put(%{config | enrolment_token: "id.c2VjcmV0c2VjcmV0.0000000000000000"})
    assert {:error, :ca_mismatch} = Identity.ensure()
    refute File.exists?(Config.path(config, :ca))
  end

  test "a certificate within 30 days of expiry is renewed and the files rotated", %{
    config: config,
    ca: ca
  } do
    {:ok, _} = Identity.ensure()
    short = CA.issue(ca, File.read!(Path.join(config.data_dir, "client.csr")), "box", 10)
    File.write!(Config.path(config, :cert), short)
    before = File.read!(Config.path(config, :key))
    assert {:ok, _} = Identity.ensure()

    assert_received {:portal_request, "POST", "/builder/v1/renew", %{"csr_pem" => _}, fp}
                    when is_binary(fp)

    assert File.read!(Config.path(config, :key)) != before
    assert DateTime.diff(Identity.cert_expires_at(), DateTime.utc_now(), :day) > 300
  end
end
