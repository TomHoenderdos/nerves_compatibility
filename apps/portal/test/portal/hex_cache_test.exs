defmodule Portal.HexCacheTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  @moduletag :tmp_dir

  @tarball "jason tarball"

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp opts(tmp),
    do: [
      scratch_root: Path.join(tmp, "scratch"),
      hex_cache: Path.join(tmp, "hex-cache"),
      release_checksum: fn "jason", "1.4.4" -> {:ok, sha(@tarball)} end
    ]

  test "reads the download from the run's own scratch dir, whatever path was reported", %{
    tmp_dir: tmp
  } do
    dir = Path.join([tmp, "scratch", "run-1", "work", "hex-home", "packages", "hexpm"])
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "jason-1.4.4.tar"), @tarball)

    elsewhere = Path.join(tmp, "elsewhere.tar")
    File.write!(elsewhere, "something else")

    result = %{
      "hex_cache" => %{
        "misses" => [%{"name" => "jason", "version" => "1.4.4", "path" => elsewhere}]
      }
    }

    assert %{promoted: 1, refused: 0, touched: 0} =
             Portal.HexCache.promote(result, "run-1", opts(tmp))

    assert File.read!(Path.join([tmp, "hex-cache", "packages", "hexpm", "jason-1.4.4.tar"])) ==
             @tarball
  end

  # The container owns work/: a symlinked hex-home would have the host read
  # (and promote) whatever it points at.
  test "a symlinked hex-home in the run's work dir is refused", %{tmp_dir: tmp} do
    elsewhere = Path.join([tmp, "elsewhere", "packages", "hexpm"])
    File.mkdir_p!(elsewhere)
    File.write!(Path.join(elsewhere, "jason-1.4.4.tar"), @tarball)

    work = Path.join([tmp, "scratch", "run-1", "work"])
    File.mkdir_p!(work)
    File.ln_s!(Path.join(tmp, "elsewhere"), Path.join(work, "hex-home"))

    result = %{"hex_cache" => %{"misses" => [%{"name" => "jason", "version" => "1.4.4"}]}}

    capture_log(fn ->
      assert %{promoted: 0, refused: 1} = Portal.HexCache.promote(result, "run-1", opts(tmp))
    end)

    refute File.exists?(Path.join([tmp, "hex-cache", "packages", "hexpm", "jason-1.4.4.tar"]))
  end

  test "a run without a report, or with a malformed one, promotes nothing", %{tmp_dir: tmp} do
    zero = %{promoted: 0, refused: 0, skipped: 0, ignored: 0, touched: 0}

    assert Portal.HexCache.promote(%{}, "run-1", opts(tmp)) == zero
    assert Portal.HexCache.promote(nil, "run-1", opts(tmp)) == zero
    assert Portal.HexCache.promote(%{"hex_cache" => "x"}, "run-1", opts(tmp)) == zero

    capture_log(fn ->
      assert %{promoted: 0, refused: 1} =
               Portal.HexCache.promote(
                 %{"hex_cache" => %{"misses" => [%{"name" => "../x", "version" => "1"}]}},
                 "run-1",
                 opts(tmp)
               )
    end)
  end
end
