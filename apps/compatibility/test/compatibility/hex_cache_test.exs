defmodule Compatibility.HexCacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Compatibility.HexCache

  @moduletag :tmp_dir

  @tarball "the bytes Hex serves for jason 1.4.4"

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  # A run's per-run `packages/hexpm` as the container leaves it, and the
  # shared cache root on the host.
  defp dirs(tmp) do
    source = Path.join([tmp, "run", "work", "hex-home", "packages", "hexpm"])
    root = Path.join(tmp, "hex-cache")
    File.mkdir_p!(source)
    File.mkdir_p!(root)
    {source, root}
  end

  defp miss(name, version, extra \\ %{}),
    do: Map.merge(%{"name" => name, "version" => version}, extra)

  defp lookup(answers) do
    fn name, version -> Map.get(answers, {name, version}, {:error, :unknown_release}) end
  end

  defp dest(root, file), do: Path.join([root, "packages", "hexpm", file])

  defp promote(misses, source, root, answers, opts \\ []) do
    hc_promote(misses, source, root, lookup(answers), opts)
  end

  # `source` is `<work>/hex-home/packages/hexpm`; the work dir is trusted.
  defp hc_promote(misses, source, root, lookup, opts \\ []) do
    trusted = source |> Path.dirname() |> Path.dirname() |> Path.dirname()
    HexCache.promote(misses, source, root, lookup, Keyword.put_new(opts, :trusted, trusted))
  end

  describe "promote/5" do
    test "moves a downloaded tarball whose bytes hash to Hex's checksum", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)

      assert %{promoted: 1, refused: 0, skipped: 0, ignored: 0} =
               promote([miss("jason", "1.4.4")], source, root, %{
                 {"jason", "1.4.4"} => {:ok, sha(@tarball)}
               })

      path = dest(root, "jason-1.4.4.tar")
      assert File.read!(path) == @tarball
      assert {:ok, %File.Stat{type: :regular, mode: mode}} = File.lstat(path)
      assert Bitwise.band(mode, 0o777) == 0o644
      # Nothing but the tarball: the temporary file was renamed, not copied.
      assert File.ls!(Path.dirname(path)) == ["jason-1.4.4.tar"]
    end

    test "never trusts the checksum the worker reported", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      planted = "a tarball the build wrote itself"
      File.write!(Path.join(source, "jason-1.4.4.tar"), planted)

      log =
        capture_log(fn ->
          assert %{promoted: 0, refused: 1} =
                   promote(
                     [miss("jason", "1.4.4", %{"outer_checksum" => sha(planted)})],
                     source,
                     root,
                     %{{"jason", "1.4.4"} => {:ok, sha(@tarball)}}
                   )
        end)

      assert log =~ "does not hash to the checksum Hex.pm publishes"
      refute File.exists?(dest(root, "jason-1.4.4.tar"))
    end

    test "accepts Hex's checksum in either case", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)

      assert %{promoted: 1} =
               promote([miss("jason", "1.4.4")], source, root, %{
                 {"jason", "1.4.4"} => {:ok, String.upcase(sha(@tarball))}
               })
    end

    test "refuses a symlink, a hardlinked file and a directory", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      elsewhere = Path.join(tmp, "elsewhere.tar")
      File.write!(elsewhere, @tarball)
      File.ln_s!(elsewhere, Path.join(source, "jason-1.4.4.tar"))
      File.ln!(elsewhere, Path.join(source, "plug-1.16.0.tar"))
      File.mkdir_p!(Path.join(source, "mime-2.0.6.tar"))

      answers = %{
        {"jason", "1.4.4"} => {:ok, sha(@tarball)},
        {"plug", "1.16.0"} => {:ok, sha(@tarball)},
        {"mime", "2.0.6"} => {:ok, sha(@tarball)}
      }

      capture_log(fn ->
        assert %{promoted: 0, refused: 3} =
                 promote(
                   [miss("jason", "1.4.4"), miss("plug", "1.16.0"), miss("mime", "2.0.6")],
                   source,
                   root,
                   answers
                 )
      end)

      for file <- ~w(jason-1.4.4.tar plug-1.16.0.tar mime-2.0.6.tar),
          do: refute(File.exists?(dest(root, file)))
    end

    test "refuses names and versions that are not Hex's, before touching the disk", %{
      tmp_dir: tmp
    } do
      {source, root} = dirs(tmp)

      bad = [
        miss("../../etc/passwd", "1.0.0"),
        miss("Jason", "1.4.4"),
        miss("jason", "1.4"),
        miss("jason", "1.4.4/../../x"),
        miss("jason-x", "1.0.0"),
        %{"name" => "jason"},
        "jason-1.4.4.tar",
        nil
      ]

      parent = self()

      lookup = fn name, version ->
        send(parent, {:asked, name, version})
        {:ok, sha(@tarball)}
      end

      capture_log(fn ->
        assert %{promoted: 0, refused: 8} = hc_promote(bad, source, root, lookup)
      end)

      refute_received {:asked, _, _}
    end

    test "a release Hex does not publish is refused", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-9.9.9.tar"), @tarball)

      capture_log(fn ->
        assert %{promoted: 0, refused: 1} = promote([miss("jason", "9.9.9")], source, root, %{})
      end)
    end

    test "a Hex outage promotes nothing, refuses nothing and stops asking", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)
      File.write!(Path.join(source, "plug-1.16.0.tar"), @tarball)
      parent = self()

      lookup = fn name, version ->
        send(parent, {:asked, name, version})
        {:error, :hex_api_unavailable}
      end

      capture_log(fn ->
        assert %{promoted: 0, refused: 0, skipped: 2} =
                 hc_promote(
                   [miss("jason", "1.4.4"), miss("plug", "1.16.0")],
                   source,
                   root,
                   lookup
                 )
      end)

      assert_received {:asked, "jason", "1.4.4"}
      refute_received {:asked, "plug", "1.16.0"}
    end

    # The budget is checked again once the lookup answers, so the overrun
    # past it is at most one lookup (`max_overrun_ms/0`), never a read and a
    # write on top.
    test "misses left when the time budget runs out are skipped", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)
      File.write!(Path.join(source, "plug-1.16.0.tar"), @tarball)
      parent = self()

      lookup = fn name, _version ->
        send(parent, {:asked, name})
        Process.sleep(20)
        {:ok, sha(@tarball)}
      end

      capture_log(fn ->
        assert %{promoted: 0, skipped: 2} =
                 hc_promote(
                   [miss("jason", "1.4.4"), miss("plug", "1.16.0")],
                   source,
                   root,
                   lookup,
                   budget_ms: 10
                 )
      end)

      assert_received {:asked, "jason"}
      refute_received {:asked, "plug"}
      refute File.exists?(dest(root, "jason-1.4.4.tar"))
      assert HexCache.max_overrun_ms() >= HexCache.lookup_timeout_ms()
    end

    # The container owns everything under its work dir: a link anywhere on
    # the way to the tarball would have the host read wherever it points.
    test "refuses a run whose hex-home, packages or hexpm dir is a symlink", %{tmp_dir: tmp} do
      answers = %{{"jason", "1.4.4"} => {:ok, sha(@tarball)}}

      for component <- ["hex-home", "packages", "hexpm"] do
        work = Path.join([tmp, component, "work"])
        elsewhere = Path.join([tmp, component, "elsewhere"])
        File.mkdir_p!(Path.join([elsewhere, "packages", "hexpm"]))
        File.mkdir_p!(work)

        # The real tree lives elsewhere; one component of the path is a link.
        target =
          case component do
            "hex-home" -> elsewhere
            "packages" -> Path.join(elsewhere, "packages")
            "hexpm" -> Path.join([elsewhere, "packages", "hexpm"])
          end

        File.write!(Path.join([elsewhere, "packages", "hexpm", "jason-1.4.4.tar"]), @tarball)

        case component do
          "hex-home" ->
            File.ln_s!(target, Path.join(work, "hex-home"))

          "packages" ->
            File.mkdir_p!(Path.join(work, "hex-home"))
            File.ln_s!(target, Path.join([work, "hex-home", "packages"]))

          "hexpm" ->
            File.mkdir_p!(Path.join([work, "hex-home", "packages"]))
            File.ln_s!(target, Path.join([work, "hex-home", "packages", "hexpm"]))
        end

        root = Path.join([tmp, component, "hex-cache"])
        source = Path.join([work, "hex-home", "packages", "hexpm"])

        log =
          capture_log(fn ->
            assert %{promoted: 0, refused: 1} =
                     HexCache.promote([miss("jason", "1.4.4")], source, root, lookup(answers),
                       trusted: work
                     )
          end)

        assert log =~ "not a real directory"
        refute File.exists?(dest(root, "jason-1.4.4.tar"))
      end
    end

    test "a source outside the trusted dir promotes nothing", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)

      capture_log(fn ->
        assert %{promoted: 0, refused: 1} =
                 HexCache.promote(
                   [miss("jason", "1.4.4")],
                   source,
                   root,
                   lookup(%{{"jason", "1.4.4"} => {:ok, sha(@tarball)}}),
                   trusted: Path.join(tmp, "other")
                 )
      end)
    end

    test "a file over the size cap is refused unread", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)

      capture_log(fn ->
        assert %{refused: 1} =
                 promote(
                   [miss("jason", "1.4.4")],
                   source,
                   root,
                   %{{"jason", "1.4.4"} => {:ok, sha(@tarball)}},
                   max_bytes: 4
                 )
      end)
    end

    test "misses past the cap are ignored, and duplicates count once", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)
      answers = %{{"jason", "1.4.4"} => {:ok, sha(@tarball)}}

      capture_log(fn ->
        assert %{promoted: 1, ignored: 2} =
                 promote(
                   [miss("jason", "1.4.4"), miss("jason", "1.4.4"), miss("a", "1.0.0")],
                   source,
                   root,
                   answers,
                   max: 1
                 )
      end)
    end

    test "replaces a cached tarball that does not match, via rename", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)
      File.mkdir_p!(Path.join([root, "packages", "hexpm"]))
      # Left by a build from before the cache was read-only.
      File.write!(dest(root, "jason-1.4.4.tar"), "stale")

      assert %{promoted: 1} =
               promote([miss("jason", "1.4.4")], source, root, %{
                 {"jason", "1.4.4"} => {:ok, sha(@tarball)}
               })

      assert File.read!(dest(root, "jason-1.4.4.tar")) == @tarball
    end

    test "never writes through a symlinked packages dir", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)
      File.write!(Path.join(source, "jason-1.4.4.tar"), @tarball)
      outside = Path.join(tmp, "outside")
      File.mkdir_p!(Path.join(outside, "hexpm"))
      File.ln_s!(outside, Path.join(root, "packages"))

      log =
        capture_log(fn ->
          assert %{promoted: 0, skipped: 1} =
                   promote([miss("jason", "1.4.4")], source, root, %{
                     {"jason", "1.4.4"} => {:ok, sha(@tarball)}
                   })
        end)

      assert log =~ "not a real directory"
      assert File.ls!(Path.join(outside, "hexpm")) == []
    end

    test "anything but a list promotes nothing", %{tmp_dir: tmp} do
      {source, root} = dirs(tmp)

      for misses <- [nil, %{}, "x"] do
        assert %{promoted: 0, refused: 0, skipped: 0, ignored: 0} =
                 promote(misses, source, root, %{})
      end
    end
  end

  describe "touch/3 and locked_pairs/1" do
    test "marks cached tarballs a run used as recently used", %{tmp_dir: tmp} do
      {_source, root} = dirs(tmp)
      File.mkdir_p!(Path.join([root, "packages", "hexpm"]))
      path = dest(root, "jason-1.4.4.tar")
      File.write!(path, @tarball)
      File.touch!(path, 1_000_000_000)

      locked = HexCache.locked_pairs(%{"package" => %{"name" => "jason", "version" => "1.4.4"}})

      assert HexCache.touch([miss("jason", "1.4.4"), miss("absent", "1.0.0")], root, locked) ==
               1

      %File.Stat{mtime: mtime, atime: atime} = File.lstat!(path, time: :posix)
      assert mtime > 1_000_000_000
      assert atime > 1_000_000_000
    end

    test "never touches through a symlink or with a malformed pair", %{tmp_dir: tmp} do
      {_source, root} = dirs(tmp)
      File.mkdir_p!(Path.join([root, "packages", "hexpm"]))
      target = Path.join(tmp, "target")
      File.write!(target, "x")
      File.touch!(target, 1_000_000_000)
      File.ln_s!(target, dest(root, "jason-1.4.4.tar"))

      locked = MapSet.new([{"jason", "1.4.4"}, {"../target", "1.0.0"}])

      assert HexCache.touch([miss("jason", "1.4.4"), miss("../target", "1.0.0"), 7], root, locked) ==
               0

      assert File.stat!(target, time: :posix).mtime == 1_000_000_000
      assert HexCache.touch(nil, root, locked) == 0
    end

    # `hits` is the container's word: a run could name every cached release
    # to keep it from eviction. Only what the run's reported lock names is
    # refreshed.
    test "only touches hits the run's lock names", %{tmp_dir: tmp} do
      {_source, root} = dirs(tmp)
      File.mkdir_p!(Path.join([root, "packages", "hexpm"]))

      for file <- ~w(jason-1.4.4.tar decimal-2.1.1.tar telemetry-1.3.0.tar) do
        File.write!(dest(root, file), "x")
        File.touch!(dest(root, file), 1_000_000_000)
      end

      result = %{
        "package" => %{"name" => "jason", "version" => "1.4.4"},
        "deps_lock" => %{"decimal" => %{"version" => "2.1.1", "checksum" => "c"}},
        "systems" => %{
          "nerves_system_rpi4" => %{"deps_lock" => %{"x" => %{"version" => "1.0.0"}}},
          "host" => "garbage"
        }
      }

      locked = HexCache.locked_pairs(result)

      assert MapSet.equal?(
               locked,
               MapSet.new([{"jason", "1.4.4"}, {"decimal", "2.1.1"}, {"x", "1.0.0"}])
             )

      hits = [miss("jason", "1.4.4"), miss("decimal", "2.1.1"), miss("telemetry", "1.3.0")]
      assert HexCache.touch(hits, root, locked) == 2

      assert File.stat!(dest(root, "telemetry-1.3.0.tar"), time: :posix).mtime == 1_000_000_000
      assert HexCache.locked_pairs(nil) == MapSet.new()
    end
  end

  describe "pair/1" do
    test "accepts what Hex publishes" do
      assert {:ok, {"jason", "1.4.4"}} = HexCache.pair(miss("jason", "1.4.4"))
      assert {:ok, {"nerves", "2.0.0-pre.3"}} = HexCache.pair(miss("nerves", "2.0.0-pre.3"))
      assert {:ok, {"a_b9", "1.0.0+build.1"}} = HexCache.pair(miss("a_b9", "1.0.0+build.1"))
      assert :error = HexCache.pair(miss("9a", "1.0.0"))
    end

    test "the tarball name is Hex's own" do
      assert HexCache.tarball_name("jason", "1.4.4") == "jason-1.4.4.tar"
    end
  end
end
