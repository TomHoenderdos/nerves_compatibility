defmodule Compatibility.KinoAssetsTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Compatibility.KinoAssets

  @dir Path.expand("../fixtures/kino_assets", __DIR__)
  @module "Elixir.Kino.VegaLite"
  @chart "Elixir.KinoVegaLite.ChartCell"
  @cdn "https://repo.hex.pm/preview/kino_vega_lite/0.1.13/"

  defp archive(otp, d), do: hd(Path.wildcard(Path.join([@dir, otp, d, "*.tar.gz"])))
  defp tarball, do: File.read!(Path.join(@dir, "kino_vega_lite-0.1.13.tar"))
  defp beam(module), do: File.read!(Path.join(@dir, module <> ".beam"))

  defp input(otp \\ "otp28", d \\ "Kino_VegaLite", module \\ @module) do
    path = archive(otp, d)

    %{
      name: d <> "/" <> Path.basename(path),
      archive: File.read!(path),
      module: module,
      beam: beam(module),
      tarball: tarball(),
      app: "kino_vega_lite",
      version: "0.1.13"
    }
  end

  defp hash_of(%{name: name}), do: name |> Path.basename(".tar.gz")

  # --- hand-made archives ------------------------------------------------------

  defp pad(bin, n), do: bin <> :binary.copy(<<0>>, n - byte_size(bin))

  defp octal(n, width),
    do: String.pad_leading(Integer.to_string(n, 8), width - 1, "0") <> <<0>>

  defp header(name, size, over) do
    f =
      Map.merge(
        %{
          name: name,
          mode: "0100644\0",
          uid: "0000000\0",
          gid: "0000000\0",
          type: "0",
          link: "",
          magic: "ustar\0",
          version: "00",
          uname: "",
          gname: "",
          prefix: ""
        },
        over
      )

    head =
      pad(f.name, 100) <>
        f.mode <>
        f.uid <>
        f.gid <>
        octal(size, 12) <>
        octal(1_700_000_000, 12) <>
        "        " <>
        f.type <>
        pad(f.link, 100) <>
        f.magic <>
        f.version <>
        pad(f.uname, 32) <>
        pad(f.gname, 32) <>
        "0000000\0" <> "0000000\0" <> pad(f.prefix, 155) <> pad("", 12)

    sum = for <<b <- head>>, reduce: 0, do: (acc -> acc + b)
    <<pre::binary-148, _blank::binary-8, post::binary>> = head
    pre <> octal(sum, 7) <> " " <> post
  end

  defp block(bytes), do: bytes <> :binary.copy(<<0>>, rem(512 - rem(byte_size(bytes), 512), 512))

  defp ustar(members, over \\ %{}) do
    body =
      for {name, bytes} <- members,
          into: "",
          do: header(name, byte_size(bytes), over) <> block(bytes)

    body <> :binary.copy(<<0>>, 1024)
  end

  defp gz(tar, flg \\ 0, extra \\ "") do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, :default, :deflated, -15, 8, :default)
    deflated = z |> :zlib.deflate(tar, :finish) |> IO.iodata_to_binary()
    :ok = :zlib.deflateEnd(z)
    :zlib.close(z)

    <<0x1F, 0x8B, 8, flg, 0::32, 0, 3>> <>
      extra <> deflated <> <<:erlang.crc32(tar)::little-32, byte_size(tar)::little-32>>
  end

  # The real members of the real archive, packed again by hand.
  defp real_members, do: elem(KinoAssets.members(input().archive), 1)

  defp with_archive(bytes, over \\ %{}), do: Map.merge(input(), Map.put(over, :archive, bytes))

  # A beam of `module` whose `__assets_info__/0` holds `hash` and `cdn_url`,
  # compiled as Kino.JS's quote compiles it. Mix compiles test code without
  # debug info, so the module asks for its own.
  defp beam_with(module, hash, cdn_url) do
    name = String.replace_prefix(module, "Elixir.", "")

    source = """
    defmodule #{name} do
      @compile :debug_info

      def __assets_info__() do
        %{
          archive_path: Kino.JS.__assets_archive_path__(__MODULE__, #{inspect(hash)}),
          js_path: "main.js",
          hash: #{inspect(hash)},
          cdn_url: #{inspect(cdn_url)}
        }
      end
    end
    """

    capture_io(:stderr, fn -> send(self(), {:compiled, Code.compile_string(source)}) end)
    assert_received {:compiled, [{mod, bytes}]}
    :code.purge(mod)
    :code.delete(mod)
    bytes
  end

  # --- the proof -----------------------------------------------------------------

  test "the real archives pass, packed on OTP 27, 28 and 29" do
    for otp <- ~w(otp27 otp28 otp29),
        {d, module} <- [{"Kino_VegaLite", @module}, {"KinoVegaLite_ChartCell", @chart}] do
      assert {:ok, proof} = KinoAssets.verify(input(otp, d, module)), "#{otp} #{d}"
      assert proof.dir == d
      assert proof.hash == hash_of(input(otp, d, module))
      assert proof.hash == KinoAssets.hash(proof.members)
    end

    assert {:ok, %{assets_path: "lib/assets/vega_lite/build", members: [{"main.js", _}]}} =
             KinoAssets.verify(input())

    assert {:ok,
            %{assets_path: "lib/assets/chart_cell", members: [{"main.css", _}, {"main.js", _}]}} =
             KinoAssets.verify(input("otp28", "KinoVegaLite_ChartCell", @chart))
  end

  test "an archive packed again by hand with the same members passes" do
    assert {:ok, _} = KinoAssets.verify(with_archive(gz(ustar(real_members()))))
  end

  test "members added, removed, renamed or changed refuse" do
    [{name, bytes}] = real_members()

    for members <- [
          [{name, bytes}, {"extra.js", "x"}],
          [],
          [{"other.js", bytes}],
          [{name, bytes <> " "}]
        ] do
      assert {:error, "archive members differ from the package's assets" <> _} =
               KinoAssets.verify(with_archive(gz(ustar(members)))),
             inspect(Enum.map(members, &elem(&1, 0)))
    end
  end

  # The member name check refuses it before the members are compared: a
  # name with a segment that starts with `.` is not one Kino.JS packs.
  test "a dotfile member refuses, as Kino.JS's wildcard never sees one" do
    assert {:error, "tar member name is not a safe relative path"} =
             KinoAssets.verify(with_archive(gz(ustar([{".hidden", "x"} | real_members()]))))

    assert {:error, "tar member name is not a safe relative path"} =
             KinoAssets.verify(with_archive(gz(ustar([{"sub/.hidden", "x"} | real_members()]))))
  end

  test "the archive name: another module's directory, or a hash one character off" do
    i = input()
    [dir, file] = String.split(i.name, "/")
    off = String.replace(file, ~r/^./, fn c -> if c == "a", do: "b", else: "a" end)

    assert {:error, "archive is not in Elixir.Kino.VegaLite's directory"} =
             KinoAssets.verify(%{i | name: "KinoVegaLite_ChartCell/" <> file})

    assert {:error, "archive name's hash is not the module's"} =
             KinoAssets.verify(%{i | name: dir <> "/" <> off})

    assert {:error, "archive name is not <dir>/<26 base32>.tar.gz"} =
             KinoAssets.verify(%{i | name: dir <> "/x.tar.gz"})
  end

  test "the beam: another hash literal, inline assets, another assets_path, no debug info" do
    i = input()
    h = hash_of(i)

    assert {:error, "archive name's hash is not the module's"} =
             KinoAssets.verify(%{
               i
               | beam:
                   beam_with(
                     @module,
                     String.duplicate("a", 26),
                     @cdn <> "lib/assets/vega_lite/build"
                   )
             })

    assert {:error, "inline or unrecognised Kino.JS assets"} =
             KinoAssets.verify(%{i | beam: beam_with(@module, h, nil)})

    assert {:error, "archive members differ" <> _} =
             KinoAssets.verify(%{
               i
               | beam: beam_with(@module, h, @cdn <> "lib/assets/chart_cell")
             })

    assert {:error, "assets_path is not this release's" <> _} =
             KinoAssets.verify(%{
               i
               | beam:
                   beam_with(
                     @module,
                     h,
                     "https://repo.hex.pm/preview/kino_vega_lite/0.1.12/lib/assets/vega_lite/build"
                   )
             })

    assert {:error, "assets_path is not this release's" <> _} =
             KinoAssets.verify(%{i | beam: beam_with(@module, h, @cdn <> "../lib")})

    {:ok, {_mod, stripped}} = :beam_lib.strip(i.beam)

    assert {:error, "inline or unrecognised Kino.JS assets"} =
             KinoAssets.verify(%{i | beam: stripped})

    assert {:error, "inline or unrecognised Kino.JS assets"} =
             KinoAssets.verify(%{i | beam: beam(@chart)})
  end

  test "tar headers: pax, a uid, mode 0755, a link member, a prefix, a bad checksum" do
    members = real_members()

    for {over, why} <- [
          {%{type: "x"}, "tar archive has a pax or GNU header"},
          {%{type: "L"}, "tar archive has a pax or GNU header"},
          {%{type: "2", link: "main.js"}, "tar member is not a regular file"},
          {%{uid: "0001750\0"}, "tar member owner is not 0"},
          {%{mode: "0100755\0"}, "tar member mode is not 0100644"},
          {%{uname: "tom"}, "tar member names a link or an owner"},
          {%{prefix: "lib"}, "tar member name has a prefix"},
          {%{magic: "ustar ", version: " \0"}, "tar header is not ustar"}
        ] do
      assert {:error, ^why} = KinoAssets.verify(with_archive(gz(ustar(members, over)))), why
    end

    <<head::binary-148, _sum::binary-8, rest::binary>> = ustar(members)

    assert {:error, "tar header checksum does not match"} =
             KinoAssets.verify(with_archive(gz(head <> "0000000 " <> rest)))
  end

  test "tar framing: data not padded with zeros, no end, bytes after the end" do
    [{name, bytes}] = real_members()
    good = ustar([{name, bytes}])
    data_end = 512 + byte_size(bytes)
    <<pre::binary-size(^data_end), pad_byte, post::binary>> = good

    assert {:error, "tar data is not padded with zeros"} =
             KinoAssets.verify(with_archive(gz(pre <> <<pad_byte + 1>> <> post)))

    assert {:error, "tar archive does not end"} =
             KinoAssets.verify(with_archive(gz(binary_part(good, 0, byte_size(good) - 1024))))

    assert {:error, "bytes after the tar archive's end"} =
             KinoAssets.verify(with_archive(gz(good <> "x" <> :binary.copy(<<0>>, 511))))
  end

  test "gzip: FNAME set, a second member, trailing bytes, a bad CRC, over the cap" do
    tar = ustar(real_members())

    assert {:error, "gzip header has flags set"} =
             KinoAssets.verify(with_archive(gz(tar, 0x08, "main.tar\0")))

    assert {:error, "not one gzip member that ends at the file's end"} =
             KinoAssets.verify(with_archive(gz(tar) <> gz(tar)))

    assert {:error, "not one gzip member that ends at the file's end"} =
             KinoAssets.verify(with_archive(gz(tar) <> <<0, 0, 0>>))

    good = gz(tar)
    bad_crc = binary_part(good, 0, byte_size(good) - 8) <> <<0::32, byte_size(tar)::little-32>>

    assert {:error, "not one gzip member that ends at the file's end"} =
             KinoAssets.verify(with_archive(bad_crc))

    big = gz(:binary.copy(<<0>>, 64 * 1024 * 1024 + 1))
    assert {:error, "archive inflates past 64 MiB"} = KinoAssets.verify(with_archive(big))
  end

  test "a non-regular entry under assets_path in the tarball refuses" do
    # The writer's tarball with lib/assets/vega_lite/build/link -> main.js added.
    {:ok, entries} = :erl_tar.extract({:binary, tarball()}, [:memory])
    {_, gz} = List.keyfind(entries, ~c"contents.tar.gz", 0)
    work = Path.join(System.tmp_dir!(), "ka-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    :ok = :erl_tar.extract({:binary, gz}, [:compressed, {:cwd, String.to_charlist(work)}])
    File.ln_s!("main.js", Path.join(work, "lib/assets/vega_lite/build/link"))
    files = work |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.reject(&File.dir?/1)
    contents = Path.join(work, "contents.tar.gz")

    names =
      for f <- files, do: {String.to_charlist(Path.relative_to(f, work)), String.to_charlist(f)}

    :ok = :erl_tar.create(String.to_charlist(contents), names, [:compressed])
    outer = for {n, b} <- entries, n != ~c"contents.tar.gz", do: {n, b}
    path = Path.join(work, "outer.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(path),
        outer ++ [{~c"contents.tar.gz", File.read!(contents)}]
      )

    assert {:error, "non-regular file under lib/assets/vega_lite/build in the tarball"} =
             KinoAssets.verify(%{input() | tarball: File.read!(path)})

    File.rm_rf!(work)
  end

  # Review Focus 4.
  test "long, non-ASCII and spaced member names never raise" do
    long = String.duplicate("a", 101)

    assert {:error, "tar member name has a prefix"} =
             KinoAssets.verify(
               with_archive(gz(ustar([{"x", "y"}], %{prefix: long |> binary_part(0, 100)})))
             )

    for name <- ["ünïcødé.js", "with space.js", "dir/sub/x.js"] do
      assert {:ok, [{^name, "y"}]} = KinoAssets.members(gz(ustar([{name, "y"}])))
    end

    assert {:error, _} = KinoAssets.members(gz(ustar([{"../up.js", "y"}])))
    assert {:error, _} = KinoAssets.members(gz(ustar([{"/abs.js", "y"}])))

    for _ <- 1..200 do
      garbage = :crypto.strong_rand_bytes(:rand.uniform(4096))
      assert {:error, _} = KinoAssets.verify(with_archive(garbage))

      assert {:error, _} =
               KinoAssets.verify(with_archive(<<0x1F, 0x8B, 8, 0, 0::32, 0, 3>> <> garbage))
    end

    assert {:error, _} = KinoAssets.verify(%{input() | tarball: "nope"})
    assert {:error, _} = KinoAssets.verify(%{input() | beam: "nope"})
    assert {:error, _} = KinoAssets.verify(%{})
  end

  describe "exports_assets_info/1" do
    # A beam, IFF chunks by hand: `atoms` the atom table (OTP 28's compact
    # lengths, as `count` negative says), `exports` `{atom index, arity}`.
    defp iff(atoms, exports, compact? \\ true) do
      table =
        if compact? do
          <<-length(atoms)::signed-32>> <>
            for(a <- atoms, into: "", do: compact_len(byte_size(a)) <> a)
        else
          <<length(atoms)::signed-32>> <> for(a <- atoms, into: "", do: <<byte_size(a)>> <> a)
        end

      expt =
        <<length(exports)::32>> <>
          for({i, arity} <- exports, into: "", do: <<i::32, arity::32, 1::32>>)

      chunks = chunk("AtU8", table) <> chunk("ExpT", expt) <> chunk("Code", "x")
      <<"FOR1", byte_size(chunks) + 4::32, "BEAM">> <> chunks
    end

    defp chunk(id, data) do
      pad = rem(4 - rem(byte_size(data), 4), 4)
      id <> <<byte_size(data)::32>> <> data <> :binary.copy(<<0>>, pad)
    end

    defp compact_len(n) when n < 16, do: <<n::4, 0::1, 0::3>>
    defp compact_len(n), do: <<div(n, 256)::3, 0::1, 1::1, 0::3, rem(n, 256)>>

    test "the real asset modules export it, others do not" do
      assert KinoAssets.exports_assets_info(beam(@module)) == {:ok, @module, true}
      assert KinoAssets.exports_assets_info(beam(@chart)) == {:ok, @chart, true}

      assert {:ok, "lists", false} =
               KinoAssets.exports_assets_info(File.read!(:code.which(:lists)))
    end

    test "both atom table shapes, and long names" do
      long = "Elixir." <> String.duplicate("M", 200)

      for compact? <- [true, false] do
        assert KinoAssets.exports_assets_info(iff([long, "__assets_info__"], [{2, 0}], compact?)) ==
                 {:ok, long, true}

        assert KinoAssets.exports_assets_info(
                 iff(["Elixir.M", "__assets_info__"], [{2, 1}], compact?)
               ) ==
                 {:ok, "Elixir.M", false}
      end
    end

    test "anything else is :error, never a raise" do
      good = beam(@module)

      for bad <- [
            "",
            "not a beam",
            :zlib.gzip(good),
            binary_part(good, 0, 100),
            iff(["Elixir.M"], [{9, 0}]),
            iff(["Elixir.M", "__assets_info__"], [{0, 0}]),
            <<"FOR1", 4::32, "BEAM">>
          ] do
        assert KinoAssets.exports_assets_info(bad) == :error,
               inspect(binary_part(bad, 0, min(16, byte_size(bad))))
      end

      for _ <- 1..200 do
        junk = <<"FOR1", 1000::32, "BEAM">> <> :crypto.strong_rand_bytes(996)
        assert KinoAssets.exports_assets_info(junk) == :error
      end
    end
  end
end
