defmodule Portal.Builders.EnrolmentTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Builders
  alias Portal.Builders.{Builder, BuilderCertificate, CA}

  setup do
    dir = Path.join(System.tmp_dir!(), "ncc-ca-#{System.unique_integer([:positive])}")
    key_path = Path.join(dir, "ca-key.pem")
    previous = Application.get_env(:portal, CA, [])
    Application.put_env(:portal, CA, Keyword.put(previous, :key_path, key_path))
    {:ok, _} = CA.init(key_path)

    on_exit(fn ->
      Application.put_env(:portal, CA, previous)
      File.rm_rf(dir)
    end)

    :ok
  end

  defp csr, do: X509.CSR.new(X509.PrivateKey.new_ec(:secp256r1), "/CN=x") |> X509.CSR.to_pem()

  test "a token is shown once, enrols once, and names the CA" do
    {:ok, %{token: token}} = Builders.create_token("box-a", "admin")
    [id, secret, prefix] = String.split(token, ".")
    assert String.length(prefix) == 16
    assert byte_size(Base.url_decode64!(secret, padding: false)) == 32
    {:ok, %{cert: ca}} = CA.load()
    assert prefix == CA.prefix(ca)

    assert {:ok, %{builder: builder, cert_pem: pem, expires_at: expires}} =
             Builders.enrol(token, csr(), %{agent_version: "1.a", slots: 2})

    assert builder.name == "box-a" and builder.publishing == false and builder.slots == 2
    assert builder.fingerprint == CA.fingerprint(X509.Certificate.from_pem!(pem))
    assert DateTime.diff(expires, DateTime.utc_now(), :day) in 364..366

    assert [%BuilderCertificate{superseded_at: nil}] =
             Ash.load!(builder, :certificates, domain: Builders).certificates

    assert {:error, :token_used} = Builders.enrol(token, csr(), %{})
    assert {:error, :invalid_token} = Builders.enrol("nope.nope.nope", csr(), %{})
    assert {:error, :invalid_token} = Builders.enrol("#{id}.AAAA.#{prefix}", csr(), %{})
  end

  test "a token is refused for a name the CA would refuse" do
    assert {:error, :invalid_name} = Builders.create_token("bad name/../", "admin")
  end

  test "an expired token is refused" do
    {:ok, %{token: token, record: record}} = Builders.create_token("box-b", "admin")
    record |> Ash.Changeset.for_update(:expire_now, %{}) |> Ash.update!(domain: Builders)
    assert {:error, :token_expired} = Builders.enrol(token, csr(), %{})
  end

  test "a second token for the same name cannot enrol while the first builder exists" do
    {:ok, %{token: t1}} = Builders.create_token("box-c", "admin")
    {:ok, _} = Builders.enrol(t1, csr(), %{})
    {:ok, %{token: t2}} = Builders.create_token("box-c", "admin")
    assert {:error, :name_taken} = Builders.enrol(t2, csr(), %{})
  end

  test "lookup by fingerprint honours current, superseded-within-24h and revoked" do
    {:ok, %{token: token}} = Builders.create_token("box-d", "admin")
    {:ok, %{builder: builder}} = Builders.enrol(token, csr(), %{})
    assert {:ok, %Builder{id: id}} = Builders.by_fingerprint(builder.fingerprint)
    assert id == builder.id
    assert {:error, :unknown} = Builders.by_fingerprint("nope")

    assert {:error, :too_early} = Builders.renew(builder, csr())

    near =
      builder
      |> Ash.Changeset.for_update(:rotate_cert, %{
        cert_expires_at: DateTime.add(DateTime.utc_now(), 10, :day),
        fingerprint: builder.fingerprint,
        cert_pem: builder.cert_pem
      })
      |> Ash.update!(domain: Builders)

    assert {:ok, %{cert_pem: new_pem}} = Builders.renew(near, csr())
    new_fp = CA.fingerprint(X509.Certificate.from_pem!(new_pem))
    assert {:ok, %Builder{fingerprint: ^new_fp}} = Builders.by_fingerprint(new_fp)
    assert {:ok, %Builder{}} = Builders.by_fingerprint(builder.fingerprint)

    old =
      BuilderCertificate
      |> Ash.Query.filter(fingerprint == ^builder.fingerprint)
      |> Ash.read_one!(domain: Builders)

    old
    |> Ash.Changeset.for_update(:update_superseded_at, %{
      superseded_at: DateTime.add(DateTime.utc_now(), -25, :hour)
    })
    |> Ash.update!(domain: Builders)

    assert {:error, :unknown} = Builders.by_fingerprint(builder.fingerprint)

    {:ok, _} = Builders.revoke(near)
    assert {:error, :revoked} = Builders.by_fingerprint(new_fp)

    assert {:error, :revoked} =
             Builders.renew(Ash.get!(Builder, builder.id, domain: Builders), csr())
  end

  test "touch writes last_seen_at at most once a minute" do
    {:ok, %{token: token}} = Builders.create_token("box-e", "admin")
    {:ok, %{builder: builder}} = Builders.enrol(token, csr(), %{})
    first = Builders.touch(builder, "1.a")
    assert %DateTime{} = first.last_seen_at
    second = Builders.touch(first, "1.a")
    assert second.last_seen_at == first.last_seen_at

    stale =
      first
      |> Ash.Changeset.for_update(:touch, %{
        last_seen_at: DateTime.add(DateTime.utc_now(), -120, :second)
      })
      |> Ash.update!(domain: Builders)

    assert DateTime.compare(Builders.touch(stale, "1.b").last_seen_at, stale.last_seen_at) == :gt
    assert Builders.touch(stale, "1.b").last_version == "1.b"
  end
end
