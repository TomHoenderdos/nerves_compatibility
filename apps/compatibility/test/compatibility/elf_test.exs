defmodule Compatibility.ElfTest do
  use ExUnit.Case, async: true
  alias Compatibility.Elf

  @dir Path.expand("../fixtures/elf", __DIR__)
  defp read!(name), do: Elf.read_file(Path.join(@dir, name))

  test "aarch64 NIF: class, machine, type, needed and version needs" do
    assert {:ok, info} = read!("nif_aarch64.so")
    assert %{class: 64, machine: :aarch64, type: :dyn} = info
    assert info.needed == ["libc.so.6", "ld-linux-aarch64.so.1"]

    assert info.needs == %{
             "libc.so.6" => ["GLIBC_2.17"],
             "ld-linux-aarch64.so.1" => ["GLIBC_2.17"]
           }

    assert info.defines == []
  end

  test "armv6 NIF is 32-bit arm" do
    assert {:ok, %{class: 32, machine: :arm, type: :dyn, needs: needs}} = read!("nif_armv6.so")
    assert needs == %{"libc.so.6" => ["GLIBC_2.4"], "ld-linux-armhf.so.3" => ["GLIBC_2.4"]}
  end

  test "musl x86_64 NIF needs libc.so with no versions" do
    assert {:ok, %{machine: :x86_64, needed: ["libc.so"], needs: needs}} = read!("nif_x86_64.so")
    assert needs == %{}
  end

  test "libz defines its ZLIB versions and names its soname" do
    assert {:ok, %{soname: "libz.so.1", defines: defines}} = read!("libz_aarch64.so.1")
    assert "ZLIB_1.2.0" in defines and "ZLIB_1.3.2" in defines
    refute "libz.so.1" in defines
    assert length(defines) == 16
  end

  test "ET_REL is read as :rel and is not a portable type" do
    assert {:ok, %{type: :rel}} = read!("rel_aarch64.o")
    refute Elf.portable_type?(:rel)
    assert Elf.portable_type?(:dyn) and Elf.portable_type?(:exec)
  end

  test "not ELF, truncated, big-endian, bad class" do
    assert Elf.read("hello") == :not_elf
    assert Elf.read(<<0x7F, "ELF", 2, 1>>) == {:error, :truncated}
    {:ok, so} = File.read(Path.join(@dir, "nif_aarch64.so"))
    assert Elf.read(binary_part(so, 0, 200)) in [{:error, :truncated}, {:error, :bounds}]
    <<head::binary-size(5), _::8, rest::binary>> = so
    assert Elf.read(head <> <<2>> <> rest) == {:error, :big_endian}
    <<magic::binary-size(4), _::8, rest2::binary>> = so
    assert Elf.read(magic <> <<9>> <> rest2) == {:error, :bad_class}
  end

  test "an absurd section count is a bounds error" do
    {:ok, so} = File.read(Path.join(@dir, "nif_aarch64.so"))
    # e_shnum is at offset 60 in ELF64
    <<pre::binary-size(60), _::little-16, post::binary>> = so
    assert Elf.read(pre <> <<0xFFFF::little-16>> <> post) == {:error, :bounds}
  end

  test "a dynamic object without section headers has no readable dynamic section" do
    assert read!("noshdr_aarch64.so") == {:error, :no_dynamic}
    assert read!("shnum0_aarch64.so") == {:error, :no_dynamic}
  end

  test "a static executable reads with empty needs" do
    {:ok, so} = File.read(Path.join(@dir, "nif_aarch64.so"))
    # e_type @16, e_phnum @56, e_shnum @60 in ELF64
    <<pre::binary-size(16), _::little-16, mid::binary-size(38), _::little-16,
      mid2::binary-size(2), _::little-16, post::binary>> = so

    static =
      pre <> <<2::little-16>> <> mid <> <<0::little-16>> <> mid2 <> <<0::little-16>> <> post

    assert {:ok, %{type: :exec, needed: [], needs: %{}, defines: [], soname: nil}} =
             Elf.read(static)
  end

  test "a program header table outside the file is a bounds error" do
    {:ok, so} = File.read(Path.join(@dir, "nif_aarch64.so"))
    # e_phoff is at offset 32 in ELF64
    <<pre::binary-size(32), _::little-64, post::binary>> = so
    assert Elf.read(pre <> <<byte_size(so)::little-64>> <> post) == {:error, :bounds}
  end

  test "corrupted bytes never raise" do
    {:ok, so} = File.read(Path.join(@dir, "libz_aarch64.so.1"))
    <<_::binary-size(40), shoff::little-64, _::binary>> = so
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..300 do
      corrupt =
        Enum.reduce(1..:rand.uniform(4), so, fn _, acc ->
          at = corrupt_at(byte_size(acc), shoff)
          <<pre::binary-size(at), _::8, post::binary>> = acc
          pre <> <<:rand.uniform(256) - 1>> <> post
        end)

      assert read_outcome(Elf.read(corrupt))
    end
  end

  defp read_outcome({:ok, %{needed: needed, needs: needs, defines: defines}}),
    do: is_list(needed) and is_map(needs) and is_list(defines)

  defp read_outcome(:not_elf), do: true

  defp read_outcome({:error, reason}),
    do: reason in [:bounds, :big_endian, :truncated, :bad_class, :no_dynamic]

  # The bytes land in the ELF header, the section header table or the first
  # 8 KiB, which hold the dynamic and version sections: the parts the reader
  # follows.
  defp corrupt_at(size, shoff) do
    case :rand.uniform(3) do
      1 -> :rand.uniform(64) - 1
      2 -> shoff + :rand.uniform(size - shoff) - 1
      3 -> :rand.uniform(8192) - 1
    end
  end

  test "more version entries than the budget is a bounds error" do
    {:ok, so} = File.read(Path.join(@dir, "libz_aarch64.so.1"))
    <<_::binary-size(40), shoff::little-64, _::binary-size(10), shnum::little-16, _::binary>> = so

    # sh_info sits 44 bytes into an ELF64 section header
    at =
      Enum.find_value(0..(shnum - 1), fn i ->
        header = shoff + i * 64
        <<_::binary-size(header + 4), type::little-32, _::binary>> = so
        if type == 0x6FFFFFFD, do: header + 44
      end)

    <<pre::binary-size(at), _::little-32, post::binary>> = so
    assert Elf.read(pre <> <<5000::little-32>> <> post) == {:error, :bounds}
  end

  test "read_file refuses a missing file" do
    assert Elf.read_file(Path.join(@dir, "absent.so")) == {:error, :enoent}
  end

  @tag :tmp_dir
  test "read_file refuses a file over 64 MiB before reading it", %{tmp_dir: dir} do
    path = Path.join(dir, "big.so")
    {:ok, io} = :file.open(path, [:write, :raw, :binary])
    :ok = :file.pwrite(io, 64 * 1024 * 1024, <<0>>)
    :ok = :file.close(io)
    assert Elf.read_file(path) == {:error, :too_large}
  end

  test "parse_version and satisfied?" do
    assert Elf.parse_version("GLIBC_2.17") == {"GLIBC", [2, 17]}
    assert Elf.parse_version("CXXABI_1.3.15") == {"CXXABI", [1, 3, 15]}
    assert Elf.parse_version("GLIBC_PRIVATE") == nil
    assert Elf.parse_version("V1") == nil
    assert Elf.satisfied?(["GLIBC_2.17"], ["GLIBC_2.4", "GLIBC_2.17", "GLIBC_2.38"]) == :ok
    assert Elf.satisfied?(["GLIBC_2.17"], ["GLIBC_2.4", "GLIBC_2.38"]) == {:missing, "GLIBC_2.17"}
    assert Elf.satisfied?(["GLIBCXX_3.4.32"], ["GLIBCXX_3.4.31"]) == {:missing, "GLIBCXX_3.4.32"}
    assert Elf.satisfied?(["GLIBC_PRIVATE", "ZLIB_1.2.9"], ["ZLIB_1.2.9", "ZLIB_1.3.2"]) == :ok
    assert Elf.satisfied?(["OPENSSL_3.0.0"], []) == {:missing, "OPENSSL_3.0.0"}
  end

  test "series_from_version" do
    assert Elf.series_from_version("15.3.1") == "15.3"
    assert Elf.series_from_version("15.3") == nil
    assert Elf.series_from_version("junk") == nil
  end
end
