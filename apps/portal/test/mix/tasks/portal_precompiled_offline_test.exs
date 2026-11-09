defmodule Mix.Tasks.Portal.PrecompiledOfflineTest do
  use ExUnit.Case, async: false
  alias Mix.Tasks.Portal.Precompiled.{OfflineKeygen, RootRotate, SignOffline}
  alias Portal.Precompiled.{Envelope, Keys, Offline, Root}

  @moduletag :tmp_dir

  @manifest ~s({"format":2,"versions":{}})

  setup %{tmp_dir: dir} do
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)

    online = Keys.generate()
    Keys.write!(Path.join(dir, "signing.key"), online)
    root1 = Root.payload(online.keyid, online.public, ~U[2030-01-01 00:00:00Z])
    write_env!(Path.join(dir, "root.json"), root1, [online])
    %{online: online}
  end

  test "keygen, rotate and sign make an offline.json the rotated root verifies",
       %{tmp_dir: dir, online: online} do
    public = keygen!(dir)
    assert File.stat!(Path.join(dir, "off/offline.key")).mode |> Bitwise.band(0o777) == 0o600

    rotate!(dir, public)
    assert_received {:mix_shell, :info, ["wrote " <> _]}

    env2 = dir |> Path.join("root2.json") |> File.read!() |> JSON.decode!()
    # Chains from root 1: signed by the key root 1's root role names.
    assert {:ok, payload2} = Envelope.verify(env2, %{online.keyid => online.public}, 1)
    root2 = JSON.decode!(payload2)
    assert root2["version"] == 2
    assert [offline_id] = root2["roles"]["offline"]["keyids"]
    assert root2["roles"]["batch"] == %{"keyids" => [online.keyid], "threshold" => 1}
    assert root2["roles"]["root"] == %{"keyids" => [online.keyid], "threshold" => 1}

    bundle = make_bundle!(dir, online, "root2.json")

    SignOffline.run([
      "--bundle",
      bundle,
      "--key",
      Path.join(dir, "off/offline.key"),
      "--root",
      Path.join(dir, "root2.json")
    ])

    assert_received {:mix_shell, :info, ["offline.json sequence " <> _]}
    {:ok, off_public} = Base.url_decode64(public, padding: false)
    off_env = bundle |> Path.join("offline.json") |> File.read!() |> JSON.decode!()
    assert {:ok, off_payload} = Envelope.verify(off_env, %{offline_id => off_public}, 1)
    assert %{"kind" => "offline"} = JSON.decode!(off_payload)
    assert {:ok, _} = Offline.verify(off_env, root2)
    # The online key alone does not make an offline document.
    assert {:error, :below_threshold} =
             Envelope.verify(off_env, %{online.keyid => online.public}, 1)
  end

  test "a device trusting root 1 is served by a bundle that carries root 2",
       %{tmp_dir: dir, online: online} do
    public = keygen!(dir)
    rotate!(dir, public)
    bundle = make_bundle!(dir, online, "root2.json")

    # --root is the root the device already trusts; the bundle's root chains from it.
    SignOffline.run([
      "--bundle",
      bundle,
      "--key",
      Path.join(dir, "off/offline.key"),
      "--root",
      Path.join(dir, "root.json")
    ])

    assert File.exists?(Path.join(bundle, "offline.json"))
  end

  test "an expired batch under an expired root still gets a valid offline.json",
       %{tmp_dir: dir, online: online} do
    public = keygen!(dir)

    RootRotate.run([
      "--root",
      Path.join(dir, "root.json"),
      "--key",
      Path.join(dir, "signing.key"),
      "--offline-public=" <> public,
      "--out",
      Path.join(dir, "root2.json"),
      "--years",
      "0"
    ])

    bundle = make_bundle!(dir, online, "root2.json", "2020-01-08T00:00:00Z")

    SignOffline.run([
      "--bundle",
      bundle,
      "--key",
      Path.join(dir, "off/offline.key"),
      "--root",
      Path.join(dir, "root2.json")
    ])

    assert_received {:mix_shell, :info, ["note: the root in use (version 2) expired at " <> _]}
    {:ok, root2, _} = dir |> Path.join("root2.json") |> File.read!() |> Root.verify_self()
    off_env = bundle |> Path.join("offline.json") |> File.read!() |> JSON.decode!()
    assert {:ok, %{"manifests_v2" => %{"recon" => _}}} = Offline.verify(off_env, root2)
  end

  test "sign_offline needs --root", %{tmp_dir: dir, online: online} do
    public = keygen!(dir)
    rotate!(dir, public)
    bundle = make_bundle!(dir, online, "root2.json")

    assert_raise Mix.Error, ~r/--root FILE is required/, fn ->
      SignOffline.run(["--bundle", bundle, "--key", Path.join(dir, "off/offline.key")])
    end

    refute File.exists?(Path.join(bundle, "offline.json"))
  end

  test "sign_offline refuses a bundle whose root is not the trusted one",
       %{tmp_dir: dir, online: online} do
    public = keygen!(dir)
    rotate!(dir, public)
    {:ok, off_public} = Base.url_decode64(public, padding: false)

    # A self-signed root that names the real offline key, so the operator's
    # key would sign it; only the trusted root tells it apart.
    evil = Keys.generate()

    forged =
      Root.payload(%{
        version: 3,
        expires: ~U[2030-01-01 00:00:00Z],
        keys: [{evil.keyid, evil.public}, {Keys.keyid(off_public), off_public}],
        roles: %{
          "root" => {[evil.keyid], 1},
          "batch" => {[evil.keyid], 1},
          "offline" => {[Keys.keyid(off_public)], 1}
        }
      })

    write_env!(Path.join(dir, "forged.json"), forged, [evil])
    bundle = make_bundle!(dir, evil, "forged.json")

    assert_raise Mix.Error, ~r/does not chain from the trusted root/, fn ->
      SignOffline.run([
        "--bundle",
        bundle,
        "--key",
        Path.join(dir, "off/offline.key"),
        "--root",
        Path.join(dir, "root2.json")
      ])
    end

    refute File.exists?(Path.join(bundle, "offline.json"))
    _ = online
  end

  test "sign_offline refuses a key outside the offline role", %{tmp_dir: dir, online: online} do
    public = keygen!(dir)
    rotate!(dir, public)
    bundle = make_bundle!(dir, online, "root2.json")

    assert_raise Mix.Error, ~r/is not an offline key of the root in use/, fn ->
      SignOffline.run([
        "--bundle",
        bundle,
        "--key",
        Path.join(dir, "signing.key"),
        "--root",
        Path.join(dir, "root2.json")
      ])
    end

    refute File.exists?(Path.join(bundle, "offline.json"))
  end

  test "sign_offline refuses a root without an offline role", %{tmp_dir: dir, online: online} do
    keygen!(dir)
    bundle = make_bundle!(dir, online, "root.json")

    assert_raise Mix.Error, ~r/has no offline role/, fn ->
      SignOffline.run([
        "--bundle",
        bundle,
        "--key",
        Path.join(dir, "off/offline.key"),
        "--root",
        Path.join(dir, "root.json")
      ])
    end
  end

  test "keygen refuses to overwrite an offline key", %{tmp_dir: dir} do
    keygen!(dir)

    assert_raise Mix.Error, ~r/refusing to overwrite/, fn ->
      OfflineKeygen.run(["--out", Path.join(dir, "off")])
    end
  end

  test "rotate refuses a key that is not in the current root role", %{tmp_dir: dir} do
    stranger = Keys.generate()
    Keys.write!(Path.join(dir, "stranger.key"), stranger)
    other = Keys.generate()

    assert_raise Mix.Error, ~r/not a root key/, fn ->
      RootRotate.run([
        "--root",
        Path.join(dir, "root.json"),
        "--key",
        Path.join(dir, "stranger.key"),
        "--offline-public=" <> Base.url_encode64(other.public, padding: false),
        "--out",
        Path.join(dir, "x.json")
      ])
    end

    refute File.exists?(Path.join(dir, "x.json"))
  end

  test "rotate refuses an offline key the root already names", %{tmp_dir: dir, online: online} do
    assert_raise Mix.Error, ~r/must be its own key/, fn ->
      rotate!(dir, Base.url_encode64(online.public, padding: false))
    end
  end

  test "rotate takes a public key that starts with a dash in the = form", %{tmp_dir: dir} do
    key = Stream.repeatedly(&Keys.generate/0) |> Enum.find(&dashed?/1)
    rotate!(dir, Base.url_encode64(key.public, padding: false))
    assert_received {:mix_shell, :info, ["root version 2, offline keyid " <> id]}
    assert id == key.keyid
  end

  test "rotate refuses a public key that is not 32 bytes", %{tmp_dir: dir} do
    assert_raise Mix.Error, ~r/32-byte/, fn -> rotate!(dir, "abcd") end
  end

  test "rotate refuses a current root that does not verify under itself", %{tmp_dir: dir} do
    other = Keys.generate()
    key = Keys.generate()

    write_env!(
      Path.join(dir, "root.json"),
      Root.payload(key.keyid, key.public, ~U[2030-01-01 00:00:00Z]),
      [other]
    )

    assert_raise Mix.Error, ~r/does not verify under itself/, fn ->
      rotate!(dir, Base.url_encode64(Keys.generate().public, padding: false))
    end
  end

  test "rotating again replaces the offline key", %{tmp_dir: dir, online: online} do
    first = keygen!(dir)
    rotate!(dir, first)
    second = Keys.generate()

    RootRotate.run([
      "--root",
      Path.join(dir, "root2.json"),
      "--key",
      Path.join(dir, "signing.key"),
      "--offline-public=" <> Base.url_encode64(second.public, padding: false),
      "--out",
      Path.join(dir, "root3.json")
    ])

    env3 = dir |> Path.join("root3.json") |> File.read!() |> JSON.decode!()
    {:ok, payload3} = Envelope.verify(env3, %{online.keyid => online.public}, 1)
    root3 = JSON.decode!(payload3)
    assert root3["version"] == 3
    assert root3["roles"]["offline"]["keyids"] == [second.keyid]
    assert Map.keys(root3["keys"]) |> Enum.sort() == Enum.sort([online.keyid, second.keyid])
  end

  defp keygen!(dir) do
    OfflineKeygen.run(["--out", Path.join(dir, "off")])
    assert_received {:mix_shell, :info, ["public: " <> public]}
    public
  end

  defp rotate!(dir, public) do
    RootRotate.run([
      "--root",
      Path.join(dir, "root.json"),
      "--key",
      Path.join(dir, "signing.key"),
      "--offline-public=" <> public,
      "--out",
      Path.join(dir, "root2.json")
    ])
  end

  defp dashed?(key), do: String.starts_with?(Base.url_encode64(key.public, padding: false), "-")

  defp write_env!(path, payload, signers) do
    File.write!(
      path,
      JSON.encode!(Envelope.sign(payload, Enum.map(signers, &{&1.keyid, &1.private})))
    )
  end

  # A bundle: the named root as root.json, a batch signed by `key`, one manifest.
  defp make_bundle!(dir, key, root_file, expires \\ "2026-11-16T00:00:00Z") do
    b = Path.join(dir, "bundle")
    File.mkdir_p!(Path.join(b, "v2/manifests"))
    File.cp!(Path.join(dir, root_file), Path.join(b, "root.json"))
    File.write!(Path.join(b, "v2/manifests/recon.json"), @manifest)
    sha = Base.encode16(:crypto.hash(:sha256, @manifest), case: :lower)

    batch =
      JSON.encode!(%{
        "version" => 1,
        "sequence" => 1,
        "issued" => "2026-11-09T00:00:00Z",
        "expires" => expires,
        "manifests" => %{},
        "manifests_v2" => %{"recon" => sha}
      })

    write_env!(Path.join(b, "batch.json"), batch, [key])
    b
  end
end
