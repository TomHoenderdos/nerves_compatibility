defmodule Portal.BuildCache.L2.TarballTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Tarball

  setup do
    tmp = Path.join(System.tmp_dir!(), "tarball-#{System.unique_integer([:positive])}")
    entry = Path.join(tmp, "entry")
    File.mkdir_p!(Path.join(entry, "ebin"))
    File.mkdir_p!(Path.join(entry, ".mix"))
    File.write!(Path.join(entry, "ebin/Elixir.Jason.beam"), "beam")
    File.write!(Path.join(entry, ".mix/compile.elixir_scm"), "scm")
    File.ln_s!("../../../../deps/jason/priv", Path.join(entry, "priv"))
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp, entry: entry, tar: Path.join(tmp, "e.tar.gz"), out: Path.join(tmp, "out")}
  end

  defp listing(dir) do
    dir
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.map(&Path.relative_to(&1, dir))
    |> Enum.sort()
  end

  test "round trip keeps files, dot dirs and Mix's link", %{entry: entry, tar: tar, out: out} do
    assert {:ok, %{sha256: sha, bytes: bytes}} = Tarball.pack(entry, tar, "jason")
    assert bytes == File.stat!(tar).size
    assert sha == Tarball.sha256_file(tar)
    File.mkdir_p!(out)
    assert :ok = Tarball.unpack(tar, out)
    assert listing(out) == listing(entry)
    assert File.read_link!(Path.join(out, "priv")) == "../../../../deps/jason/priv"
    assert File.read!(Path.join(out, "ebin/Elixir.Jason.beam")) == "beam"
  end

  test "pack refuses a priv link to another package when the package is bound, not when free", %{
    entry: entry,
    tar: tar
  } do
    File.rm!(Path.join(entry, "priv"))
    File.ln_s!("../../../../deps/other/priv", Path.join(entry, "priv"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
    assert {:ok, _} = Tarball.pack(entry, tar, :any)
  end

  test "pack refuses a hardlink and a foreign symlink", %{entry: entry, tar: tar} do
    File.ln!(Path.join(entry, "ebin/Elixir.Jason.beam"), Path.join(entry, "ebin/dup.beam"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
    File.rm!(Path.join(entry, "ebin/dup.beam"))
    File.ln_s!("/etc/hostname", Path.join(entry, "ebin/evil"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
  end

  # Archives built by hand with erl_tar, the way a hostile uploader would.
  defp hostile(tmp, members) do
    path = Path.join(tmp, "hostile-#{System.unique_integer([:positive])}.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])

    for {name, content} <- members,
        do: :ok = :erl_tar.add(tar, content, String.to_charlist(name), [])

    :ok = :erl_tar.close(tar)
    path
  end

  test "unpack refuses a ../ member", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    assert {:error, reason} = Tarball.unpack(hostile(tmp, [{"../escape", "x"}]), out)
    assert inspect(reason) =~ "escape"
    refute File.exists?(Path.join(tmp, "escape"))
  end

  test "unpack refuses an absolute member", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    assert {:error, {:member_name, _}} = Tarball.unpack(hostile(tmp, [{"/tmp/abs", "x"}]), out)
  end

  test "unpack refuses a symlink that leaves the entry", %{
    out: out,
    entry: entry,
    tar: tar
  } do
    File.rm!(Path.join(entry, "priv"))
    File.ln_s!("../../other", Path.join(entry, "priv"))
    # Build the archive without the check so the refusal happens on unpack.
    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [
          {~c"priv", String.to_charlist(Path.join(entry, "priv"))},
          {~c"ebin", String.to_charlist(Path.join(entry, "ebin"))}
        ],
        [:compressed]
      )

    File.mkdir_p!(out)
    assert {:error, {:member_type, :symlink, _}} = Tarball.unpack(tar, out)
  end

  test "unpack refuses a hard link, a device and a fifo entry", %{tmp: tmp, out: out} do
    # erl_tar cannot write those types; craft the header bytes directly.
    for typeflag <- [?1, ?3, ?6] do
      path = Path.join(tmp, "typed-#{typeflag}.tar.gz")
      File.write!(path, :zlib.gzip(ustar_entry("ebin/x", typeflag)))
      File.mkdir_p!(out)
      assert {:error, {:member_type, type, _}} = Tarball.unpack(path, out)
      assert type in [:link, :char, :fifo]
      File.rm_rf!(out)
    end
  end

  test "unpack refuses an empty archive and an archive that is not gzip", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    empty = Path.join(tmp, "empty.tar.gz")
    File.write!(empty, :zlib.gzip(:binary.copy(<<0>>, 1024)))
    assert {:error, _} = Tarball.unpack(empty, out)
    junk = Path.join(tmp, "junk.tar.gz")
    File.write!(junk, "not a tarball")
    assert {:error, _} = Tarball.unpack(junk, out)
  end

  test "unpack refuses a truncated archive", %{entry: entry, tar: tar, tmp: tmp, out: out} do
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    bytes = File.read!(tar)
    cut = Path.join(tmp, "cut.tar.gz")
    File.write!(cut, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    File.mkdir_p!(out)
    assert {:error, _} = Tarball.unpack(cut, out)
  end

  test "unpack strips modes", %{entry: entry, tar: tar, out: out} do
    File.chmod!(Path.join(entry, "ebin/Elixir.Jason.beam"), 0o4777)
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    File.mkdir_p!(out)
    assert :ok = Tarball.unpack(tar, out)

    assert Bitwise.band(File.stat!(Path.join(out, "ebin/Elixir.Jason.beam")).mode, 0o7777) ==
             0o755
  end

  test "pack carries Mix links as a manifest, never as symlink members", %{entry: entry, tar: tar} do
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    {:ok, table} = :erl_tar.table(String.to_charlist(tar), [:compressed, :verbose])
    refute Enum.any?(table, fn {_, type, _, _, _, _, _} -> type == :symlink end)
    assert Enum.count(table, fn {name, _, _, _, _, _, _} -> name == ~c".ncc-links.json" end) == 1
  end

  test "pack reserves the manifest name", %{entry: entry, tar: tar} do
    File.write!(Path.join(entry, ".ncc-links.json"), ~s({"priv": "../../../../deps/other/priv"}))
    assert {:error, {:reserved_name, ".ncc-links.json"}} = Tarball.pack(entry, tar, "jason")
    File.rm!(Path.join(entry, "priv"))
    assert {:error, {:reserved_name, ".ncc-links.json"}} = Tarball.pack(entry, tar, "jason")
    refute File.exists?(tar)
  end

  test "pack refuses an entry that holds nothing but links", %{entry: entry, tar: tar} do
    File.rm_rf!(Path.join(entry, "ebin"))
    File.rm_rf!(Path.join(entry, ".mix"))
    assert {:error, :empty_entry} = Tarball.pack(entry, tar, "jason")
  end

  test "unpack refuses any symlink member", %{tmp: tmp, out: out} do
    dir = Path.join(tmp, "withlink")
    File.mkdir_p!(Path.join(dir, "ebin"))
    File.ln_s!("y", Path.join(dir, "ebin/x"))
    tar = Path.join(tmp, "link.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"ebin", String.to_charlist(Path.join(dir, "ebin"))}],
        [:compressed]
      )

    File.mkdir_p!(out)
    assert {:error, {:member_type, :symlink, _}} = Tarball.unpack(tar, out)
  end

  @good "../../../../deps/x/priv"

  for {label, members} <- [
        {"a bad key", ~s({"ebin": "../../../../deps/x/priv"})},
        {"a target outside Mix's shape", ~s({"priv": "../../other"})},
        {"a name and target mismatch", ~s({"priv": "../../../../deps/x/include"})},
        {"a non-map", "[1]"},
        {"a non-string target", ~s({"priv": 1})},
        {"not JSON", "nope"},
        {"an oversized manifest",
         ~s({"priv": "../../../../deps/x/priv", "pad": "#{String.duplicate("a", 5000)}"})}
      ] do
    test "unpack refuses a manifest with #{label}", %{tmp: tmp, out: out} do
      File.mkdir_p!(out)
      tar = hostile(tmp, [{"ebin/a", "x"}, {".ncc-links.json", unquote(members)}])
      assert {:error, {:links, _}} = Tarball.unpack(tar, out)
    end
  end

  test "unpack refuses a manifest whose link name exists in the archive", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    tar = hostile(tmp, [{"priv/a", "x"}, {".ncc-links.json", ~s({"priv": "#{@good}"})}])
    assert {:error, {:links, {:exists, "priv"}}} = Tarball.unpack(tar, out)
  end

  test "unpack leaves a manifest-named file below the top level alone", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    tar = hostile(tmp, [{"ebin/.ncc-links.json", "[1]"}])
    assert :ok = Tarball.unpack(tar, out)
    assert File.exists?(Path.join(out, "ebin/.ncc-links.json"))
  end

  test "unpack refuses when the members sum past the extraction cap", %{
    entry: entry,
    tar: tar,
    out: out
  } do
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    File.mkdir_p!(out)
    assert {:error, :too_large} = Tarball.unpack(tar, out, max_extracted_bytes: 10)
    assert Tarball.max_extracted_bytes() == 2 * 1024 * 1024 * 1024
  end

  # A single 512-byte ustar header with no data, for a type erl_tar will not write.
  defp ustar_entry(name, typeflag) do
    name = String.pad_trailing(name, 100, <<0>>)
    mode = "0000644\0"
    uid = "0000000\0"
    gid = "0000000\0"
    size = "00000000000\0"
    mtime = "00000000000\0"

    rest =
      <<typeflag>> <>
        String.pad_trailing("", 100, <<0>>) <>
        "ustar\0" <> "00" <> String.pad_trailing("", 32 + 32 + 8 + 8 + 155, <<0>>)

    unsigned = name <> mode <> uid <> gid <> size <> mtime <> "        " <> rest
    chksum = unsigned |> :binary.bin_to_list() |> Enum.sum()

    header =
      name <>
        mode <>
        uid <>
        gid <>
        size <>
        mtime <>
        (chksum |> Integer.to_string(8) |> String.pad_leading(6, "0")) <> <<0, ?\s>> <> rest

    header = String.pad_trailing(header, 512, <<0>>)
    header <> :binary.copy(<<0>>, 1024)
  end
end
