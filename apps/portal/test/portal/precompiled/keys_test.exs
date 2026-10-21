defmodule Portal.Precompiled.KeysTest do
  use ExUnit.Case, async: false
  @moduletag :tmp_dir
  alias Portal.Precompiled.Keys

  setup %{tmp_dir: dir} do
    old = Application.get_env(:portal, :precompiled_signing)
    on_exit(fn -> Application.put_env(:portal, :precompiled_signing, old) end)
    %{path: Path.join(dir, "signing.key")}
  end

  test "keyid is the hex sha256 of the public key" do
    key = Keys.generate()
    assert key.keyid == Base.encode16(:crypto.hash(:sha256, key.public), case: :lower)
    assert byte_size(key.public) == 32 and byte_size(key.private) == 32
  end

  test "write! then load round-trips with mode 0600", %{path: path} do
    key = Keys.generate()
    Keys.write!(path, key)
    assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    assert {:ok, ^key} = Keys.load()
    assert Keys.root_path() == Path.join(Path.dirname(path), "root.json")
  end

  test "load without a configured path is :no_key" do
    Application.put_env(:portal, :precompiled_signing, key_path: nil)
    assert {:error, :no_key} = Keys.load()
    assert Keys.root_path() == nil
  end

  test "load with a missing or corrupt file is :unreadable", %{path: path} do
    Application.put_env(:portal, :precompiled_signing, key_path: path)
    assert {:error, :unreadable} = Keys.load()
    File.write!(path, "{}")
    assert {:error, :unreadable} = Keys.load()
  end
end
