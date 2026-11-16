defmodule NccWorker.Portability.PrivRootsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.PrivRoots

  @moduletag :tmp_dir
  @root "/work/proj"

  defp put(dir, rel, bytes) do
    path = Path.join([dir, "priv", rel])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, bytes)
  end

  defp check(dir), do: PrivRoots.check(Path.join(dir, "priv"), [@root, "/usr/lib/erlang"])

  test "files without a root pass; no priv at all passes", %{tmp_dir: dir} do
    assert check(dir) == :ok
    put(dir, "assets/a.js", "export const x = '/work/other';")
    put(dir, "assets/b.tar.gz", :zlib.gzip("nothing here"))
    assert check(dir) == :ok
  end

  test "a root in a file, as given or inflated, refuses naming the first file", %{tmp_dir: dir} do
    put(dir, "z.txt", "at /usr/lib/erlang/lib")
    put(dir, "a/b.txt", "src " <> @root <> "/deps/x/lib/x.ex")
    assert check(dir) == {:refuse, "bakes the build path: priv/a/b.txt"}

    File.rm_rf!(Path.join(dir, "priv"))
    # The second gzip member holds it.
    put(dir, "m.gz", :zlib.gzip("one") <> :zlib.gzip(@root))
    assert check(dir) == {:refuse, "bakes the build path: priv/m.gz"}
  end

  test "a link, a gzip that does not inflate and no roots cannot be told", %{tmp_dir: dir} do
    put(dir, "bad.gz", <<0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3, 0xFF, 0xFF>>)
    assert {:error, "priv/bad.gz: " <> _} = check(dir)

    File.rm_rf!(Path.join(dir, "priv"))
    put(dir, "a.txt", "a")
    File.ln_s!("/etc/hosts", Path.join(dir, "priv/link"))
    assert check(dir) == {:error, "priv/link is a symlink"}

    assert {:error, _} = PrivRoots.check(Path.join(dir, "priv"), [])
    assert {:error, _} = PrivRoots.check(nil, [@root])
  end
end
