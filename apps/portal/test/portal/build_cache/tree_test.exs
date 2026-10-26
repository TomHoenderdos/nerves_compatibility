defmodule Portal.BuildCache.TreeTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.Tree

  setup do
    dir = Path.join(System.tmp_dir!(), "tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "ebin"))
    File.write!(Path.join(dir, "ebin/Elixir.Jason.beam"), "beam")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "a plain entry passes", %{dir: dir} do
    assert :ok = Tree.check(dir, package: "jason")
    assert :ok = Tree.check(dir, package: :any)
  end

  test "Mix's own priv link passes with the package bound or free", %{dir: dir} do
    File.ln_s!("../../../../deps/jason/priv", Path.join(dir, "priv"))
    assert :ok = Tree.check(dir, package: "jason")
    assert :ok = Tree.check(dir, package: :any)
  end

  test "a priv link to another package fails bound and passes free", %{dir: dir} do
    File.ln_s!("../../../../deps/other/priv", Path.join(dir, "priv"))
    assert {:error, reason} = Tree.check(dir, package: "jason")
    assert reason =~ "priv link"
    assert :ok = Tree.check(dir, package: :any)
  end

  test "any other symlink fails either way", %{dir: dir} do
    File.ln_s!("/etc/passwd", Path.join(dir, "ebin/x"))
    assert {:error, reason} = Tree.check(dir, package: :any)
    assert reason =~ "symlink"
  end

  test "a hardlinked pair fails", %{dir: dir} do
    File.ln!(Path.join(dir, "ebin/Elixir.Jason.beam"), Path.join(dir, "ebin/copy.beam"))
    assert {:error, reason} = Tree.check(dir, package: :any)
    assert reason =~ "hardlinked"
  end

  test "strip_modes/1 drops setuid and group/other write", %{dir: dir} do
    file = Path.join(dir, "ebin/Elixir.Jason.beam")
    File.chmod!(file, 0o4777)
    assert :ok = Tree.strip_modes(dir)
    assert Bitwise.band(File.stat!(file).mode, 0o7777) == 0o755
  end

  test "strip_modes/1 gives the owner back a 0o000 file and directory", %{dir: dir} do
    file = Path.join(dir, "ebin/Elixir.Jason.beam")
    locked = Path.join(dir, "locked")
    File.mkdir_p!(Path.join(locked, "inner"))
    File.chmod!(file, 0o000)
    File.chmod!(locked, 0o000)
    on_exit(fn -> File.chmod(locked, 0o700) end)

    assert :ok = Tree.strip_modes(dir)
    assert Bitwise.band(File.stat!(file).mode, 0o7777) == 0o600
    assert Bitwise.band(File.stat!(locked).mode, 0o7777) == 0o700
    assert File.dir?(Path.join(locked, "inner"))
  end
end
