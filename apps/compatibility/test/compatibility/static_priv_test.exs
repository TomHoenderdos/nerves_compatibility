defmodule Compatibility.StaticPrivTest do
  # The priv rules on their own, with the files and the tarball in memory.
  # The worker (`NccWorker.StaticPriv`) and the portal
  # (`Portal.Catalog.ToolchainPriv`) each read them their own way and hand
  # them here; these tests are about what the rules say, chiefly about the
  # files a package's own compile wrote into its own build priv (`built`),
  # which its Hex tarball never carries.
  use ExUnit.Case, async: true

  alias Compatibility.StaticPriv

  @moduletag :tmp_dir

  @mib 1024 * 1024

  # A Hex tarball's bytes as `mix hex.build` writes it: an outer tar of
  # VERSION, CHECKSUM, metadata.config and contents.tar.gz, the last holding
  # the package's files at their paths. `files` are `path => content` or
  # `path => {content, mode}`.
  defp hex_tarball(root, files) do
    staging = Path.join(root, "staging-#{System.unique_integer([:positive])}")

    entries =
      for {path, spec} <- Map.put_new(files, "lib/sample.ex", "defmodule Sample do end") do
        {content, mode} = content_and_mode(spec)
        full = Path.join(staging, path)
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, content)
        File.chmod!(full, mode)
        {String.to_charlist(path), String.to_charlist(full)}
      end

    contents = Path.join(root, "contents-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(contents), entries, [:compressed])
    outer = Path.join(root, "sample-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", ~s({<<"name">>,<<"sample">>}.\n)},
        {~c"contents.tar.gz", File.read!(contents)}
      ])

    File.read!(outer)
  end

  defp content_and_mode({content, mode}), do: {content, mode}
  defp content_and_mode(content), do: {content, 0o644}

  defp file(path, bytes, mode \\ 0o100644), do: %{path: path, mode: mode, bytes: bytes}

  @archive "assets/Kino_Tree/abc.tar.gz"
  @gz <<0x1F, 0x8B, 8, 0, 0, 0, 0, 0, 0, 3, "kino assets">>

  describe "files from the package's own tarball, as before" do
    test "byte for byte the tarball's is static", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})
      assert StaticPriv.check([file("data.json", "{}")], tarball) == :ok
      assert StaticPriv.check([file("data.json", "{}")], tarball, []) == :ok
    end

    test "a file the tarball does not carry is not", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})

      assert {:error, "ships a priv file its Hex tarball does not carry (priv/#{@archive})",
              path: @archive} == StaticPriv.check([file(@archive, @gz)], tarball)
    end

    # Being on the list says nothing about a file that is not on it.
    test "a file not on the compile-written list is judged against the tarball",
         %{tmp_dir: root} do
      tarball = hex_tarball(root, %{"priv/data.json" => ~s({"v": 1})})
      files = [file(@archive, @gz), file("data.json", ~s({"v": 2}))]

      assert {:error, "ships a priv file that differs from its Hex tarball's (priv/data.json)",
              _details} = StaticPriv.check(files, tarball, [@archive])
    end
  end

  describe "files the package's own compile wrote" do
    test "one the tarball does not carry is static", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})
      files = [file(@archive, @gz), file("data.json", "{}")]

      assert StaticPriv.check(files, tarball, [@archive]) == :ok
    end

    test "a package whose priv is only what its compile wrote", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{})
      assert StaticPriv.check([file(@archive, @gz)], tarball, [@archive]) == :ok
    end

    # The compile wrote over a file the release itself ships: what the
    # tarball says it is and what the build publishes are no longer the
    # same thing, whatever the bytes.
    test "one at a path the tarball carries is not, even with the same bytes",
         %{tmp_dir: root} do
      for {bytes, i} <- Enum.with_index([@gz, "another"]) do
        tarball = hex_tarball(Path.join(root, "#{i}"), %{("priv/" <> @archive) => @gz})

        assert {:error,
                "ships a priv file its compile wrote over one its Hex tarball carries " <>
                  "(priv/#{@archive})", path: @archive} ==
                 StaticPriv.check([file(@archive, bytes)], tarball, [@archive])
      end
    end

    test "native code by its magic is not", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{})

      for magic <- [<<0x7F, "ELF">>, <<0xCF, 0xFA, 0xED, 0xFE>>, "MZ", "!<arch>\n"] do
        assert {:error, "ships native code in priv (priv/assets/x.bin)", path: "assets/x.bin"} ==
                 StaticPriv.check([file("assets/x.bin", magic <> <<0::64>>)], tarball, [
                   "assets/x.bin"
                 ])
      end
    end

    test "native code by its name is not", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{})

      assert {:error, "ships native code in priv (priv/nif.so)", path: "nif.so"} ==
               StaticPriv.check([file("nif.so", "data")], tarball, ["nif.so"])
    end

    test "an executable one is not", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{})

      assert {:error, "ships an executable priv file (priv/run.sh)", path: "run.sh"} ==
               StaticPriv.check([file("run.sh", "echo hi", 0o100755)], tarball, ["run.sh"])
    end

    test "the caps count them like any other file", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{})
      many = for i <- 1..501, do: file("assets/#{i}.txt", "row #{i}")

      assert StaticPriv.check(many, tarball, Enum.map(many, & &1.path)) ==
               StaticPriv.too_many()

      large = [file("assets/a.bin", :binary.copy("a", 10 * @mib)), file("assets/b.bin", "b")]

      assert StaticPriv.check(large, tarball, ["assets/a.bin", "assets/b.bin"]) ==
               StaticPriv.too_large()
    end

    # Not being in the tarball is only known from the tarball.
    test "without the tarball none is", %{tmp_dir: _root} do
      assert {:error, "ships priv files that could not be checked against its Hex tarball", []} ==
               StaticPriv.check([file(@archive, @gz)], nil, [@archive])
    end

    test "a list that is not one of paths refuses every file", %{tmp_dir: root} do
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})
      files = [file("data.json", "{}")]

      for built <- [nil, "assets", %{@archive => true}, [@archive, :other], [~c"assets"]] do
        assert {:error, "ships priv files whose compile-written list is malformed", []} ==
                 StaticPriv.check(files, tarball, built),
               inspect(built)
      end
    end
  end
end
