defmodule Mix.Tasks.Portal.Precompiled.KeygenTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  import ExUnit.CaptureIO

  test "writes signing.key and a self-signed root.json", %{tmp_dir: dir} do
    out = capture_io(fn -> Mix.Tasks.Portal.Precompiled.Keygen.run(["--out", dir]) end)
    assert File.exists?(Path.join(dir, "signing.key"))
    env = dir |> Path.join("root.json") |> File.read!() |> JSON.decode!()
    {:ok, payload} = Portal.Precompiled.Envelope.verify(env, keys_from_root(env), 1)
    assert JSON.decode!(payload)["version"] == 1
    assert out =~ "keyid"
  end

  test "refuses to overwrite an existing key", %{tmp_dir: dir} do
    File.write!(Path.join(dir, "signing.key"), "x")
    assert_raise Mix.Error, fn -> Mix.Tasks.Portal.Precompiled.Keygen.run(["--out", dir]) end
  end

  defp keys_from_root(env) do
    payload = env["payload"] |> Base.url_decode64!(padding: false) |> JSON.decode!()

    Map.new(payload["keys"], fn {kid, %{"public" => pub}} ->
      {kid, Base.url_decode64!(pub, padding: false)}
    end)
  end
end
