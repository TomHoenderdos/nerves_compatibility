defmodule Portal.Precompiled.OfflineTest do
  use ExUnit.Case, async: true
  alias Portal.Precompiled.{Envelope, Keys, Offline, Root}

  @moduletag :tmp_dir

  @manifest ~s({"format":2,"versions":{}})

  setup %{tmp_dir: dir} do
    key = Keys.generate()
    root = signed_root(1, ~U[2030-01-01 00:00:00Z], [key], [key])
    File.write!(Path.join(dir, "root.json"), root)
    File.mkdir_p!(Path.join(dir, "v2/manifests"))
    File.write!(Path.join(dir, "v2/manifests/recon.json"), @manifest)
    sha = sha256(@manifest)
    write_batch!(dir, key, %{"manifests" => %{}, "manifests_v2" => %{"recon" => sha}})
    %{key: key, sha: sha, trusted: root}
  end

  describe "check_bundle/2" do
    test "a verified bundle yields its batch payload", %{tmp_dir: dir, sha: sha, trusted: t} do
      assert {:ok, %{batch: %{"manifests_v2" => %{"recon" => ^sha}}, root: %{"version" => 1}}} =
               Offline.check_bundle(dir, t)
    end

    test "a manifest that does not hash to the batch's sha is refused",
         %{tmp_dir: dir, trusted: t} do
      File.write!(Path.join(dir, "v2/manifests/recon.json"), ~s({"format":2}))
      assert {:error, "manifest recon does not match the batch"} = Offline.check_bundle(dir, t)
    end

    test "a batch signed by another key is refused", %{tmp_dir: dir, trusted: t} do
      other = Keys.generate()
      write_batch!(dir, other, %{"manifests_v2" => %{}})

      assert {:error, "batch.json does not verify under the trusted root"} =
               Offline.check_bundle(dir, t)
    end

    test "a forged self-signed root in the bundle is refused", %{tmp_dir: dir, trusted: t} do
      # The attacker brings a root, batch and manifests that all agree with
      # each other; only the trusted root can tell them apart.
      evil = Keys.generate()

      File.write!(
        Path.join(dir, "root.json"),
        signed_root(2, ~U[2030-01-01 00:00:00Z], [evil], [evil])
      )

      write_batch!(dir, evil, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      assert {:error, "bundle root.json does not chain from the trusted root"} =
               Offline.check_bundle(dir, t)
    end

    test "a forged root of the trusted version is refused", %{tmp_dir: dir, trusted: t} do
      evil = Keys.generate()

      File.write!(
        Path.join(dir, "root.json"),
        signed_root(1, ~U[2030-01-01 00:00:00Z], [evil], [evil])
      )

      write_batch!(dir, evil, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      assert {:error, "bundle root.json does not chain from the trusted root"} =
               Offline.check_bundle(dir, t)
    end

    test "a newer root signed by its own keys only does not chain", %{tmp_dir: dir, trusted: t} do
      next = Keys.generate()

      File.write!(
        Path.join(dir, "root.json"),
        signed_root(2, ~U[2030-01-01 00:00:00Z], [next], [next])
      )

      assert {:error, "bundle root.json does not chain from the trusted root"} =
               Offline.check_bundle(dir, t)
    end

    test "a newer bundle root that follows is accepted, but trust stays with the trusted root",
         %{tmp_dir: dir, key: key, trusted: t} do
      next = Keys.generate()

      File.write!(
        Path.join(dir, "root.json"),
        signed_root(2, ~U[2030-01-01 00:00:00Z], [next], [key, next])
      )

      # The batch verifies under the trusted root's batch role, not the bundle's.
      assert {:ok, %{root: %{"version" => 1}}} = Offline.check_bundle(dir, t)

      write_batch!(dir, next, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      assert {:error, "batch.json does not verify under the trusted root"} =
               Offline.check_bundle(dir, t)
    end

    test "a stale trusted root: a root forged by a key it still lists signs nothing",
         %{tmp_dir: dir} do
      # v1 trusts k_old; v2 (current) replaced it. Whoever kept k_old forges a
      # v99 that follows v1, delegates the real offline key, and signs a batch.
      k_old = Keys.generate()
      offline = Keys.generate()
      v1 = root_env(1, %{root: [k_old], batch: [k_old]}, [k_old])

      v99 =
        root_env(99, %{root: [k_old], batch: [k_old], offline: [offline]}, [k_old])

      File.write!(Path.join(dir, "root.json"), v99)
      write_batch!(dir, k_old, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      # The bundle root follows v1, but the root in use is v1, which has no
      # offline role: the attacker's delegation counts for nothing.
      assert {:ok, %{root: root}} = Offline.check_bundle(dir, v1)
      assert root["version"] == 1
      assert :error = Root.role_keys(root, "offline")
    end

    test "a forged root that follows a revoked root does not follow the current one",
         %{tmp_dir: dir} do
      k_old = Keys.generate()
      k_new = Keys.generate()
      offline = Keys.generate()
      v2 = root_env(2, %{root: [k_new], batch: [k_new], offline: [offline]}, [k_old, k_new])
      v99 = root_env(99, %{root: [k_old], batch: [k_old], offline: [offline]}, [k_old])
      File.write!(Path.join(dir, "root.json"), v99)
      write_batch!(dir, k_old, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      assert {:error, "bundle root.json does not chain from the trusted root"} =
               Offline.check_bundle(dir, v2)
    end

    test "a newer root signed only by the batch-role key does not chain", %{tmp_dir: dir} do
      r = Keys.generate()
      b = Keys.generate()
      trusted = root_env(1, %{root: [r], batch: [b]}, [r])
      next = Keys.generate()

      File.write!(
        Path.join(dir, "root.json"),
        root_env(2, %{root: [next], batch: [b]}, [b, next])
      )

      assert {:error, "bundle root.json does not chain from the trusted root"} =
               Offline.check_bundle(dir, trusted)
    end

    test "a batch signed only by the root-role key is refused", %{tmp_dir: dir} do
      r = Keys.generate()
      b = Keys.generate()
      trusted = root_env(1, %{root: [r], batch: [b]}, [r])
      File.write!(Path.join(dir, "root.json"), trusted)
      write_batch!(dir, r, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})

      assert {:error, "batch.json does not verify under the trusted root"} =
               Offline.check_bundle(dir, trusted)

      write_batch!(dir, b, %{"manifests_v2" => %{"recon" => sha256(@manifest)}})
      assert {:ok, _} = Offline.check_bundle(dir, trusted)
    end

    test "a format-1 manifest that does not hash to the batch's sha is refused",
         %{tmp_dir: dir, key: key, sha: sha, trusted: t} do
      File.mkdir_p!(Path.join(dir, "manifests"))
      File.write!(Path.join(dir, "manifests/recon.json"), ~s({"versions":{"x":1}}))

      write_batch!(dir, key, %{
        "manifests" => %{"recon" => sha256(~s({"versions":{}}))},
        "manifests_v2" => %{"recon" => sha}
      })

      assert {:error, "format-1 manifest recon does not match the batch"} =
               Offline.check_bundle(dir, t)
    end

    test "a bundle root older than the trusted root is refused", %{tmp_dir: dir, key: key} do
      trusted = signed_root(2, ~U[2030-01-01 00:00:00Z], [key], [key])

      assert {:error, "bundle root.json version 1 is older than the trusted root (2)"} =
               Offline.check_bundle(dir, trusted)
    end

    test "a trusted root that does not verify under itself is refused", %{tmp_dir: dir, key: key} do
      other = Keys.generate()
      payload = Root.payload(key.keyid, key.public, ~U[2030-01-01 00:00:00Z])
      bad = JSON.encode!(Envelope.sign(payload, [{other.keyid, other.private}]))

      assert {:error, "the trusted root does not verify under itself"} =
               Offline.check_bundle(dir, bad)
    end

    test "only the manifests present in the bundle are kept", %{
      tmp_dir: dir,
      key: key,
      sha: sha,
      trusted: t
    } do
      v1 = ~s({"versions":{}})
      File.mkdir_p!(Path.join(dir, "manifests"))
      File.write!(Path.join(dir, "manifests/recon.json"), v1)

      write_batch!(dir, key, %{
        "manifests" => %{"recon" => sha256(v1), "jason" => String.duplicate("a", 64)},
        "manifests_v2" => %{"recon" => sha, "jason" => String.duplicate("b", 64)}
      })

      assert {:ok, %{batch: batch}} = Offline.check_bundle(dir, t)
      assert batch["manifests"] == %{"recon" => sha256(v1)}
      assert batch["manifests_v2"] == %{"recon" => sha}
    end

    test "a package name that is not a plain name is never read", %{
      tmp_dir: dir,
      key: key,
      sha: sha,
      trusted: t
    } do
      File.write!(Path.join(dir, "outside.json"), @manifest)

      write_batch!(dir, key, %{
        "manifests_v2" => %{"recon" => sha, "../../outside" => sha256(@manifest)}
      })

      assert {:ok, %{batch: %{"manifests_v2" => v2}}} = Offline.check_bundle(dir, t)
      assert v2 == %{"recon" => sha}
    end

    test "a bundle that holds none of the batch's manifests is refused",
         %{tmp_dir: dir, trusted: t} do
      File.rm!(Path.join(dir, "v2/manifests/recon.json"))

      assert {:error, "the bundle holds none of the batch's manifests"} =
               Offline.check_bundle(dir, t)
    end

    test "an expired batch still yields its manifests", %{
      tmp_dir: dir,
      key: key,
      sha: sha,
      trusted: t
    } do
      write_batch!(dir, key, %{"manifests_v2" => %{"recon" => sha}}, "2020-01-08T00:00:00Z")

      assert {:ok, %{batch: %{"manifests_v2" => %{"recon" => ^sha}}}} =
               Offline.check_bundle(dir, t)
    end

    test "a missing root.json is refused", %{tmp_dir: dir, trusted: t} do
      File.rm!(Path.join(dir, "root.json"))

      assert {:error, "bundle root.json is missing or not an envelope"} =
               Offline.check_bundle(dir, t)
    end
  end

  describe "payload/3" do
    test "the offline payload has no expiry and names the batch's manifests", %{sha: sha} do
      doc =
        Offline.payload(
          %{"manifests" => %{}, "manifests_v2" => %{"recon" => sha}},
          1_762_646_400,
          ~U[2026-11-09 00:00:00Z]
        )
        |> JSON.decode!()

      assert doc["kind"] == "offline"
      assert doc["version"] == 1
      assert doc["sequence"] == 1_762_646_400
      assert doc["issued"] == "2026-11-09T00:00:00Z"
      refute Map.has_key?(doc, "expires")
      assert doc["manifests"] == %{}
      assert doc["manifests_v2"] == %{"recon" => sha}

      assert Map.keys(doc) |> Enum.sort() ==
               ~w(issued kind manifests manifests_v2 sequence version)
    end
  end

  describe "verify/2" do
    setup %{key: key} do
      offline = Keys.generate()
      root = root_map(2, "2020-01-01T00:00:00Z", key, offline)
      %{offline: offline, root: root}
    end

    test "an offline document signed by the offline role verifies, even under an expired root",
         %{offline: offline, root: root, sha: sha} do
      env = offline_env(offline, sha)

      assert {:ok, %{"kind" => "offline", "manifests_v2" => %{"recon" => ^sha}}} =
               Offline.verify(env, root)
    end

    test "an offline document signed by the online key is refused",
         %{key: key, root: root, sha: sha} do
      env = offline_env(key, sha)

      assert {:error, "offline.json does not verify under the root's offline role"} =
               Offline.verify(env, root)
    end

    test "a root without an offline role verifies no offline document",
         %{key: key, offline: offline, sha: sha} do
      root = JSON.decode!(Root.payload(key.keyid, key.public, ~U[2030-01-01 00:00:00Z]))

      assert {:error, "the root has no offline role"} =
               Offline.verify(offline_env(offline, sha), root)
    end

    test "a signed document of another kind is refused", %{offline: offline, root: root} do
      env = Envelope.sign(JSON.encode!(%{"kind" => "batch"}), [{offline.keyid, offline.private}])
      assert {:error, "offline.json is not an offline document"} = Offline.verify(env, root)
    end
  end

  defp offline_env(key, sha) do
    payload = Offline.payload(%{"manifests_v2" => %{"recon" => sha}}, 1, ~U[2026-11-09 00:00:00Z])
    Envelope.sign(payload, [{key.keyid, key.private}])
  end

  defp root_map(version, expires, online, offline) do
    {:ok, exp, 0} = DateTime.from_iso8601(expires)

    Root.payload(%{
      version: version,
      expires: exp,
      keys: [{online.keyid, online.public}, {offline.keyid, offline.public}],
      roles: %{
        "root" => {[online.keyid], 1},
        "batch" => {[online.keyid], 1},
        "offline" => {[offline.keyid], 1}
      }
    })
    |> JSON.decode!()
  end

  # A root envelope whose root and batch roles name `role_keys`, signed by `signers`.
  defp signed_root(version, expires, role_keys, signers) do
    ids = Enum.map(role_keys, & &1.keyid)

    payload =
      Root.payload(%{
        version: version,
        expires: expires,
        keys: Enum.map(role_keys, &{&1.keyid, &1.public}),
        roles: %{"root" => {ids, 1}, "batch" => {ids, 1}}
      })

    JSON.encode!(Envelope.sign(payload, Enum.map(signers, &{&1.keyid, &1.private})))
  end

  # A root envelope with a key set per role (`root`, `batch`, `offline` when
  # given), signed by `signers`.
  defp root_env(version, roles, signers) do
    keys = roles |> Map.values() |> List.flatten() |> Enum.uniq_by(& &1.keyid)

    payload =
      Root.payload(%{
        version: version,
        expires: ~U[2030-01-01 00:00:00Z],
        keys: Enum.map(keys, &{&1.keyid, &1.public}),
        roles:
          Map.new(roles, fn {name, ks} -> {to_string(name), {Enum.map(ks, & &1.keyid), 1}} end)
      })

    JSON.encode!(Envelope.sign(payload, Enum.map(signers, &{&1.keyid, &1.private})))
  end

  defp write_batch!(dir, key, maps, expires \\ "2026-11-16T00:00:00Z") do
    batch =
      JSON.encode!(
        Map.merge(
          %{
            "version" => 1,
            "sequence" => 7,
            "issued" => "2026-11-09T00:00:00Z",
            "expires" => expires,
            "manifests" => %{}
          },
          maps
        )
      )

    File.write!(
      Path.join(dir, "batch.json"),
      JSON.encode!(Envelope.sign(batch, [{key.keyid, key.private}]))
    )
  end

  defp sha256(b), do: Base.encode16(:crypto.hash(:sha256, b), case: :lower)
end
