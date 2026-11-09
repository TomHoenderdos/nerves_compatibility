defmodule Portal.Precompiled.RootTest do
  use ExUnit.Case, async: true
  alias Portal.Precompiled.{Envelope, Keys, Root}

  test "payload names the key in both roles at threshold 1" do
    key = Keys.generate()
    payload = Root.payload(key.keyid, key.public, ~U[2027-10-21 00:00:00Z])
    doc = JSON.decode!(payload)
    assert doc["version"] == 1
    assert doc["expires"] == "2027-10-21T00:00:00Z"

    assert doc["keys"][key.keyid] == %{
             "type" => "ed25519",
             "public" => Base.url_encode64(key.public, padding: false)
           }

    assert doc["roles"]["root"] == %{"keyids" => [key.keyid], "threshold" => 1}
    assert doc["roles"]["batch"] == %{"keyids" => [key.keyid], "threshold" => 1}
    env = Envelope.sign(payload, [{key.keyid, key.private}])
    assert {:ok, ^payload} = Envelope.verify(env, %{key.keyid => key.public}, 1)
  end

  test "payload/3 is unchanged: payload/1 with one key in root and batch" do
    k = Keys.generate()
    exp = ~U[2027-01-01 00:00:00Z]

    assert Root.payload(k.keyid, k.public, exp) ==
             Root.payload(%{
               version: 1,
               expires: exp,
               keys: [{k.keyid, k.public}],
               roles: %{"root" => {[k.keyid], 1}, "batch" => {[k.keyid], 1}}
             })
  end

  test "payload/1 writes an offline role with its own key" do
    online = Keys.generate()
    offline = Keys.generate()

    doc =
      Root.payload(%{
        version: 2,
        expires: ~U[2027-11-09 00:00:00Z],
        keys: [{online.keyid, online.public}, {offline.keyid, offline.public}],
        roles: %{
          "root" => {[online.keyid], 1},
          "batch" => {[online.keyid], 1},
          "offline" => {[offline.keyid], 1}
        }
      })
      |> JSON.decode!()

    assert doc["version"] == 2
    assert doc["roles"]["offline"] == %{"keyids" => [offline.keyid], "threshold" => 1}
    assert Map.keys(doc["keys"]) |> Enum.sort() == Enum.sort([online.keyid, offline.keyid])
  end

  test "a root with an offline role conforms to RootPayload, and a bad role does not" do
    online = Keys.generate()
    offline = Keys.generate()

    doc =
      Root.payload(%{
        version: 2,
        expires: ~U[2027-11-09 00:00:00Z],
        keys: [{online.keyid, online.public}, {offline.keyid, offline.public}],
        roles: %{
          "root" => {[online.keyid], 1},
          "batch" => {[online.keyid], 1},
          "offline" => {[offline.keyid], 1}
        }
      })
      |> JSON.decode!()

    PortalWeb.ApiSpecAssertions.assert_api_schema(doc, "RootPayload")

    assert_raise ExUnit.AssertionError, fn ->
      doc
      |> put_in(["roles", "offline", "threshold"], 0)
      |> PortalWeb.ApiSpecAssertions.assert_api_schema("RootPayload")
    end
  end

  describe "verify_self/1 and follows/2" do
    test "a root that verifies under its own root role, and one that does not" do
      key = Keys.generate()
      other = Keys.generate()
      payload = Root.payload(key.keyid, key.public, ~U[2030-01-01 00:00:00Z])

      assert {:ok, %{"version" => 1}, ^payload} =
               Root.verify_self(JSON.encode!(Envelope.sign(payload, [{key.keyid, key.private}])))

      assert :error = Root.verify_self(Envelope.sign(payload, [{other.keyid, other.private}]))
      assert :error = Root.verify_self("not json")
    end

    test "a newer root follows only when the current root role signed it too" do
      key = Keys.generate()
      next = Keys.generate()
      current = JSON.decode!(Root.payload(key.keyid, key.public, ~U[2030-01-01 00:00:00Z]))

      v2 =
        Root.payload(%{
          version: 2,
          expires: ~U[2020-01-01 00:00:00Z],
          keys: [{next.keyid, next.public}],
          roles: %{"root" => {[next.keyid], 1}, "batch" => {[next.keyid], 1}}
        })

      both = Envelope.sign(v2, [{key.keyid, key.private}, {next.keyid, next.private}])
      only_new = Envelope.sign(v2, [{next.keyid, next.private}])

      # Expiry is not part of the chain: v2 expired in 2020 and still follows.
      assert {:ok, %{"version" => 2}, ^v2} = Root.follows(both, current)
      assert :error = Root.follows(only_new, current)
      assert :error = Root.follows(both, %{current | "version" => 2})
    end
  end
end
