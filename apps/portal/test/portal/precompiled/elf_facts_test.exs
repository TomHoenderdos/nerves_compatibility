defmodule Portal.Precompiled.ElfFactsTest do
  use ExUnit.Case, async: true

  alias Portal.Precompiled.ElfFacts

  @fixtures Path.expand("../../../../compatibility/test/fixtures/elf", __DIR__)

  defp fixture(name), do: File.read!(Path.join(@fixtures, name))

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  # The priv entries of `{path, content}` files and the reader of their blobs.
  defp priv(files) do
    blobs = Map.new(files, fn {_path, content} -> {sha(content), content} end)

    entries =
      Enum.map(files, fn {path, content} -> %{"path" => path, "sha256" => sha(content)} end)

    read_blob = fn sha ->
      case Map.fetch(blobs, sha) do
        {:ok, content} -> {:ok, content}
        :error -> {:error, :enoent}
      end
    end

    {entries, read_blob}
  end

  defp compute(files) do
    {entries, read_blob} = priv(files)
    ElfFacts.compute(entries, read_blob)
  end

  test "a NIF is native and portable, with its needs" do
    assert compute([{"priv/gpio_nif.so", fixture("nif_aarch64.so")}]) == %{
             native: true,
             portable: true,
             needs: %{
               "libc.so.6" => ["GLIBC_2.17"],
               "ld-linux-aarch64.so.1" => ["GLIBC_2.17"]
             }
           }
  end

  test "a file that is not ELF is neither native nor a reason to refuse" do
    assert compute([{"priv/data.json", ~s({"beam": "ish"})}]) == %{
             native: false,
             portable: true,
             needs: %{}
           }
  end

  test "a relocatable object beside a NIF is not portable" do
    assert %{native: true, portable: false} =
             compute([
               {"priv/gpio_nif.so", fixture("nif_aarch64.so")},
               {"priv/obj.o", fixture("rel_aarch64.o")}
             ])
  end

  test "an ELF file that does not read is native and not portable" do
    assert %{native: true, portable: false} =
             compute([{"priv/broken.so", fixture("noshdr_aarch64.so")}])
  end

  test "needs are the per-soname union, sorted and deduplicated" do
    %{needs: needs} =
      compute([
        {"priv/gpio_nif.so", fixture("nif_aarch64.so")},
        {"priv/libz.so.1", fixture("libz_aarch64.so.1")}
      ])

    assert needs == %{
             "libc.so.6" => ["GLIBC_2.17"],
             "ld-linux-aarch64.so.1" => ["GLIBC_2.17"]
           }

    # A library needed with no version still counts as needed.
    assert %{needs: %{"libc.so" => []}} = compute([{"priv/x.so", fixture("nif_x86_64.so")}])
  end

  test "a library the build ships itself is not a need, matched by file name" do
    # The NIF needs ld-linux-aarch64.so.1; a copy under priv/lib provides it.
    %{needs: needs} =
      compute([
        {"priv/gpio_nif.so", fixture("nif_aarch64.so")},
        {"priv/lib/ld-linux-aarch64.so.1", fixture("libz_aarch64.so.1")}
      ])

    assert needs == %{"libc.so.6" => ["GLIBC_2.17"]}
  end

  test "a library the build ships itself is not a need, matched by its soname" do
    {:ok, libz} = Compatibility.Elf.read(fixture("libz_aarch64.so.1"))
    assert libz.soname == "libz.so.1"

    needs = %{"libz.so.1" => ["ZLIB_1.2.0"], "libc.so.6" => ["GLIBC_2.17"]}

    # Shipped under another file name, found by DT_SONAME.
    assert ElfFacts.without_bundled(needs, [{"priv/lib/libz-1.3.so", libz}]) ==
             %{"libc.so.6" => ["GLIBC_2.17"]}

    # Shipped under its soname, with no DT_SONAME of its own.
    assert ElfFacts.without_bundled(needs, [{"priv/lib/libz.so.1", %{soname: nil}}]) ==
             %{"libc.so.6" => ["GLIBC_2.17"]}

    assert ElfFacts.without_bundled(needs, []) == needs
  end

  test "a blob that cannot be read is an error naming it" do
    entries = [%{"path" => "priv/gone.so", "sha256" => String.duplicate("a", 64)}]

    assert ElfFacts.compute(entries, fn _sha -> {:error, :enoent} end) ==
             {:error, {:blob, String.duplicate("a", 64)}}
  end
end
