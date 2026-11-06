defmodule Compatibility.BuildCache.TreeTest do
  use ExUnit.Case, async: true

  alias Compatibility.BuildCache.Tree

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

  defp mode(path), do: Bitwise.band(File.lstat!(path).mode, 0o7777)

  test "readable_modes/1 makes every dir 0755, a file with an exec bit 0755, the rest 0644",
       %{dir: dir} do
    beam = Path.join(dir, "ebin/Elixir.Jason.beam")
    tool = Path.join(dir, "ebin/tool")
    group_x = Path.join(dir, "ebin/group_x")
    File.write!(tool, "#!/bin/sh\n")
    File.write!(group_x, "x")
    File.chmod!(beam, 0o600)
    File.chmod!(tool, 0o4700)
    File.chmod!(group_x, 0o610)
    File.chmod!(Path.join(dir, "ebin"), 0o700)
    File.ln_s!("../../../../deps/jason/priv", Path.join(dir, "priv"))

    assert :ok = Tree.strip_modes(dir)
    assert :ok = Tree.readable_modes(dir)

    assert mode(dir) == 0o755
    assert mode(Path.join(dir, "ebin")) == 0o755
    assert mode(beam) == 0o644
    assert mode(tool) == 0o755
    assert mode(group_x) == 0o755
    # The link is left alone: chmod would follow it.
    assert File.lstat!(Path.join(dir, "priv")).type == :symlink
  end
end
