defmodule NccWorker.NervesCacheTest do
  use ExUnit.Case, async: true

  alias NccWorker.NervesCache

  @moduletag :tmp_dir

  @lock """
  %{
    "jason": {:hex, :jason, "1.4.4", "i", [:mix], [], "hexpm", "o"},
    "nerves": {:hex, :nerves, "2.0.0-pre.3", "i", [:mix], [], "hexpm", "o"},
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "2.0.0", "i", [:mix], [], "hexpm", "o"},
    "nerves_toolchain_aarch64_nerves_linux_gnu": {:hex, :nerves_toolchain_aarch64_nerves_linux_gnu, "14.2.0", "i", [:mix], [], "hexpm", "o"},
    "shoehorn": {:hex, :shoehorn, "0.9.2", "i", [:mix], [], "hexpm", "o"},
  }
  """

  # An entry as the warm job leaves it in the cache.
  defp entry!(cache, name, fingerprint) do
    dir = Path.join([cache, "artifacts", name])
    File.mkdir_p!(Path.join(dir, "images"))
    File.write!(Path.join(dir, ".fingerprint"), fingerprint)
    File.write!(Path.join(dir, "images/rootfs.tar"), "rootfs of #{name}")
    dir
  end

  defp build!(tmp, opts \\ []) do
    {:ok, layout} =
      NervesCache.prepare(
        :build,
        Keyword.merge(
          [cache_root: Path.join(tmp, "cache"), work_dir: Path.join(tmp, "work"), rw: false],
          opts
        )
      )

    layout
  end

  defp project!(tmp, lock) do
    dir = Path.join(tmp, "proj")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "mix.lock"), lock)
    dir
  end

  describe "build mode" do
    test "the farm links every cache entry and the dl dir starts empty", %{tmp_dir: tmp} do
      cache = Path.join(tmp, "cache")
      entry!(cache, "nerves_system_rpi4-2.0.0", "abc1234")
      entry!(cache, "nerves_toolchain_aarch64_nerves_linux_gnu-14.2.0", "def5678")

      # As the container sees it: nobody may write there.
      File.chmod!(Path.join(cache, "artifacts"), 0o555)
      on_exit(fn -> File.chmod(Path.join(cache, "artifacts"), 0o755) end)

      layout = build!(tmp)

      assert layout.mode == :farm
      assert layout.artifacts_dir == Path.join([tmp, "work", "nerves", "artifacts"])
      assert layout.dl_dir == Path.join([tmp, "work", "nerves", "dl"])

      for name <- ["nerves_system_rpi4-2.0.0", "nerves_toolchain_aarch64_nerves_linux_gnu-14.2.0"] do
        link = Path.join(layout.artifacts_dir, name)
        assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
        assert File.read_link!(link) == Path.join([cache, "artifacts", name])
        assert File.read!(Path.join(link, "images/rootfs.tar")) == "rootfs of #{name}"
      end

      assert File.ls!(layout.dl_dir) == []
      assert NervesCache.misses(layout) == []
    end

    test "a host whose cache was never warmed gets an empty farm", %{tmp_dir: tmp} do
      layout = build!(tmp)

      assert File.ls!(layout.artifacts_dir) == []
      assert NervesCache.misses(layout) == []
    end

    test "env points Nerves at the farm and never at ~/.nerves", %{tmp_dir: tmp} do
      layout = build!(tmp)

      assert NervesCache.env(layout) == [
               {"NERVES_ARTIFACTS_DIR", Path.join([tmp, "work", "nerves", "artifacts"])},
               {"NERVES_DL_DIR", Path.join([tmp, "work", "nerves", "dl"])},
               {"XDG_DATA_HOME", Path.join([tmp, "work", "nerves", "data"])}
             ]
    end

    # nerves_bootstrap's UpdateChecker writes <XDG_DATA_HOME or ~>/.nerves
    # when its application starts. The root is read-only and ~/.nerves is no
    # longer a mount, so without this the app fails to start, its compile
    # hook never runs, and `mix firmware` builds for the host and dies with
    # "No Nerves package is supplying an Erlang runtime".
    test "every mode gives nerves_bootstrap a writable data dir under /work", %{tmp_dir: tmp} do
      work = Path.join(tmp, "work")
      cache = Path.join(tmp, "cache")

      layouts = [
        build!(tmp),
        build!(tmp, rw: true),
        elem(NervesCache.prepare(:warm, cache_root: cache, work_dir: work, run_id: "w-1"), 1)
      ]

      for layout <- layouts do
        {"XDG_DATA_HOME", data} = List.keyfind(NervesCache.env(layout), "XDG_DATA_HOME", 0)
        assert data == Path.join([work, "nerves", "data"])
        refute String.starts_with?(data, cache)

        # Marked checked, so bootstrap neither writes nor asks hex.pm.
        check = Path.join([data, "nerves", "nerves_bootstrap_update_check"])
        assert {:ok, %File.Stat{type: :regular, mtime: mtime}} = File.lstat(check, time: :posix)
        assert abs(System.os_time(:second) - mtime) < 60
      end
    end

    test "misses are the real directories only, as name and version", %{tmp_dir: tmp} do
      entry!(Path.join(tmp, "cache"), "nerves_system_rpi4-2.0.0", "abc1234")
      layout = build!(tmp)

      File.mkdir_p!(Path.join(layout.artifacts_dir, "nerves_system_x86_64-2.0.1-rc.1"))
      File.write!(Path.join(layout.artifacts_dir, "README"), "not an artifact")
      File.mkdir_p!(Path.join(layout.artifacts_dir, "nerves_system_bbb-2.0.0.stale.x"))

      assert NervesCache.misses(layout) == [
               %{"name" => "nerves_system_x86_64", "version" => "2.0.1-rc.1"}
             ]
    end

    # Nerves' fingerprint-mismatch path (artifact_resolver.ex): `File.rm_rf!`
    # on the entry, `mkdir_p`, extract, write `.fingerprint`. On a farm link
    # the rm_rf removes the link only, so the fresh extraction lands in the
    # run dir and the read-only cache is untouched.
    test "a fingerprint mismatch replaces the link, never the cache entry", %{tmp_dir: tmp} do
      cached = entry!(Path.join(tmp, "cache"), "nerves_system_rpi4-2.0.0", "abc1234")
      layout = build!(tmp)
      link = Path.join(layout.artifacts_dir, "nerves_system_rpi4-2.0.0")

      File.rm_rf!(link)
      File.mkdir_p!(link)
      File.write!(Path.join(link, ".fingerprint"), "fresh99")

      assert File.read!(Path.join(cached, ".fingerprint")) == "abc1234"

      assert File.read!(Path.join(cached, "images/rootfs.tar")) ==
               "rootfs of nerves_system_rpi4-2.0.0"

      assert {:ok, %File.Stat{type: :directory}} = File.lstat(link)

      assert NervesCache.misses(layout) == [
               %{"name" => "nerves_system_rpi4", "version" => "2.0.0"}
             ]
    end

    test "the lock report lists only nerves_system_* and nerves_toolchain_*", %{tmp_dir: tmp} do
      project = project!(tmp, @lock)

      assert NervesCache.lock_entries(project) == [
               %{"name" => "nerves_system_rpi4", "version" => "2.0.0"},
               %{"name" => "nerves_toolchain_aarch64_nerves_linux_gnu", "version" => "14.2.0"}
             ]
    end

    test "put_report adds misses and lock, and nothing when both are empty", %{tmp_dir: tmp} do
      layout = build!(tmp)
      File.mkdir_p!(Path.join(layout.artifacts_dir, "nerves_system_rpi4-2.0.0"))

      assert %{nerves_cache: %{misses: [%{"name" => "nerves_system_rpi4"}], lock: [_, _]}} =
               NervesCache.put_report(%{run_id: "r"}, layout, project!(tmp, @lock))

      empty = build!(Path.join(tmp, "other"))

      assert NervesCache.put_report(%{run_id: "r"}, empty, Path.join(tmp, "no-proj")) == %{
               run_id: "r"
             }
    end

    test "the read-write fallback points Nerves at the cache and reports nothing", %{tmp_dir: tmp} do
      layout = build!(tmp, rw: true)
      cache = Path.join(tmp, "cache")

      assert layout.mode == :direct
      assert layout.artifacts_dir == Path.join(cache, "artifacts")
      assert layout.dl_dir == Path.join(cache, "dl")
      assert File.dir?(layout.artifacts_dir)
      assert NervesCache.report(layout, project!(tmp, @lock)) == nil
    end
  end

  describe "warm mode" do
    setup %{tmp_dir: tmp} do
      cache = Path.join(tmp, "cache")

      {:ok, layout} =
        NervesCache.prepare(:warm,
          cache_root: cache,
          work_dir: Path.join(tmp, "work"),
          run_id: "warm_nerves-42"
        )

      %{cache: cache, layout: layout}
    end

    # What Nerves leaves after extracting into the staging farm.
    defp extracted!(layout, name, fingerprint) do
      dir = Path.join(layout.artifacts_dir, name)
      File.rm_rf!(dir)
      File.mkdir_p!(dir)
      if fingerprint, do: File.write!(Path.join(dir, ".fingerprint"), fingerprint)
      File.write!(Path.join(dir, "marker"), "from warm_nerves-42")
      dir
    end

    test "staging lives under staging/<run_id> and farms the cache", %{tmp_dir: tmp} do
      cache = Path.join(tmp, "cache2")
      entry!(cache, "nerves_system_rpi4-2.0.0", "abc1234")

      {:ok, layout} =
        NervesCache.prepare(:warm,
          cache_root: cache,
          work_dir: Path.join(tmp, "work"),
          run_id: "warm_nerves-7"
        )

      assert layout.mode == :staging
      assert layout.artifacts_dir == Path.join([cache, "staging", "warm_nerves-7", "artifacts"])
      assert layout.dl_dir == Path.join([cache, "staging", "warm_nerves-7", "dl"])

      assert {:ok, %File.Stat{type: :symlink}} =
               File.lstat(Path.join(layout.artifacts_dir, "nerves_system_rpi4-2.0.0"))
    end

    test "a new entry is renamed into place", %{cache: cache, layout: layout} do
      extracted!(layout, "nerves_system_rpi4-2.0.0", "abc1234")

      assert {:ok, %{installed: ["nerves_system_rpi4-2.0.0"], kept: [], replaced: []}} =
               NervesCache.install_staged(layout)

      installed = Path.join([cache, "artifacts", "nerves_system_rpi4-2.0.0"])
      assert {:ok, %File.Stat{type: :directory}} = File.lstat(installed)
      assert File.read!(Path.join(installed, "marker")) == "from warm_nerves-42"
    end

    test "an entry with the same fingerprint is left alone", %{cache: cache, layout: layout} do
      existing = entry!(cache, "nerves_system_rpi4-2.0.0", "abc1234")
      extracted!(layout, "nerves_system_rpi4-2.0.0", "abc1234")

      assert {:ok, %{installed: [], kept: ["nerves_system_rpi4-2.0.0"], replaced: []}} =
               NervesCache.install_staged(layout)

      refute File.exists?(Path.join(existing, "marker"))
    end

    test "a different fingerprint is replaced and the old entry set aside", ctx do
      %{cache: cache, layout: layout} = ctx
      entry!(cache, "nerves_system_rpi4-2.0.0", "corrupt")
      extracted!(layout, "nerves_system_rpi4-2.0.0", "abc1234")

      assert {:ok, %{replaced: ["nerves_system_rpi4-2.0.0"]}} = NervesCache.install_staged(layout)

      artifacts = Path.join(cache, "artifacts")
      entry = Path.join(artifacts, "nerves_system_rpi4-2.0.0")
      assert File.read!(Path.join(entry, ".fingerprint")) == "abc1234"

      stale = Path.join(artifacts, "nerves_system_rpi4-2.0.0.stale.warm_nerves-42")
      assert File.read!(Path.join(stale, ".fingerprint")) == "corrupt"

      assert :ok = NervesCache.cleanup(layout)
      refute File.exists?(stale)
      refute File.exists?(Path.join([cache, "staging", "warm_nerves-42"]))
      assert File.dir?(entry)
    end

    test "an extraction without a fingerprint is not installed", %{cache: cache, layout: layout} do
      extracted!(layout, "nerves_system_rpi4-2.0.0", nil)

      assert {:ok, %{installed: [], incomplete: ["nerves_system_rpi4-2.0.0"]}} =
               NervesCache.install_staged(layout)

      refute File.exists?(Path.join([cache, "artifacts", "nerves_system_rpi4-2.0.0"]))
    end

    test "cleanup leaves another run's set-aside entries alone", %{cache: cache, layout: layout} do
      other = Path.join([cache, "artifacts", "nerves_system_bbb-2.0.0.stale.warm_nerves-41"])
      File.mkdir_p!(other)

      assert :ok = NervesCache.cleanup(layout)
      assert File.dir?(other)
    end

    test "a run id cannot name a directory outside staging", %{cache: cache, tmp_dir: tmp} do
      for bad <- ["", ".", ".."] do
        assert_raise ArgumentError, fn ->
          NervesCache.prepare(:warm, cache_root: cache, work_dir: tmp, run_id: bad)
        end
      end

      {:ok, layout} =
        NervesCache.prepare(:warm, cache_root: cache, work_dir: tmp, run_id: "a/../../b")

      assert Path.dirname(Path.dirname(layout.artifacts_dir)) == Path.join(cache, "staging")
    end
  end
end
