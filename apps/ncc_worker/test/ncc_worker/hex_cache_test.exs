defmodule NccWorker.HexCacheTest do
  use ExUnit.Case, async: true

  alias NccWorker.HexCache

  @moduletag :tmp_dir

  @lock """
  %{
    "jason": {:hex, :jason, "1.4.4", "i", [:mix], [], "hexpm", "o"},
    "nerves": {:hex, :nerves, "2.0.0-pre.3", "i", [:mix], [], "hexpm", "o"},
    "telemetry": {:hex, :telemetry, "1.3.0", "i", [:mix], [], "hexpm", "o"},
  }
  """

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # The shared cache as the host leaves it: tarballs only, plus what a build
  # from before the read-only mount could have left at its root.
  defp shared!(tmp) do
    root = Path.join(tmp, "hex-cache")
    dir = Path.join([root, "packages", "hexpm"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "jason-1.4.4.tar"), "jason tarball")
    File.write!(Path.join(dir, "nerves-2.0.0-pre.3.tar"), "nerves tarball")
    File.write!(Path.join(dir, "jason-1.4.4.tar.0123456789abcdef"), "a download cut short")
    File.write!(Path.join(root, "cache.ets"), "planted registry")
    File.write!(Path.join(root, "cache.bin"), "planted registry")
    File.write!(Path.join(root, "hex.config"), "{unsafe_registry, true}.")
    root
  end

  defp prepare!(tmp, opts \\ []) do
    {:ok, layout} =
      HexCache.prepare(
        Keyword.merge(
          [cache_root: shared!(tmp), work_dir: Path.join(tmp, "work"), rw: false],
          opts
        )
      )

    layout
  end

  defp project!(tmp) do
    dir = Path.join(tmp, "proj")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.lock"), @lock)
    dir
  end

  describe "prepare/1" do
    test "a per-run HEX_HOME links every cached tarball and nothing else", %{tmp_dir: tmp} do
      layout = prepare!(tmp)
      home = Path.join([tmp, "work", "hex-home"])
      packages = Path.join([home, "packages", "hexpm"])

      assert layout.mode == :seeded
      assert layout.home == home

      assert Enum.sort(File.ls!(packages)) == ["jason-1.4.4.tar", "nerves-2.0.0-pre.3.tar"]

      assert {:ok, target} = File.read_link(Path.join(packages, "jason-1.4.4.tar"))
      assert target == Path.join([tmp, "hex-cache", "packages", "hexpm", "jason-1.4.4.tar"])

      # Hex does not verify its registry cache, and `hex.config` can turn
      # registry verification off or name a mirror: neither is seeded.
      assert File.ls!(home) == ["packages"]
    end

    test "the packages dirs are real directories Hex can write misses into", %{tmp_dir: tmp} do
      layout = prepare!(tmp)
      packages = Path.join([layout.home, "packages", "hexpm"])

      assert {:ok, %File.Stat{type: :directory}} = File.lstat(packages)
      File.write!(Path.join(packages, "telemetry-1.3.0.tar"), "download")

      # A rejected cached tarball is removed by Hex: that removes the link only.
      File.rm!(Path.join(packages, "jason-1.4.4.tar"))
      assert File.exists?(Path.join([tmp, "hex-cache", "packages", "hexpm", "jason-1.4.4.tar"]))
    end

    test "a cache that was never filled leaves an empty per-run home", %{tmp_dir: tmp} do
      {:ok, layout} =
        HexCache.prepare(
          cache_root: Path.join(tmp, "nope"),
          work_dir: Path.join(tmp, "work"),
          rw: false
        )

      assert File.ls!(Path.join([layout.home, "packages", "hexpm"])) == []
    end

    test "the read-write fallback uses the mounted cache itself", %{tmp_dir: tmp} do
      layout = prepare!(tmp, rw: true)

      assert layout.mode == :direct
      assert layout.home == Path.join(tmp, "hex-cache")
      refute File.exists?(Path.join([tmp, "work", "hex-home"]))
    end

    test "env/1 points HEX_HOME at the run's home", %{tmp_dir: tmp} do
      layout = prepare!(tmp)
      assert HexCache.env(layout) == [{"HEX_HOME", Path.join([tmp, "work", "hex-home"])}]
    end
  end

  describe "report/2" do
    test "lists the downloads with their checksums, and the cached tarballs the lock used", %{
      tmp_dir: tmp
    } do
      layout = prepare!(tmp)
      packages = Path.join([layout.home, "packages", "hexpm"])
      File.write!(Path.join(packages, "telemetry-1.3.0.tar"), "telemetry tarball")
      # A temporary download Hex never renamed is not a miss.
      File.write!(Path.join(packages, "telemetry-1.3.0.tar.0123456789abcdef"), "partial")

      assert HexCache.report(layout, project!(tmp)) == %{
               misses: [
                 %{
                   "name" => "telemetry",
                   "version" => "1.3.0",
                   "outer_checksum" => sha("telemetry tarball"),
                   "path" => "hex-home/packages/hexpm/telemetry-1.3.0.tar"
                 }
               ],
               hits: [
                 %{"name" => "jason", "version" => "1.4.4"},
                 %{"name" => "nerves", "version" => "2.0.0-pre.3"}
               ]
             }
    end

    test "a cached tarball Hex replaced counts as a miss, not a hit", %{tmp_dir: tmp} do
      layout = prepare!(tmp)
      path = Path.join([layout.home, "packages", "hexpm", "jason-1.4.4.tar"])
      File.rm!(path)
      File.write!(path, "the real jason tarball")

      report = HexCache.report(layout, project!(tmp))

      assert [%{"name" => "jason", "version" => "1.4.4"}] =
               Enum.map(report.misses, &Map.take(&1, ["name", "version"]))

      assert report.hits == [%{"name" => "nerves", "version" => "2.0.0-pre.3"}]
    end

    test "nothing to report is nil, and so is the read-write fallback", %{tmp_dir: tmp} do
      layout = prepare!(tmp)
      assert HexCache.report(layout, Path.join(tmp, "no-project")) == nil

      rw = prepare!(tmp, rw: true)
      assert HexCache.report(rw, project!(tmp)) == nil
    end

    test "put_report/3 adds the report under :hex_cache", %{tmp_dir: tmp} do
      layout = prepare!(tmp)

      assert %{hex_cache: %{hits: [_, _]}} = HexCache.put_report(%{}, layout, project!(tmp))
      assert HexCache.put_report(%{a: 1}, layout, Path.join(tmp, "none")) == %{a: 1}
    end
  end
end
