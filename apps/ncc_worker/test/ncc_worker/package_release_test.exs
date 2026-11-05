defmodule NccWorker.PackageReleaseTest do
  # What the static priv check compares a build against: the release the lock
  # resolved for the package (`DepsLock.package_release/2`) and that release's
  # tarball from the run's Hex home, only when it is the tarball the lock's
  # outer checksum names (`HexCache.package_tarball/4`).
  use ExUnit.Case, async: true

  alias NccWorker.{DepsLock, HexCache}

  @moduletag :tmp_dir

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp cached(home, file, bytes) do
    dir = Path.join([home, "packages", "hexpm"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, file), bytes)
  end

  describe "HexCache.package_tarball/4" do
    test "the cached tarball whose sha is the lock's outer checksum", %{tmp_dir: home} do
      cached(home, "jason-1.4.4.tar", "tarball bytes")

      assert HexCache.package_tarball(home, "jason", "1.4.4", sha("tarball bytes")) ==
               "tarball bytes"
    end

    test "an upper-case checksum names the same tarball", %{tmp_dir: home} do
      cached(home, "jason-1.4.4.tar", "tarball bytes")

      assert HexCache.package_tarball(home, "jason", "1.4.4", String.upcase(sha("tarball bytes"))) ==
               "tarball bytes"
    end

    test "nothing when the cached tarball is not the one the lock names", %{tmp_dir: home} do
      cached(home, "jason-1.4.4.tar", "other bytes")
      assert HexCache.package_tarball(home, "jason", "1.4.4", sha("tarball bytes")) == nil
    end

    test "nothing when no tarball is cached", %{tmp_dir: home} do
      assert HexCache.package_tarball(home, "jason", "1.4.4", sha("x")) == nil
    end

    test "nothing over the tarball size cap, without reading it all", %{tmp_dir: home} do
      big = :binary.copy("a", Compatibility.StaticPriv.max_tarball_bytes() + 1)
      cached(home, "jason-1.4.4.tar", big)
      assert HexCache.package_tarball(home, "jason", "1.4.4", sha(big)) == nil
    end

    # Name and version come from the lock; neither may reach outside the cache.
    test "nothing for a name or version that is not a Hex tarball name", %{tmp_dir: home} do
      cached(home, "jason-1.4.4.tar", "tarball bytes")
      File.write!(Path.join(home, "outside.tar"), "outside")

      for {name, version} <- [{"../outside", "1"}, {"jason", "1.4.4/../../x"}, {"Jason", "1.4.4"}] do
        assert HexCache.package_tarball(home, name, version, sha("outside")) == nil
      end
    end
  end

  describe "DepsLock.package_release/2" do
    defp lock(dir, contents), do: File.write!(Path.join(dir, "mix.lock"), contents)

    test "the package's Hex name, locked version and outer checksum", %{tmp_dir: dir} do
      lock(dir, """
      %{
        "jason": {:hex, :jason, "1.4.4", "inner", [:mix], [], "hexpm", "outer-jason"},
      }
      """)

      assert DepsLock.package_release(dir, "jason") ==
               {:ok, %{name: "jason", version: "1.4.4", checksum: "outer-jason"}}
    end

    # The lock key is the app name; the tarball is the Hex package's.
    test "the Hex name when the app is named otherwise", %{tmp_dir: dir} do
      lock(dir, """
      %{
        "my_app": {:hex, :my_pkg, "0.2.0", "inner", [:mix], [], "hexpm", "outer-pkg"},
      }
      """)

      assert {:ok, %{name: "my_pkg", version: "0.2.0", checksum: "outer-pkg"}} =
               DepsLock.package_release(dir, "my_pkg")
    end

    test "an error for a package the lock does not hold from Hex", %{tmp_dir: dir} do
      lock(dir, """
      %{
        "jason": {:hex, :jason, "1.4.4", "inner", [:mix], [], "hexpm", "outer-jason"},
        "local": {:git, "https://example.com/local.git", "abc", []},
      }
      """)

      assert DepsLock.package_release(dir, "missing") == :error
      assert DepsLock.package_release(dir, "local") == :error
    end

    # An old lock entry has no outer checksum: nothing to name a tarball by.
    test "an error for an entry without an outer checksum", %{tmp_dir: dir} do
      lock(dir, """
      %{
        "jason": {:hex, :jason, "1.4.4", "inner", [:mix], [], "hexpm"},
      }
      """)

      assert DepsLock.package_release(dir, "jason") == :error
    end

    test "an error without a readable lock", %{tmp_dir: dir} do
      assert DepsLock.package_release(dir, "jason") == :error
      lock(dir, "not a lock")
      assert DepsLock.package_release(dir, "jason") == :error
    end
  end
end
