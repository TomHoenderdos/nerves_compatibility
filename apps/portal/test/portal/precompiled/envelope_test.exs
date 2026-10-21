defmodule Portal.Precompiled.EnvelopeTest do
  use ExUnit.Case, async: true
  alias Portal.Precompiled.{Envelope, Keys}

  setup do
    key = Keys.generate()
    %{key: key, keys: %{key.keyid => key.public}}
  end

  test "signs and verifies raw payload bytes", %{key: key, keys: keys} do
    env = Envelope.sign(~s({"a":1}), [{key.keyid, key.private}])
    assert %{"payload" => _, "signatures" => [%{"keyid" => kid, "sig" => _}]} = env
    assert kid == key.keyid
    assert {:ok, ~s({"a":1})} = Envelope.verify(env, keys, 1)
    assert {:ok, ~s({"a":1})} = Envelope.verify(JSON.encode!(env), keys, 1)
  end

  test "a tampered payload fails", %{key: key, keys: keys} do
    env = Envelope.sign("hello", [{key.keyid, key.private}])
    tampered = Map.put(env, "payload", Base.url_encode64("hellp", padding: false))
    assert {:error, :below_threshold} = Envelope.verify(tampered, keys, 1)
  end

  test "an unknown keyid does not count toward the threshold", %{key: key} do
    env = Envelope.sign("hello", [{key.keyid, key.private}])
    assert {:error, :below_threshold} = Envelope.verify(env, %{"other" => key.public}, 1)
  end

  test "threshold two needs two distinct valid keys", %{key: key} do
    other = Keys.generate()
    env = Envelope.sign("hello", [{key.keyid, key.private}, {other.keyid, other.private}])
    keys = %{key.keyid => key.public, other.keyid => other.public}
    assert {:ok, "hello"} = Envelope.verify(env, keys, 2)
    dup = Map.update!(env, "signatures", fn [s, _] -> [s, s] end)
    assert {:error, :below_threshold} = Envelope.verify(dup, keys, 2)
  end

  test "garbage is a bad envelope" do
    assert {:error, :bad_envelope} = Envelope.verify("not json", %{}, 1)
    assert {:error, :bad_envelope} = Envelope.verify(%{"payload" => 1}, %{}, 1)
  end
end
