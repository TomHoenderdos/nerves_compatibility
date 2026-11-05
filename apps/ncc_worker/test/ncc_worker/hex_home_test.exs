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

  test "does not create a `.hex` entry in the project directory", c do
    # typedstruct 0.5.4's mix.exs reads `<deps_path>/../.hex` as a file to
    # learn its own version, and `File.read!/1` on a directory raises, so a
    # `.hex` directory next to `deps/` fails every project that depends on it.
    File.write!(Path.join(c.shared, "cache.ets"), "registry")

    dir = HexHome.prepare(c.project, "host")

    assert is_binary(dir)
    refute File.exists?(Path.join(c.project, ".hex"))
    assert String.starts_with?(dir, c.project)
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

  # Hex 2.6 renamed its registry cache to `cache.bin` (a header, a CRC32 and
  # one term) and reads `cache.ets` only when there is no `cache.bin`. The
  # image runs 2.6, so `cache.bin` is the file the targets share.
  test "seeds and publishes Hex 2.6's cache.bin", c do
    File.write!(Path.join(c.shared, "cache.bin"), "bin-v1")

    a = HexHome.prepare(c.project, "rpi4")
    assert File.read!(Path.join(a, "cache.bin")) == "bin-v1"

    File.write!(Path.join(a, "cache.bin"), "bin-v2")
    assert :ok = HexHome.publish(a)
    assert File.read!(Path.join(c.shared, "cache.bin")) == "bin-v2"

    b = HexHome.prepare(c.project, "x86_64")
    assert File.read!(Path.join(b, "cache.bin")) == "bin-v2"
  end

  test "a host build's first cache.bin warms the targets after it", c do
    host = HexHome.prepare(c.project, "host")
    File.write!(Path.join(host, "cache.bin"), "fetched")
    HexHome.publish(host)

    assert Enum.sort(File.ls!(c.shared)) == ["cache.bin", "packages"]
    assert File.read!(Path.join(HexHome.prepare(c.project, "rpi4"), "cache.bin")) == "fetched"
  end

  # Each file keeps its own name: a Hex that cannot parse a format never finds
  # it under the name it reads.
  test "keeps each registry file under its own name", c do
    File.write!(Path.join(c.shared, "cache.bin"), "bin")
    File.write!(Path.join(c.shared, "cache.ets"), "ets")

    dir = HexHome.prepare(c.project, "rpi4")
    assert File.read!(Path.join(dir, "cache.bin")) == "bin"
    assert File.read!(Path.join(dir, "cache.ets")) == "ets"

    File.write!(Path.join(dir, "cache.bin"), "bin-2")
    HexHome.publish(dir)
    assert File.read!(Path.join(c.shared, "cache.bin")) == "bin-2"
    assert File.read!(Path.join(c.shared, "cache.ets")) == "ets"
  end

  test "knows the registry file of the Hex versions it was checked against" do
    assert HexHome.registry_file("2.6.0") == {:ok, "cache.bin"}
    assert HexHome.registry_file("2.5.1") == {:ok, "cache.ets"}
    assert HexHome.registry_file("2.7.0") == :error
    assert HexHome.registry_file("not a version") == :error
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
