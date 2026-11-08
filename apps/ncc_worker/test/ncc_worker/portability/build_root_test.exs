defmodule NccWorker.Portability.BuildRootTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias NccWorker.Portability.{BuildRoot, Context, Etf}

  @moduletag :tmp_dir

  # Compiles `source` as if from `<root>/deps/fx/lib/fx.ex` and writes its
  # beams into `<root>/ebin`; `closure_file?` accepts real files under deps/fx.
  defp compile(root, source) do
    file = Path.join(root, "deps/fx/lib/fx.ex")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, source)
    File.write!(Path.join(root, "deps/fx/README.md"), "fx")
    ebin = Path.join(root, "ebin")
    File.mkdir_p!(ebin)

    modules = Code.compile_string(source, file)

    for {module, binary} <- modules do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end

    {ebin, &(String.starts_with?(&1, Path.join(root, "deps/fx/")) and File.regular?(&1))}
  end

  defp write_beam(ebin, name, chunks) do
    File.mkdir_p!(ebin)
    File.write!(Path.join(ebin, name <> ".beam"), iff(chunks))
  end

  defp iff(chunks) do
    body =
      for {id, data} <- chunks, into: <<>> do
        pad = rem(4 - rem(byte_size(data), 4), 4)
        <<id::binary-size(4), byte_size(data)::32, data::binary, 0::size(pad)-unit(8)>>
      end

    <<"FOR1", byte_size(body) + 4::32, "BEAM", body::binary>>
  end

  defp lit_t(terms) do
    entries = for t <- terms, into: <<>>, do: <<byte_size(t)::32, t::binary>>
    <<0::32, length(terms)::32, entries::binary>>
  end

  defp chunk(binary, id) do
    {:ok, {_, [{_, data}]}} = :beam_lib.chunks(binary, [String.to_charlist(id)])
    data
  end

  describe "check/3" do
    test "quote location: :keep and Logger-style file metadata are allowed", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxKeep do
          defmacro m, do: quote(location: :keep, do: 1 + 1)
          def meta, do: %{file: __ENV__.file, line: __ENV__.line}
          def mfa, do: {__MODULE__, {:meta, 0}, __ENV__.file, 1}
          def kw, do: [file: __ENV__.file, line: 2]
          @erl_file String.to_charlist(__ENV__.file)
          def erl, do: %{file: @erl_file, mfa: {__MODULE__, :erl, 0}}
        end
        """)

      assert :ok = BuildRoot.check(ebin, [root], ok?)
    end

    test "an external resource that is a closure file is allowed", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxResource do
          @external_resource Path.expand("../README.md", __DIR__)
          def x, do: 1
        end
        """)

      assert :ok = BuildRoot.check(ebin, [root], ok?)
    end

    test "an external resource that is not a closure file refuses", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxResourceDir do
          @external_resource Path.expand("..", __DIR__)
          def x, do: 1
        end
        """)

      assert {:refuse, "bakes the build path: Elixir.FxResourceDir " <> _} =
               BuildRoot.check(ebin, [root], ok?)
    end

    test "a directory baked into a literal refuses", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxRoot do
          @root Path.expand("..", __DIR__)
          def root, do: @root
        end
        """)

      assert {:refuse, "bakes the build path: Elixir.FxRoot " <> snippet} =
               BuildRoot.check(ebin, [root], ok?)

      assert snippet =~ "<root>/deps/fx"
      refute snippet =~ root
    end

    test "a closure file in an allowed shape still refuses when it is not a closure file",
         %{tmp_dir: root} do
      {ebin, _ok?} =
        compile(root, """
        defmodule FxNotClosure do
          def meta, do: %{file: __ENV__.file}
        end
        """)

      assert {:refuse, _} = BuildRoot.check(ebin, [root], fn _ -> false end)
    end

    test "a source path outside the allowed shapes refuses", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxList do
          def files, do: [__ENV__.file]
        end
        """)

      assert {:refuse, _} = BuildRoot.check(ebin, [root], ok?)
    end

    test "a __mix_recompile__? file list refuses", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxRecompile do
          @paths [Path.expand("../README.md", __DIR__)]
          def __mix_recompile__?, do: Enum.any?(@paths, &File.exists?/1)
        end
        """)

      assert {:refuse, _} = BuildRoot.check(ebin, [root], ok?)
    end

    test "a root in a literal atom refuses, even inside an allowed shape", %{tmp_dir: root} do
      ok? = fn _ -> true end
      atom_lit = <<131, 119, byte_size(root), root::binary>>
      write_beam(Path.join(root, "hand"), "atom", [{"LitT", lit_t([atom_lit])}])
      assert {:refuse, _} = BuildRoot.check(Path.join(root, "hand"), [root], ok?)

      keep = :erlang.term_to_binary({:keep, {String.to_atom(root), 1}})
      write_beam(Path.join(root, "hand2"), "atom", [{"LitT", lit_t([keep])}])
      assert {:refuse, _} = BuildRoot.check(Path.join(root, "hand2"), [root], ok?)
    end

    test "a root in the string table, atom table or .app refuses", %{tmp_dir: root} do
      for {chunk_id, dir} <- [{"StrT", "s"}, {"AtU8", "a"}, {"Atom", "o"}] do
        ebin = Path.join(root, dir)
        write_beam(ebin, "m", [{chunk_id, "xx" <> root <> "/lib"}])

        assert {:refuse, "bakes the build path: m " <> reason} =
                 BuildRoot.check(ebin, [root], fn _ -> true end)

        assert reason =~ "<root>"
        refute reason =~ root
      end

      app = Path.join(root, "app")
      File.mkdir_p!(app)
      File.write!(Path.join(app, "fx.app"), ~s|{application,fx,[{env,[{p,"#{root}"}]}]}.|)

      assert {:refuse, "bakes the build path: fx.app " <> reason} =
               BuildRoot.check(app, [root], fn _ -> true end)

      refute reason =~ root
    end

    test "a root in a run of code points inside mixed or improper lists refuses",
         %{tmp_dir: root} do
      for {name, term} <- [
            {"iodata", String.to_charlist(root <> "/x") ++ ["y"]},
            {"improper", String.to_charlist(root <> "/x") ++ "tail"},
            {"between", ["a", :b] ++ String.to_charlist(root) ++ [:c]},
            {"bytes", [:a | :binary.bin_to_list(Path.join(root, "ü"))]},
            {"wide", [:a | String.to_charlist(Path.join(root, "ŵ"))]}
          ] do
        dir = Path.join(root, "mixed_" <> name)
        write_beam(dir, "m", [{"LitT", lit_t([:erlang.term_to_binary(term)])}])
        assert {:refuse, _} = BuildRoot.check(dir, [root], fn _ -> true end), name
      end

      dir = Path.join(root, "mixed_clean")

      write_beam(dir, "m", [
        {"LitT", lit_t([:erlang.term_to_binary([?a, "b", -1, 0x110000 | "c"])])}
      ])

      assert :ok = BuildRoot.check(dir, [root], fn _ -> true end)
    end

    test "a compressed literal or attribute chunk is an error", %{tmp_dir: root} do
      lit = :erlang.term_to_binary(String.duplicate("a", 100), compressed: 9)
      write_beam(Path.join(root, "zl"), "m", [{"LitT", lit_t([lit])}])

      assert {:error, "literal table: " <> _} =
               BuildRoot.check(Path.join(root, "zl"), [root], fn _ -> true end)

      write_beam(Path.join(root, "za"), "m", [{"Attr", lit}])

      assert {:error, "attributes of m: " <> _} =
               BuildRoot.check(Path.join(root, "za"), [root], fn _ -> true end)
    end

    test "a root inside a fun's free variables or an improper tail refuses", %{tmp_dir: root} do
      improper = :erlang.term_to_binary([1 | root])
      write_beam(Path.join(root, "i"), "i", [{"LitT", lit_t([improper])}])
      assert {:refuse, _} = BuildRoot.check(Path.join(root, "i"), [root], fn _ -> true end)
    end

    test "a bare closure source path (Ecto's runtime-built file: field) is an observation",
         %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxEctoLike do
          def expr(params), do: %{params: params, file: __ENV__.file, line: __ENV__.line}
          def rel, do: Path.relative_to_cwd(__ENV__.file)
        end
        """)

      assert {:observe, [{:observe, "build_root_source_path", "<root>/deps/fx/lib/fx.ex"}]} =
               BuildRoot.check(ebin, [root], ok?)
    end

    test "only a bare closure source file is an observation; other bare paths refuse",
         %{tmp_dir: root} do
      {_ebin, _ok?} = compile(root, "defmodule FxSrc do\n  def x, do: :ok\nend\n")
      # Like Context.closure_file?/2: the real path is a regular file under deps/fx.
      fx = Context.realpath(Path.join(root, "deps/fx"))

      ok? = fn p ->
        real = Context.realpath(p)
        is_binary(real) and String.starts_with?(real, fx <> "/") and File.regular?(real)
      end

      source = Path.join(root, "deps/fx/lib/fx.ex")
      readme = Path.join(root, "deps/fx/README.md")
      outside = Path.join(root, "other/lib/o.ex")
      File.mkdir_p!(Path.dirname(outside))
      File.write!(outside, "")

      linked = Path.join(root, "_build/host/lib/fx/lib")
      File.mkdir_p!(Path.dirname(linked))
      File.ln_s!(Path.join(root, "deps/fx/lib"), linked)

      for rel <- ["deps/fx/priv/gen.ex", "deps/fx/test/fx_test.exs", "deps/fx/test/support/s.ex"] do
        path = Path.join(root, rel)
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, "")
      end

      for {name, literal} <- [
            {"priv", Path.join(root, "deps/fx/priv/gen.ex")},
            {"test", Path.join(root, "deps/fx/test/fx_test.exs")},
            {"test_support", Path.join(root, "deps/fx/test/support/s.ex")},
            {"symlinked", Path.join(linked, "fx.ex")},
            {"build", Path.join(root, "_build/host/lib/fx/ebin")},
            {"embedded", "at " <> source <> ":3"},
            {"prefix", source <> ".bak"},
            {"dotted", Path.join(root, "deps/fx/lib/../lib/fx.ex")},
            {"not_source", readme},
            {"outside", outside},
            {"dir", Path.join(root, "deps/fx/lib")}
          ] do
        dir = Path.join(root, "bare_" <> name)
        write_beam(dir, "m", [{"LitT", lit_t([:erlang.term_to_binary(literal)])}])
        assert {:refuse, _} = BuildRoot.check(dir, [root], ok?), name
      end

      dir = Path.join(root, "bare_ok")
      bins = Enum.map([source, source], &:erlang.term_to_binary/1)
      # The same path in two beams is observed once.
      write_beam(dir, "n", [{"LitT", lit_t(bins)}])
      write_beam(dir, "m", [{"LitT", lit_t(bins)}])
      assert {:observe, [_]} = BuildRoot.check(dir, [root], ok?)
    end

    test "a _build priv spelling is allowed only as an external resource", %{tmp_dir: root} do
      {_ebin, _} = compile(root, "defmodule FxPriv do\n  def x, do: :ok\nend\n")
      asset = Path.join(root, "deps/fx/priv/static/app.js")
      File.mkdir_p!(Path.dirname(asset))
      File.write!(asset, "")
      lib = Path.join(root, "_build/host/lib/fx")
      File.mkdir_p!(lib)
      File.ln_s!(Path.join(root, "deps/fx/priv"), Path.join(lib, "priv"))
      built = Path.join(lib, "priv/static/app.js")
      source = Path.join(root, "deps/fx/lib/fx.ex")
      fx = Context.realpath(Path.join(root, "deps/fx"))

      ok? = fn p ->
        real = Context.realpath(p)
        is_binary(real) and String.starts_with?(real, fx <> "/") and File.regular?(real)
      end

      check = fn name, term ->
        dir = Path.join(root, "shape_" <> name)
        write_beam(dir, "m", [{"LitT", lit_t([:erlang.term_to_binary(term)])}])
        BuildRoot.check(dir, [root], ok?)
      end

      for {name, term} <- [
            {"map", %{file: built, line: 1}},
            {"pair", [file: built]},
            {"keep", {:keep, {built, 1}}},
            {"mfa", {M, {:f, 0}, built, 1}},
            {"priv_real", %{file: asset}},
            {"charlist", %{file: String.to_charlist(built)}}
          ] do
        assert {:refuse, _} = check.(name, term), name
      end

      assert :ok = check.("resource", {:external_resource, [built]})
      assert :ok = check.("lib_map", %{file: source, line: 1})
      assert :ok = check.("lib_mfa", {M, {:f, 0}, source, 1})
    end

    test "a gzip-compressed beam (-compile(compressed)) is read and judged", %{tmp_dir: root} do
      clean =
        compressed_beam(Path.join(root, "gz_clean"), "ncc_br_gz_clean", ~s|f() -> {ok, "plain"}.|)

      assert <<31, 139, _::binary>> = File.read!(Path.join(clean, "ncc_br_gz_clean.beam"))
      assert :ok = BuildRoot.check(clean, [root], fn _ -> true end)

      baked =
        compressed_beam(Path.join(root, "gz_baked"), "ncc_br_gz_baked", ~s|f() -> ["#{root}/x"].|)

      assert {:refuse, "bakes the build path: ncc_br_gz_baked " <> _} =
               BuildRoot.check(baked, [root], fn _ -> true end)

      strt = Path.join(root, "gz_strt")
      File.mkdir_p!(strt)
      File.write!(Path.join(strt, "m.beam"), :zlib.gzip(iff([{"StrT", root}])))
      assert {:refuse, _} = BuildRoot.check(strt, [root], fn _ -> true end)
    end

    test "a gzip bomb or a truncated gzip beam is an error", %{tmp_dir: root} do
      # A well-formed beam whose padding chunk inflates past 64 MiB.
      big = iff([{"Pad ", :binary.copy(<<0>>, 65 * 1024 * 1024)}])
      bomb = Path.join(root, "bomb")
      File.mkdir_p!(bomb)
      File.write!(Path.join(bomb, "m.beam"), :zlib.gzip(big))

      assert {:error, "unreadable beam m (gzip inflates past" <> _} =
               BuildRoot.check(bomb, [root], fn _ -> true end)

      gz = :zlib.gzip(iff([{"LitT", lit_t([])}, {"StrT", "abc"}]))
      cut = Path.join(root, "cut")
      File.mkdir_p!(cut)
      File.write!(Path.join(cut, "m.beam"), binary_part(gz, 0, byte_size(gz) - 9))
      assert {:error, "unreadable beam m" <> _} = BuildRoot.check(cut, [root], fn _ -> true end)

      corrupt = Path.join(root, "corrupt")
      File.mkdir_p!(corrupt)
      <<head::binary-size(12), _::binary-size(4), tail::binary>> = gz
      File.write!(Path.join(corrupt, "m.beam"), head <> "XXXX" <> tail)

      assert {:error, "unreadable beam m" <> _} =
               BuildRoot.check(corrupt, [root], fn _ -> true end)

      nested = Path.join(root, "nested")
      File.mkdir_p!(nested)
      File.write!(Path.join(nested, "m.beam"), :zlib.gzip(:zlib.gzip(iff([]))))

      assert {:error, "unreadable beam m" <> _} =
               BuildRoot.check(nested, [root], fn _ -> true end)
    end

    test "a beam without any root passes", %{tmp_dir: root} do
      {ebin, ok?} = compile(root, "defmodule FxPlain do\n  def x, do: :ok\nend\n")
      assert :ok = BuildRoot.check(ebin, ["/definitely/not/here"], ok?)
    end

    test "an unparsable beam is an error, not a pass", %{tmp_dir: root} do
      ebin = Path.join(root, "bad")
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "x.beam"), "not a beam")
      assert {:error, "unreadable beam x" <> _} = BuildRoot.check(ebin, [root], fn _ -> true end)

      gz = Path.join(root, "gz")
      File.mkdir_p!(gz)
      File.write!(Path.join(gz, "x.beam"), :zlib.gzip("not a beam"))
      assert {:error, "unreadable beam x" <> _} = BuildRoot.check(gz, [root], fn _ -> true end)

      bad_lit = Path.join(root, "badlit")
      write_beam(bad_lit, "x", [{"LitT", lit_t([<<131, 255>>])}])
      assert {:error, "literal table: " <> _} = BuildRoot.check(bad_lit, [root], fn _ -> true end)

      dup = Path.join(root, "dup")
      write_beam(dup, "x", [{"LitT", lit_t([])}, {"LitT", lit_t([])}])
      assert {:error, _} = BuildRoot.check(dup, [root], fn _ -> true end)
    end

    test "a missing ebin is an error, a root with non-ASCII bytes is still found in charlists",
         %{tmp_dir: root} do
      assert {:error, "no ebin " <> _} =
               BuildRoot.check(Path.join(root, "nope"), [root], fn _ -> true end)

      File.write!(Path.join(root, "file"), "")

      assert {:error, "no ebin " <> _} =
               BuildRoot.check(Path.join(root, "file"), [root], fn _ -> true end)

      assert {:error, "no ebin " <> _} = BuildRoot.check(nil, [root], fn _ -> true end)

      uroot = Path.join(root, "ü")
      # A charlist of the root's UTF-8 bytes (binary_to_list) encodes as STRING_EXT.
      lit = :erlang.term_to_binary([:binary.bin_to_list(uroot)])
      write_beam(Path.join(root, "u"), "u", [{"LitT", lit_t([lit])}])
      assert {:refuse, _} = BuildRoot.check(Path.join(root, "u"), [uroot], fn _ -> true end)

      lit = :erlang.term_to_binary([String.to_charlist(uroot)])
      write_beam(Path.join(root, "u2"), "u", [{"LitT", lit_t([lit])}])
      assert {:refuse, _} = BuildRoot.check(Path.join(root, "u2"), [uroot], fn _ -> true end)
    end
  end

  describe "source_path_modules/3 and program_source_paths/3" do
    # `defp file` is not inlined, so the path stays a whole literal of its
    # own (an observation) rather than part of a larger literal (a refusal).
    @refusal " (a source path in a package that runs programs)"

    test "names the modules holding a bare source path", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxSpmBare do
          def file, do: __ENV__.file
        end

        defmodule FxSpmClean do
          def x, do: :ok
        end
        """)

      assert BuildRoot.source_path_modules(ebin, [root], ok?) == {:ok, ["Elixir.FxSpmBare"]}
    end

    test "a bare source path in a module that runs programs refuses", %{tmp_dir: root} do
      for {name, call} <- [
            {"FxPspCmd", ~s|System.cmd("cat", [file()])|},
            {"FxPspPort", ~s|Port.open({:spawn_executable, "/bin/cat"}, args: [file()])|},
            {"FxPspShell", ~s|:os.cmd(String.to_charlist("cat " <> file()))|},
            {"FxPspLookup", ~s|{System.find_executable("cat"), file()}|}
          ] do
        dir = Path.join(root, name)

        {ebin, ok?} =
          compile(dir, """
          defmodule #{name} do
            def run, do: #{call}
            defp file, do: __ENV__.file
          end
          """)

        # Only an observation for the literal scan: this rule is what refuses.
        assert {:observe, [_]} = BuildRoot.check(ebin, [dir], ok?), name

        assert BuildRoot.program_source_paths(ebin, [dir], ok?) ==
                 {:refuse, "bakes the build path: Elixir.#{name}" <> @refusal},
               name
      end
    end

    test "a path held in one module and run from another refuses", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxPspHold do
          def file, do: __ENV__.file
        end

        defmodule FxPspRun do
          def run, do: System.cmd("cat", [FxPspHold.file()])
        end
        """)

      assert BuildRoot.program_source_paths(ebin, [root], ok?) ==
               {:refuse, "bakes the build path: Elixir.FxPspHold" <> @refusal}
    end

    test "the first module with the path (sorted) is named", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxPspZed do
          def file, do: __ENV__.file
        end

        defmodule FxPspAbe do
          def run, do: System.cmd("cat", [file()])
          defp file, do: __ENV__.file
        end
        """)

      assert BuildRoot.program_source_paths(ebin, [root], ok?) ==
               {:refuse, "bakes the build path: Elixir.FxPspAbe" <> @refusal}
    end

    test "the path or the program call alone passes", %{tmp_dir: root} do
      path_only = Path.join(root, "path")

      {ebin, ok?} =
        compile(path_only, """
        defmodule FxPspPathOnly do
          def file, do: __ENV__.file
        end
        """)

      assert {:observe, [_]} = BuildRoot.check(ebin, [path_only], ok?)
      assert BuildRoot.program_source_paths(ebin, [path_only], ok?) == :ok

      cmd_only = Path.join(root, "cmd")

      {ebin, ok?} =
        compile(cmd_only, """
        defmodule FxPspCmdOnly do
          def run, do: System.cmd("true", [])
          def look, do: System.find_executable("cat")
          def port, do: Port.open({:spawn_executable, "/bin/true"}, [])
          def shell, do: :os.cmd(~c"true")
        end
        """)

      assert BuildRoot.program_source_paths(ebin, [cmd_only], ok?) == :ok
    end

    test "a path inside a larger literal still refuses as a baked path", %{tmp_dir: root} do
      {ebin, ok?} =
        compile(root, """
        defmodule FxPspListLit do
          def run, do: System.cmd("cat", [__ENV__.file])
        end
        """)

      refusal =
        {:refuse, ~s|bakes the build path: Elixir.FxPspListLit "<root>/deps/fx/lib/fx.ex"|}

      assert BuildRoot.check(ebin, [root], ok?) == refusal
      assert BuildRoot.program_source_paths(ebin, [root], ok?) == refusal
    end

    test "an unreadable beam is an error, never a pass", %{tmp_dir: root} do
      ebin = Path.join(root, "ebin")
      File.mkdir_p!(ebin)
      File.write!(Path.join(ebin, "Elixir.Broken.beam"), "not a beam")
      assert {:error, _} = BuildRoot.source_path_modules(ebin, [root], fn _ -> true end)
      assert {:error, _} = BuildRoot.program_source_paths(ebin, [root], fn _ -> true end)
      assert {:error, _} = BuildRoot.program_source_paths(Path.join(root, "none"), [root], & &1)
    end

    test "a path in a beam the call scan cannot read is an error", %{tmp_dir: root} do
      {_ebin, ok?} = compile(root, "defmodule FxPspSrc do\n  def x, do: :ok\nend\n")
      source = Path.join(root, "deps/fx/lib/fx.ex")
      dir = Path.join(root, "lit_only/ebin")
      # Read by the literal scan, but no beam `:beam_lib` could load for calls.
      write_beam(dir, "m", [{"LitT", lit_t([:erlang.term_to_binary(source)])}])
      assert BuildRoot.source_path_modules(dir, [root], ok?) == {:ok, ["m"]}
      assert {:error, "beam scan: " <> _} = BuildRoot.program_source_paths(dir, [root], ok?)
    end
  end

  describe "literal_table/1" do
    test "an oversized literal-table header is an error, not a decode" do
      assert {:error, "literal table larger than 64 MiB"} =
               BuildRoot.literal_table(<<0x7FFFFFFF::32, 0>>)
    end

    test "a compressed table decodes like the uncompressed one, and a bomb does not" do
      {:ok, _, beam} = :compile.forms(forms(), [:binary])
      <<0::32, table::binary>> = chunk(beam, "LitT")
      compressed = <<byte_size(table)::32, :zlib.compress(table)::binary>>

      assert {:ok, trees} = BuildRoot.literal_table(<<0::32, table::binary>>)
      assert {:ok, ^trees} = BuildRoot.literal_table(compressed)
      assert trees != []

      # Inflates past what its header claims.
      bomb = :zlib.compress(:binary.copy(<<0>>, 10_000_000))
      assert {:error, _} = BuildRoot.literal_table(<<1_000::32, bomb::binary>>)
      # Inflates to less than its header claims.
      assert {:error, _} =
               BuildRoot.literal_table(
                 <<byte_size(table) + 1::32, :zlib.compress(table)::binary>>
               )

      assert {:error, _} = BuildRoot.literal_table(<<100::32, "garbage">>)
      # A zlib stream cut before its end, though every table byte is out.
      z = :zlib.compress(table)

      assert {:error, _} =
               BuildRoot.literal_table(
                 <<byte_size(table)::32, binary_part(z, 0, byte_size(z) - 4)::binary>>
               )

      assert {:error, _} = BuildRoot.literal_table(<<0::32, 5::32>>)
      assert {:error, _} = BuildRoot.literal_table(<<0::32, 1::32, 2::32, 131>>)
      assert {:error, _} = BuildRoot.literal_table(<<1, 2>>)
    end

    test "real literal tables and attribute chunks from compiled dependencies parse" do
      beams =
        Path.wildcard(
          Path.join(
            Mix.Project.build_path(),
            "lib/{jason,plug,phoenix,phoenix_live_view,ecto,decimal}/ebin/*.beam"
          )
        ) ++ Path.wildcard(Path.join(:code.lib_dir(:stdlib), "ebin/*.beam"))

      assert length(beams) > 100

      for beam <- beams do
        bin = File.read!(beam)
        {:ok, {_, chunks}} = :beam_lib.chunks(bin, [~c"LitT", ~c"Attr"], [:allow_missing_chunks])
        chunks = Map.new(chunks)

        case chunks[~c"LitT"] do
          data when is_binary(data) ->
            assert {:ok, _trees} = BuildRoot.literal_table(data), beam

          :missing_chunk ->
            :ok
        end

        assert {:ok, _} = Etf.decode(chunks[~c"Attr"]), beam
      end

      for app <- ~w(jason plug phoenix decimal) do
        ebin = Path.join(Mix.Project.build_path(), "lib/#{app}/ebin")

        refute match?(
                 {:error, _},
                 BuildRoot.check(ebin, ["/definitely/not/here"], fn _ -> true end)
               )
      end
    end
  end

  # Compiles a one-function Erlang module with -compile(compressed) into dir.
  defp compressed_beam(dir, name, body) do
    File.mkdir_p!(dir)
    src = Path.join(dir, name <> ".erl")
    File.write!(src, "-module(#{name}).\n-compile(compressed).\n-export([f/0]).\n#{body}\n")

    {:ok, _} =
      :compile.file(String.to_charlist(src), [{:outdir, String.to_charlist(dir)}, :report])

    File.rm!(src)
    dir
  end

  # An Erlang module with assorted literals.
  defp forms do
    {:ok, tokens, _} =
      :erl_scan.string(~C"""
      -module(ncc_build_root_fixture).
      -export([f/0]).
      f() -> [{a, 1.5, <<1:3>>, 123456789012345678901234567890, #{k => "str"}, fun lists:map/2,
               [1 | 2], {}, [], <<"bin">>, -5, 300, -(1 bsl 70)}].
      """)

    split(tokens, [], [])
    |> Enum.map(fn form ->
      {:ok, parsed} = :erl_parse.parse_form(form)
      parsed
    end)
  end

  defp split([], [], acc), do: Enum.reverse(acc)

  defp split([{:dot, _} = dot | rest], cur, acc),
    do: split(rest, [], [Enum.reverse([dot | cur]) | acc])

  defp split([tok | rest], cur, acc), do: split(rest, [tok | cur], acc)

  describe "Etf.decode/1" do
    test "refuses a tuple larger than its input and deep nesting" do
      assert {:error, _} = Etf.decode(<<131, 105, 0xFFFFFFFF::32, 97, 1>>)
      deep = :binary.copy(<<108, 1::32>>, 5_000) <> <<106>> <> :binary.copy(<<106>>, 5_000)
      assert {:error, "nested too deep"} = Etf.decode(<<131>> <> deep)
    end

    test "returns unknown atoms as names" do
      bin = :erlang.term_to_binary({:keep, {"/x/y.ex", 3}})

      assert {:ok, {:tuple, [{:atom, "keep"}, {:tuple, [{:string, "/x/y.ex"}, {:int, 3}]}]}} =
               Etf.decode(bin)

      unknown = <<131, 119, 12, "ncc_new_atom">>
      assert {:ok, {:atom, "ncc_new_atom"}} = Etf.decode(unknown)
      assert_raise ArgumentError, fn -> String.to_existing_atom("ncc_new_atom") end
      assert {:ok, {:atom, "nc_é"}} = Etf.decode(<<131, 100, 4::16, "nc_", 0xE9>>)
      assert {:ok, {:atom, "x"}} = Etf.decode(<<131, 115, 1, "x">>)
      assert {:ok, {:atom, "x"}} = Etf.decode(<<131, 118, 1::16, "x">>)
      assert {:error, _} = Etf.decode(<<131, 119, 2, 0xFF, 0xFE>>)
    end

    test "decodes every literal shape" do
      cases = [
        {1, {:int, 1}},
        {-1, {:int, -1}},
        {1_000_000, {:int, 1_000_000}},
        {1.5, :float},
        {Integer.pow(2, 80), :bignum},
        {-Integer.pow(2, 4000), :bignum},
        {"bin", {:string, "bin"}},
        {~c"abc", {:string, "abc"}},
        {[1000, 2000], {:list, [{:int, 1000}, {:int, 2000}], {:list, [], nil}}},
        {[], {:list, [], nil}},
        {[:a | :b], {:list, [{:atom, "a"}], {:atom, "b"}}},
        {{}, {:tuple, []}},
        {%{a: 1}, {:map, [{{:atom, "a"}, {:int, 1}}]}},
        {<<1::3>>, {:bits, <<32>>}},
        {&Enum.map/2, {:export, {:atom, "Elixir.Enum"}, {:atom, "map"}, 2}},
        {List.to_tuple(Enum.to_list(1..300)), {:tuple, Enum.map(1..300, &{:int, &1})}}
      ]

      for {term, tree} <- cases do
        assert {:ok, ^tree} = Etf.decode(:erlang.term_to_binary(term)), inspect(term)
      end

      assert {:ok, :float} = Etf.decode(:erlang.term_to_binary(1.5, minor_version: 0))
      assert {:ok, {:string, "é"}} = Etf.decode(:erlang.term_to_binary([0xE9]))

      for term <- [self(), make_ref(), hd(Port.list())] do
        assert {:ok, {kind, {:atom, _}}} = Etf.decode(:erlang.term_to_binary(term))
        assert kind in [:pid, :ref, :port]
      end

      x = String.duplicate("free", 1)
      fun = fn -> x end

      assert {:ok, {:fun, {:atom, _}, [{:string, "free"}]}} =
               Etf.decode(:erlang.term_to_binary(fun))

      big = :erlang.term_to_binary(String.duplicate("a", 1000), compressed: 9)
      assert {:ok, {:string, s}} = Etf.decode(big)
      assert s == String.duplicate("a", 1000)
    end

    test "fails closed on malformed and unknown input" do
      for bad <- [
            <<>>,
            <<131>>,
            <<130, 97, 1>>,
            <<131, 97>>,
            <<131, 97, 1, 0>>,
            <<131, 255>>,
            <<131, 121, 0, 0, 0, 0, 97, 1>>,
            <<131, 82, 0>>,
            <<131, 77, 1::32, 0, 255>>,
            <<131, 77, 1::32, 9, 255>>,
            <<131, 110, 1, 2, 5>>,
            <<131, 108, 2::32, 106>>,
            <<131, 116, 1::32, 97, 1>>,
            <<131, 80, 1_000_000::32, 1, 2, 3>>,
            <<131, 113, 97, 1, 97, 1, 97, 1>>,
            :binary.part(:erlang.term_to_binary({"abc", [1, 2], %{a: 1}}), 0, 10),
            42
          ] do
        assert {:error, why} = Etf.decode(bad), inspect(bad)
        assert is_binary(why)
      end
    end

    test "a zlib bomb in a compressed term is an error" do
      bomb = :zlib.compress(:binary.copy(<<0>>, 100_000_000))
      assert {:error, _} = Etf.decode(<<131, 80, 100_000_000::32, bomb::binary>>)
    end

    test "too many nodes is an error" do
      wide = <<131, 108, 5_000_000::32>> <> :binary.copy(<<97, 0>>, 5_000_000) <> <<106>>
      assert {:error, "too many terms"} = Etf.decode(wide)
    end

    test "random and mutated bytes never raise and never create atoms" do
      :rand.seed(:exsss, {1, 2, 3})
      fuzz_atoms = for n <- 1..40, into: <<>>, do: <<119, 9, "ncc_fz_", n + 64, n + 64>>

      seeds = [
        :erlang.term_to_binary({:keep, {"/x/y.ex", 3}}),
        :erlang.term_to_binary(%{file: ~c"/a/b", line: 1, mfa: {:m, :f, 1}}),
        :erlang.term_to_binary([1.5, -(1 <<< 70), <<1::3>>, &Enum.map/2, {}, [1 | 2], self()]),
        <<131, 104, 40, fuzz_atoms::binary>>
      ]

      names =
        for _ <- 1..20_000, reduce: [] do
          acc ->
            input = fuzz_input(seeds)
            result = Etf.decode(input)
            assert match?({:ok, _}, result) or match?({:error, why} when is_binary(why), result)

            table = <<0::32, 1::32, byte_size(input)::32, input::binary>>
            assert {tag, _} = BuildRoot.literal_table(table)
            assert tag in [:ok, :error]
            atom_names(result) ++ acc
        end

      assert names != []

      for name <- Enum.uniq(names), String.starts_with?(name, "ncc_fz_") do
        assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
      end
    end
  end

  defp fuzz_input(seeds) do
    seed = Enum.random(seeds)

    case :rand.uniform(3) do
      1 -> <<131>> <> :crypto.strong_rand_bytes(:rand.uniform(64))
      2 -> mutate(seed)
      3 -> :binary.part(seed, 0, :rand.uniform(byte_size(seed)))
    end
  end

  defp atom_names({:ok, {:tuple, items}}), do: for({:atom, n} <- items, do: n)
  defp atom_names(_), do: []

  defp mutate(bin) do
    pos = :rand.uniform(byte_size(bin)) - 1
    {pre, <<_, post::binary>>} = :erlang.split_binary(bin, pos)
    <<pre::binary, :rand.uniform(256) - 1, post::binary>>
  end
end
