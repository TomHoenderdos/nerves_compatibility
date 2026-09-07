defmodule NccWorker.HexHomeTest do
  use ExUnit.Case, async: false

  alias NccWorker.HexHome

  setup do
    root = Path.join(System.tmp_dir!(), "ncc-hex-#{System.unique_integer([:positive])}")
    shared = Path.join(root, "shared")
    project = Path.join(root, "proj")
    File.mkdir_p!(shared)
    File.mkdir_p!(project)

    previous = System.get_env("HEX_HOME")
    System.put_env("HEX_HOME", shared)

    on_exit(fn ->
      if previous, do: System.put_env("HEX_HOME", previous), else: System.delete_env("HEX_HOME")
      File.rm_rf(root)
    end)

    {:ok, shared: shared, project: project}
  end

  test "gives each target its own registry seeded from the shared one", c do
    File.write!(Path.join(c.shared, "cache.ets"), "registry-v1")

    a = HexHome.prepare(c.project, "rpi4")
    b = HexHome.prepare(c.project, "x86_64")

    refute a == b
    assert File.read!(Path.join(a, "cache.ets")) == "registry-v1"
    assert File.read!(Path.join(b, "cache.ets")) == "registry-v1"

    # The whole point: one writer per file, so a write in one target cannot be
    # what the other target is reading.
    File.write!(Path.join(a, "cache.ets"), "registry-v2")
    assert File.read!(Path.join(b, "cache.ets")) == "registry-v1"
  end

  test "shares the tarball directory by symlink", c do
    dir = HexHome.prepare(c.project, "rpi4")
    link = Path.join(dir, "packages")

    assert {:ok, target} = File.read_link(link)
    assert Path.expand(target) == Path.expand(Path.join(c.shared, "packages"))

    File.write!(Path.join(link, "foo-1.0.0.tar"), "tarball")
    assert File.exists?(Path.join([c.shared, "packages", "foo-1.0.0.tar"]))
  end

  test "carries hex.config over when there is one", c do
    File.write!(Path.join(c.shared, "hex.config"), "cfg")
    dir = HexHome.prepare(c.project, "rpi4")
    assert File.read!(Path.join(dir, "hex.config")) == "cfg"
  end

  test "publish replaces the shared registry", c do
    File.write!(Path.join(c.shared, "cache.ets"), "old")
    dir = HexHome.prepare(c.project, "rpi4")
    File.write!(Path.join(dir, "cache.ets"), "new")

    assert :ok = HexHome.publish(dir)
    assert File.read!(Path.join(c.shared, "cache.ets")) == "new"
  end

  test "publish leaves no temporary files behind", c do
    dir = HexHome.prepare(c.project, "rpi4")
    File.write!(Path.join(dir, "cache.ets"), "new")
    HexHome.publish(dir)

    assert Enum.sort(File.ls!(c.shared)) == ["cache.ets", "packages"]
  end

  test "publish is a no-op without a private home or a registry to publish", c do
    assert :ok = HexHome.publish(nil)

    dir = HexHome.prepare(c.project, "rpi4")
    assert :ok = HexHome.publish(dir)
    refute File.exists?(Path.join(c.shared, "cache.ets"))
  end

  test "falls back to the ambient HEX_HOME when there is no shared cache", c do
    System.delete_env("HEX_HOME")
    assert HexHome.prepare(c.project, "rpi4") == nil

    System.put_env("HEX_HOME", Path.join(c.project, "does-not-exist"))
    assert HexHome.prepare(c.project, "rpi4") == nil
  end

  test "refuses to shadow the shared directory with itself", c do
    # A project directory that happens to resolve to the shared root would
    # otherwise have the build seeding a file from itself.
    assert HexHome.prepare(Path.join(c.shared, ".."), "shared") != Path.expand(c.shared)
  end
end
