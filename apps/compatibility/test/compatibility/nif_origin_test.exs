defmodule Compatibility.NifOriginTest do
  use ExUnit.Case, async: true

  alias Compatibility.NifOrigin

  @so "\x7FELF fake nif bytes"
  @archive_name "libfx-v0.1.0-nif-2.16-x86_64-unknown-linux-gnu.so.tar.gz"

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tar_gz(files) do
    path = Path.join(System.tmp_dir!(), "nif-origin-#{System.unique_integer([:positive])}.tgz")
    entries = for {name, bytes} <- files, do: {String.to_charlist(name), bytes}
    :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  # A Hex tarball: an outer tar of VERSION, CHECKSUM, metadata.config and
  # contents.tar.gz, the last holding `files`.
  defp hex_tarball(files) do
    path = Path.join(System.tmp_dir!(), "nif-origin-hex-#{System.unique_integer([:positive])}")

    :ok =
      :erl_tar.create(String.to_charlist(path), [
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", ~s({<<"name">>,<<"fx">>}.\n)},
        {~c"contents.tar.gz", tar_gz(files)}
      ])

    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  defp checksum_exs(map) do
    body = Enum.map_join(map, ",\n", fn {k, v} -> ~s(  "#{k}" => "#{v}") end)
    "%{\n" <> body <> "\n}\n"
  end

  describe "checksum_file?/1" do
    test "rustler_precompiled's and elixir_make's names" do
      assert NifOrigin.checksum_file?("checksum-Elixir.Tokenizers.Native.exs")
      assert NifOrigin.checksum_file?("checksum.exs")
      refute NifOrigin.checksum_file?("lib/checksum.exs")
      refute NifOrigin.checksum_file?("../checksum.exs")
      refute NifOrigin.checksum_file?("checksum-a/b.exs")
      refute NifOrigin.checksum_file?("checksums.txt")
      refute NifOrigin.checksum_file?(nil)
    end
  end

  describe "parse/1" do
    test "a literal map of archive names to sha256 sums" do
      hex = sha("a")

      assert NifOrigin.parse(checksum_exs(%{"a.tar.gz" => "sha256:" <> hex})) ==
               {:ok, %{"a.tar.gz" => hex}}

      assert NifOrigin.parse("%{}") == {:ok, %{}}
    end

    test "anything but literal data is refused, never evaluated" do
      hex = sha("a")

      for source <- [
            ~s|%{"a" => "sha256:" <> "#{hex}"}|,
            ~s|%{"a" => System.cmd("touch", ["/tmp/x"])}|,
            ~s|File.write!("/tmp/x", "y"); %{}|,
            ~s|%{a: "sha256:#{hex}"}|,
            ~s|%{"a" => "sha512:#{hex}"}|,
            ~s|%{"a" => "sha256:#{String.upcase(hex)}"}|,
            ~s|%{"a" => "sha256:#{hex}", "a" => "sha256:#{hex}"}|,
            ~s|%{"a/b" => "sha256:#{hex}"}|,
            ~s|["a"]|,
            "%{",
            <<0xFF, 0xFE>>
          ] do
        assert NifOrigin.parse(source) == :error, source
      end
    end

    test "an oversized file is refused before it is read" do
      assert NifOrigin.parse(String.duplicate(" ", 1024 * 1024 + 1)) == :error
    end
  end

  describe "checksum_files/1" do
    test "the checksum files at the root of the package's contents" do
      hex = sha("a")
      body = checksum_exs(%{"a.tar.gz" => "sha256:" <> hex})

      tarball =
        hex_tarball(%{
          "checksum-Elixir.Fx.Native.exs" => body,
          "lib/fx.ex" => "defmodule Fx do end",
          "lib/checksum.exs" => body
        })

      assert NifOrigin.checksum_files(tarball) ==
               {:ok, %{"checksum-Elixir.Fx.Native.exs" => %{"a.tar.gz" => hex}}}
    end

    test "a package without checksum files has none" do
      assert NifOrigin.checksum_files(hex_tarball(%{"lib/fx.ex" => "x"})) == {:ok, %{}}
    end

    test "an unreadable checksum file or tarball is an error" do
      assert NifOrigin.checksum_files(hex_tarball(%{"checksum.exs" => "Foo.bar()"})) == :error
      assert NifOrigin.checksum_files("not a tarball") == :error
      assert NifOrigin.checksum_files(nil) == :error
    end
  end

  describe "verify/3" do
    setup do
      archive = tar_gz(%{"libfx-v0.1.0-nif-2.16-x86_64-unknown-linux-gnu.so" => @so})
      checksums = %{"checksum-Elixir.Fx.Native.exs" => %{@archive_name => sha(archive)}}
      %{archive: archive, checksums: checksums}
    end

    test "a native file that is a member of a listed archive has its origin",
         %{archive: archive, checksums: checksums} do
      files = [%{"path" => "native/libfx.so", "sha256" => sha(@so)}]

      assert NifOrigin.verify(files, checksums, %{@archive_name => archive}) ==
               {:ok,
                [
                  %{
                    "path" => "native/libfx.so",
                    "checksum_file" => "checksum-Elixir.Fx.Native.exs",
                    "archive" => @archive_name,
                    "archive_sha256" => sha(archive)
                  }
                ]}
    end

    test "an archive whose bytes differ from its listed sum verifies nothing",
         %{checksums: checksums} do
      forged = tar_gz(%{"libfx.so" => @so <> "x"})
      files = [%{"path" => "native/libfx.so", "sha256" => sha(@so <> "x")}]

      assert {:error, "native file not verified against the package's checksum file: " <> _} =
               NifOrigin.verify(files, checksums, %{@archive_name => forged})
    end

    test "a native file no listed archive holds is refused",
         %{archive: archive, checksums: checksums} do
      files = [%{"path" => "native/other.so", "sha256" => sha("other")}]

      assert NifOrigin.verify(files, checksums, %{@archive_name => archive}) ==
               {:error,
                "native file not verified against the package's checksum file: native/other.so"}
    end

    test "an archive the checksum files do not name is ignored", %{archive: archive} do
      files = [%{"path" => "native/libfx.so", "sha256" => sha(@so)}]
      checksums = %{"checksum.exs" => %{"other.tar.gz" => sha(archive)}}

      assert {:error, _} = NifOrigin.verify(files, checksums, %{@archive_name => archive})
    end

    test "no native files need no archive" do
      assert NifOrigin.verify([], %{"checksum.exs" => %{}}, %{}) == {:ok, []}
    end
  end

  describe "members/1" do
    test "regular members by path with their sums; a bad archive is an error" do
      archive = tar_gz(%{"a/libx.so" => "x", "b.txt" => "y"})
      assert NifOrigin.members(archive) == {:ok, %{"a/libx.so" => sha("x"), "b.txt" => sha("y")}}
      assert NifOrigin.members("nope") == :error
    end
  end
end
