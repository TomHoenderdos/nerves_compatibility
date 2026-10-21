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
end
