defmodule NccWorker.Portability.TarTimesTest do
  # Two `.tar`/`.tar.gz` files from two builds are the same when only their
  # times differ (judge revision 21), and only then.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.TarTimes

  @moduletag :tmp_dir

  @members [{"main.js", "export function init() {}"}, {"main.css", ".box {}"}]

  # What `:erl_tar` writes from binaries, as kino's `package_assets!/2` does.
  defp tar(dir, members, opts) do
    path = Path.join(dir, "t-#{System.unique_integer([:positive])}.tar")
    entries = for {name, bytes} <- members, do: {String.to_charlist(name), bytes}
    :ok = :erl_tar.create(String.to_charlist(path), entries, opts)
    File.read!(path)
  end

  defp gz(dir, members, mtime), do: tar(dir, members, [:compressed, {:mtime, mtime}])

  test "gzipped archives whose members' times alone differ are the same", %{tmp_dir: dir} do
    a = gz(dir, @members, 1_700_000_000)
    b = gz(dir, @members, 1_700_000_042)
    assert a != b
    assert TarTimes.same?("assets/X/abc.tar.gz", a, b)
    assert TarTimes.same?("abc.tar.gz", a, a)
  end

  test "plain archives whose members' times alone differ are the same", %{tmp_dir: dir} do
    a = tar(dir, @members, mtime: 5)
    b = tar(dir, @members, mtime: 6)
    assert a != b
    assert TarTimes.same?("x.tar", a, b)
  end

  test "the gzip header's MTIME and OS bytes alone may differ", %{tmp_dir: dir} do
    <<head::binary-4, _mtime::binary-4, xfl, _os, rest::binary>> = gz(dir, @members, 5)
    other = <<head::binary, 1, 2, 3, 4, xfl, 3, rest::binary>>
    assert TarTimes.same?("x.tar.gz", head <> <<0::32, xfl, 19>> <> rest, other)

    # Not XFL.
    refute TarTimes.same?(
             "x.tar.gz",
             other,
             <<head::binary, 1, 2, 3, 4, xfl + 2, 3, rest::binary>>
           )
  end

  test "a content byte, a name, the mode or the member order refuses", %{tmp_dir: dir} do
    a = gz(dir, @members, 5)

    for b <- [
          gz(dir, [{"main.js", "export function init() {}!"}, {"main.css", ".box {}"}], 6),
          gz(dir, [{"main.js", "export function init() {]"}, {"main.css", ".box {}"}], 6),
          gz(dir, [{"main2.js", "export function init() {}"}, {"main.css", ".box {}"}], 6),
          gz(dir, Enum.reverse(@members), 6),
          gz(dir, Enum.take(@members, 1), 6),
          tar(dir, @members, [:compressed, mtime: 6, uid: 1000]),
          tar(dir, @members, [:compressed, mtime: 6, gid: 1000])
        ] do
      refute TarTimes.same?("x.tar.gz", a, b)
      refute TarTimes.same?("x.tar.gz", b, a)
    end

    # The mode: a member's mode bits, with its checksum made valid again.
    plain = tar(dir, @members, mtime: 5)
    assert TarTimes.same?("x.tar", plain, retimed(plain, 0, 9))
    refute TarTimes.same?("x.tar", plain, put_field(plain, 0, 100, "0000755\0"))
  end

  test "a corrupt, truncated or padded gzip refuses", %{tmp_dir: dir} do
    a = gz(dir, @members, 5)
    b = gz(dir, @members, 6)
    size = byte_size(b)
    <<head::binary-20, _byte, tail::binary>> = b

    for bad <- [
          head <> <<0xFF>> <> tail,
          binary_part(b, 0, size - 1),
          binary_part(b, 0, size - 8),
          b <> "x",
          b <> b,
          binary_part(b, 0, size - 8) <> <<0>> <> binary_part(b, size - 8, 8),
          "not gzip at all"
        ] do
      refute TarTimes.same?("x.tar.gz", a, bad)
    end
  end

  test "another format or a broken header refuses", %{tmp_dir: dir} do
    a = gz(dir, @members, 5)
    b = gz(dir, @members, 6)
    refute TarTimes.same?("x.zip", a, b)
    refute TarTimes.same?("x.tgz", a, b)
    refute TarTimes.same?("x.js", a, a)

    plain = tar(dir, @members, mtime: 5)
    # The checksum no longer adds up.
    broken = put_binary(plain, 0, "Main.js")
    refute TarTimes.same?("x.tar", broken, broken)
    # A size in base-256.
    big = put_field(plain, 0, 124, <<0x80>> <> :binary.copy(<<0>>, 11))
    refute TarTimes.same?("x.tar", big, big)
    refute TarTimes.same?("x.tar", plain, plain <> <<0::4096>>)
  end

  test "a pax header's time records alone may differ", %{tmp_dir: dir} do
    _ = dir
    a = pax_tar([{"path", "a.js"}, {"mtime", "1700000000.123"}], "x")
    b = pax_tar([{"path", "a.js"}, {"mtime", "17"}, {"atime", "1"}], "x")
    assert TarTimes.same?("x.tar", a, b)

    refute TarTimes.same?("x.tar", a, pax_tar([{"path", "b.js"}, {"mtime", "1"}], "x"))
    refute TarTimes.same?("x.tar", a, pax_tar([{"path", "a.js"}, {"mtime", "1"}], "y"))
    refute TarTimes.same?("x.tar", a, pax_tar([{"path", "a.js"}, {"uid", "1"}], "x"))
  end

  # A pax `size` record, not the ustar size field, frames the member's data
  # for a POSIX reader (bsdtar, GNU tar; `:erl_tar` ignores it): an archive
  # whose ustar size says 0 hides a 512-byte data block that, read as a
  # header, may differ in its "mtime" and "checksum" bytes, which bsdtar
  # extracts as `a.js`'s content. Such an archive refuses.
  test "a pax size record refuses: it frames the data the header does not" do
    hidden = header("hidden", 0, ?0)
    a = pax_framed(retimed(hidden, 0, 1))
    b = pax_framed(retimed(hidden, 0, 2))
    assert a != b

    refute TarTimes.same?("x.tar", a, b)
    refute TarTimes.same?("x.tar", a, a)

    # Solaris's `X` header, which bsdtar and GNU tar read as pax.
    refute TarTimes.same?("x.tar", pax_framed(retimed(hidden, 0, 1), ?X), a)
    x = pax_framed(retimed(hidden, 0, 1), ?X)
    refute TarTimes.same?("x.tar", x, pax_framed(retimed(hidden, 0, 2), ?X))
  end

  defp pax_framed(block, type \\ ?x) do
    data = pax_record({"size", "512"})

    header("PaxHeaders/a.js", byte_size(data), type) <>
      pad(data) <> header("a.js", 0, ?0) <> block <> <<0::size(1024 * 8)>>
  end

  # --- hand-made archives ------------------------------------------------------

  # A ustar archive of one pax header with `records`, then `a.js` holding `body`.
  defp pax_tar(records, body) do
    data = Enum.map_join(records, &pax_record/1)

    header("PaxHeaders/a.js", byte_size(data), ?x) <>
      pad(data) <>
      header("a.js", byte_size(body), ?0) <> pad(body) <> <<0::size(1024 * 8)>>
  end

  # A record's length counts its own digits.
  defp pax_record({key, value}) do
    text = " #{key}=#{value}\n"
    len = Enum.find(1..10_000, &(&1 == byte_size(text) + byte_size(Integer.to_string(&1))))
    "#{len}" <> text
  end

  defp header(name, size, type) do
    fields =
      field(name, 100) <>
        field("0000644", 8) <>
        field("0000000", 8) <>
        field("0000000", 8) <>
        field(octal(size, 11), 12) <>
        field(octal(0, 11), 12) <>
        "        " <>
        <<type>> <>
        field("", 100) <>
        "ustar\0" <>
        "00" <>
        field("", 32) <>
        field("", 32) <>
        field("", 8) <> field("", 8) <> field("", 155) <> field("", 12)

    with_checksum(fields)
  end

  defp field(text, len), do: text <> :binary.copy(<<0>>, len - byte_size(text))
  defp octal(n, width), do: n |> Integer.to_string(8) |> String.pad_leading(width, "0")
  defp pad(data), do: data <> :binary.copy(<<0>>, rem(512 - rem(byte_size(data), 512), 512))

  defp with_checksum(header) do
    sum = for <<byte <- header>>, reduce: 0, do: (acc -> acc + byte)
    put_binary(header, 148, octal(sum, 6) <> <<0, ?\s>>)
  end

  # The header at block `at` with its mtime set to `mtime`, checksum redone.
  defp retimed(tar, at, mtime), do: put_field(tar, at, 136, field(octal(mtime, 11), 12))

  # The header at block `at` with `bytes` at `offset`, checksum redone.
  defp put_field(tar, at, offset, bytes) do
    header = binary_part(tar, at * 512, 512)
    header = header |> put_binary(offset, bytes) |> put_binary(148, "        ") |> with_checksum()
    put_binary(tar, at * 512, header)
  end

  defp put_binary(bin, at, bytes),
    do:
      binary_part(bin, 0, at) <>
        bytes <> binary_part(bin, at + byte_size(bytes), byte_size(bin) - at - byte_size(bytes))
end
