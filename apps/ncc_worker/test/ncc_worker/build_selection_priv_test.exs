defmodule NccWorker.BuildSelectionPrivTest do
  # A toolchain build publishes a package's priv files to every OS and
  # architecture. Static data is the same everywhere; native code is not, and
  # neither is anything the build itself produced. So a priv file is portable
  # only when it is a regular, non-executable, non-native file that the
  # package's own Hex tarball carries byte for byte. Anything else, or anything
  # that cannot be judged, keeps the package non-portable.
  use ExUnit.Case, async: true

  alias NccWorker.BuildSelection

  @moduletag :tmp_dir

  @mib 1024 * 1024

  # The built package: sources under `deps/sample`, beams and priv under
  # `_build/host/lib/sample`.
  defp project(root) do
    source = Path.join([root, "deps", "sample"])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Sample.MixProject do end")
    File.write!(Path.join(source, "lib/sample.ex"), "defmodule Sample do end")

    built = Path.join([root, "_build", "host", "lib", "sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", "circular_buffer-1.0.0"]), built)
    File.mkdir_p!(Path.join(built, "priv"))
    built
  end

  # Writes `files` (`relative path => content` or `{content, mode}`) into the
  # built priv dir.
  defp built_priv(built, files) do
    for {path, spec} <- files do
      {content, mode} = content_and_mode(spec)
      full = Path.join([built, "priv", path])
      File.mkdir_p!(Path.dirname(full))
      File.write!(full, content)
      File.chmod!(full, mode)
    end
  end

  defp content_and_mode({content, mode}), do: {content, mode}
  defp content_and_mode(content), do: {content, 0o644}

  # A Hex package tarball as `mix hex.build` writes it: an outer tar of
  # VERSION, CHECKSUM, metadata.config and contents.tar.gz, the last holding
  # the package's files at their paths (`priv/...`, `lib/...`).
  defp hex_tarball(root, files) do
    staging = Path.join(root, "tarball-staging-#{System.unique_integer([:positive])}")

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

    tarball = Path.join(root, "sample-1.0.0.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(tarball),
        [
          {~c"VERSION", "3"},
          {~c"CHECKSUM", String.duplicate("0", 64)},
          {~c"metadata.config", ~s({<<"name">>,<<"sample">>}.\n{<<"version">>,<<"1.0.0">>}.\n)},
          {~c"contents.tar.gz", File.read!(contents)}
        ]
      )

    tarball
  end

  defp scan(file_count) do
    %{
      beam_count: 2,
      languages: [:elixir],
      errors: [],
      nif_calls?: false,
      nif_evidence: [],
      shell_calls?: false,
      shell_evidence: [],
      os_exec_calls?: false,
      os_exec_evidence: [],
      executable_lookup_calls?: false,
      executable_lookup_evidence: [],
      footprint: %{priv: %{file_count: file_count, total_bytes: 0}}
    }
  end

  # The same files built and in the tarball, then judged.
  defp judge(root, files, opts \\ []) do
    built = project(root)
    built_priv(built, Keyword.get(opts, :built, files))
    tarball = hex_tarball(root, Map.new(Keyword.get(opts, :tarball, files), &prefix/1))
    count = map_size(Keyword.get(opts, :built, files))
    BuildSelection.portable?(root, "sample", scan(count), tarball: tarball)
  end

  defp prefix({path, spec}), do: {"priv/" <> path, spec}

  @png <<0x89, "PNG", 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, "IHDR", 0, 0, 0, 1>>

  describe "static priv data from the package's own tarball" do
    test "JSON and PNG files carried byte for byte are portable", %{tmp_dir: root} do
      files = %{"data/countries.json" => ~s({"nl": "Netherlands"}), "static/logo.png" => @png}
      assert judge(root, files) == :ok
    end

    test "up to the cap is portable: 500 files", %{tmp_dir: root} do
      files = Map.new(1..500, &{"data/#{&1}.txt", "row #{&1}"})
      assert judge(root, files) == :ok
    end

    test "up to the cap is portable: 10 MiB in total", %{tmp_dir: root} do
      files = %{"data/big.bin" => :binary.copy("a", 10 * @mib)}
      assert judge(root, files) == :ok
    end
  end

  describe "what keeps a package non-portable" do
    # Native code under any name: the magic is checked on every file.
    test "an ELF binary, whatever it is called", %{tmp_dir: root} do
      assert {:skip, _} = judge(root, %{"x.dat" => <<0x7F, "ELF", 2, 1, 1, 0, 0::64>>})
    end

    test "Mach-O, thin in both widths and byte orders, and fat", %{tmp_dir: root} do
      for {magic, i} <-
            Enum.with_index([
              <<0xFE, 0xED, 0xFA, 0xCE>>,
              <<0xCE, 0xFA, 0xED, 0xFE>>,
              <<0xFE, 0xED, 0xFA, 0xCF>>,
              <<0xCF, 0xFA, 0xED, 0xFE>>,
              <<0xCA, 0xFE, 0xBA, 0xBE>>,
              <<0xBE, 0xBA, 0xFE, 0xCA>>
            ]) do
        dir = Path.join(root, "macho-#{i}")
        File.mkdir_p!(dir)

        assert {:skip, _} = judge(dir, %{"blob.bin" => magic <> <<0::256>>}),
               "magic #{Base.encode16(magic)}"
      end
    end

    test "a PE executable", %{tmp_dir: root} do
      assert {:skip, _} = judge(root, %{"tool.bin" => "MZ" <> <<0x90, 0, 3, 0, 0::256>>})
    end

    test "a static archive", %{tmp_dir: root} do
      assert {:skip, _} = judge(root, %{"lib.bin" => "!<arch>\n" <> "member/ 0 0 0 644 4 `\n"})
    end

    test "a native library by its name, whatever is in it", %{tmp_dir: root} do
      for {name, i} <- Enum.with_index(~w(nif.so nif.dylib nif.dll nif.a nif.o addon.node)) do
        dir = Path.join(root, "name-#{i}")
        File.mkdir_p!(dir)
        assert {:skip, _} = judge(dir, %{name => "not really native"}), name
      end
    end

    test "an executable bit on the built file", %{tmp_dir: root} do
      assert {:skip, _} =
               judge(root, %{"run.sh" => "echo hi"},
                 built: %{"run.sh" => {"echo hi", 0o755}},
                 tarball: %{"run.sh" => "echo hi"}
               )
    end

    test "an executable bit on the tarball's entry", %{tmp_dir: root} do
      assert {:skip, _} =
               judge(root, %{"run.sh" => "echo hi"},
                 built: %{"run.sh" => "echo hi"},
                 tarball: %{"run.sh" => {"echo hi", 0o755}}
               )
    end

    test "a symlink", %{tmp_dir: root} do
      built = project(root)
      built_priv(built, %{"data.json" => "{}"})
      File.ln_s!("data.json", Path.join([built, "priv", "alias.json"]))
      tarball = hex_tarball(root, %{"priv/data.json" => "{}", "priv/alias.json" => "{}"})

      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(2), tarball: tarball)
    end

    test "a hard link", %{tmp_dir: root} do
      built = project(root)
      built_priv(built, %{"data.json" => "{}"})
      File.ln!(Path.join([built, "priv", "data.json"]), Path.join([built, "priv", "copy.json"]))
      tarball = hex_tarball(root, %{"priv/data.json" => "{}", "priv/copy.json" => "{}"})

      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(2), tarball: tarball)
    end

    # Generated at build time: the tarball never had it.
    test "a priv file the tarball does not carry", %{tmp_dir: root} do
      assert {:skip, _} =
               judge(root, %{},
                 built: %{"generated.json" => "{}"},
                 tarball: %{}
               )
    end

    test "a priv file that differs from the tarball's", %{tmp_dir: root} do
      assert {:skip, _} =
               judge(root, %{},
                 built: %{"data.json" => ~s({"v": 2})},
                 tarball: %{"data.json" => ~s({"v": 1})}
               )
    end

    # A dependency's compile hook can write into the package's source dir as
    # well as its build: the tarball, not `deps/<package>`, is the reference.
    test "a file planted in both the source dir and the build", %{tmp_dir: root} do
      built = project(root)
      built_priv(built, %{"data.json" => "{}", "planted.json" => "{}"})
      planted = Path.join([root, "deps", "sample", "priv"])
      File.mkdir_p!(planted)
      File.write!(Path.join(planted, "planted.json"), "{}")
      File.write!(Path.join(planted, "data.json"), "{}")
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})

      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(2), tarball: tarball)
    end

    test "more than 500 priv files", %{tmp_dir: root} do
      files = Map.new(1..501, &{"data/#{&1}.txt", "row #{&1}"})
      assert {:skip, _} = judge(root, files)
    end

    test "more than 10 MiB of priv files", %{tmp_dir: root} do
      files = %{"data/a.bin" => :binary.copy("a", 10 * @mib), "data/b.bin" => "b"}
      assert {:skip, _} = judge(root, files)
    end

    test "native sources in any of the native source dirs", %{tmp_dir: root} do
      for {dir_name, i} <- Enum.with_index(~w(c_src native zig_src go_src)) do
        case_root = Path.join(root, "native-#{i}")
        File.mkdir_p!(case_root)
        built = project(case_root)
        built_priv(built, %{"data.json" => "{}"})
        File.mkdir_p!(Path.join([case_root, "deps", "sample", dir_name]))
        tarball = hex_tarball(case_root, %{"priv/data.json" => "{}"})

        assert {:skip, _} =
                 BuildSelection.portable?(case_root, "sample", scan(1), tarball: tarball),
               dir_name
      end
    end

    # No reference to compare against is no evidence.
    test "priv files without the package's tarball", %{tmp_dir: root} do
      built = project(root)
      built_priv(built, %{"data.json" => "{}"})

      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(1))

      assert {:skip, _} =
               BuildSelection.portable?(root, "sample", scan(1),
                 tarball: Path.join(root, "missing.tar")
               )

      corrupt = Path.join(root, "corrupt.tar")
      File.write!(corrupt, "not a tarball")
      assert {:skip, _} = BuildSelection.portable?(root, "sample", scan(1), tarball: corrupt)
    end

    # The beam rules still come first: priv data does not excuse a NIF.
    test "every beam rule still applies to a package with priv data", %{tmp_dir: root} do
      built = project(root)
      built_priv(built, %{"data.json" => "{}"})
      tarball = hex_tarball(root, %{"priv/data.json" => "{}"})

      nif = Map.merge(scan(1), %{nif_calls?: true, nif_evidence: []})
      assert {:skip, _} = BuildSelection.portable?(root, "sample", nif, tarball: tarball)
    end
  end
end
