defmodule Compatibility.RelocationTest do
  # Compiles the same source at two builder roots and at a user's root, then
  # relocates the first build to the user's paths: the result must be the
  # user's own compile, chunk for chunk after `beam_lib:strip/1`, and in
  # `Attr`.
  use ExUnit.Case, async: false

  alias Compatibility.Relocation

  @moduletag :tmp_dir

  defp slots(root),
    do: %{"deps" => Path.join(root, "deps"), "build" => Path.join(root, "_build/dev")}

  # The module `name` from `body`, compiled as `<root>/deps/fx/lib/fx.ex`
  # (so `__DIR__` is `<root>/deps/fx/lib`), with `@build` the root's build
  # path, as a compile-time `Mix.Project.build_path/0` gives it.
  defp compile_ex(root, name, body) do
    module = Module.concat([RelocationTest, name])
    file = Path.join(root, "deps/fx/lib/fx.ex")
    build = slots(root)["build"]
    source = "defmodule #{inspect(module)} do\n@build #{inspect(build)}\n#{body}\nend\n"
    [{^module, beam}] = in_dep(root, fn -> Code.compile_string(source, file) end)
    :code.delete(module)
    :code.purge(module)
    beam
  end

  # Mix compiles a dependency from its own dir, so the line table names
  # `lib/fx.ex` while `__DIR__` is absolute.
  defp in_dep(root, fun) do
    dir = Path.join(root, "deps/fx")
    File.mkdir_p!(dir)
    File.cd!(dir, fun)
  end

  # An Erlang module compiled from `<root>/deps/fx/src/<name>.erl`, so
  # `?FILE` is that path as a charlist.
  defp compile_erl(root, name, body) do
    file = Path.join(root, "deps/fx/src/#{name}.erl")
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, "-module(#{name}).\n-export([f/0]).\n" <> body)
    {:ok, _module, beam} = :compile.file(String.to_charlist(file), [:binary, :report_errors])
    beam
  end

  defp three(ctx, fun) do
    roots =
      for r <- ["a/proj", "bbbbbbbbb/project_b", "home/user/my app"],
          do: Path.join(ctx.tmp_dir, r)

    Enum.map(roots, &{&1, fun.(&1)})
  end

  defp stripped(beam) do
    {:ok, {_, plain}} = :beam_lib.strip(beam)
    {:ok, _, chunks} = :beam_lib.all_chunks(plain)
    {:ok, _, all} = :beam_lib.all_chunks(beam)
    attr = List.keyfind(all, ~c"Attr", 0)
    chunks ++ [attr]
  end

  # Proves the first build against the second, relocates it to the user's
  # root, and returns `{occurrences, relocated, user's own beam}`.
  defp relocated(ctx, fun) do
    [{ra, a}, {rb, b}, {ru, u}] = three(ctx, fun)
    assert {:ok, occs} = Relocation.prove(a, slots(ra), b, slots(rb))
    assert {:ok, moved} = Relocation.relocate(a, occs, slots(ra), slots(ru))
    {occs, moved, u}
  end

  test "a __DIR__ literal is rewritten to the user's deps path, md5 and vsn with it", ctx do
    {occs, moved, user} =
      relocated(
        ctx,
        &compile_ex(&1, Dir, "@dir Path.expand(\"../c_include\", __DIR__)\ndef dir, do: @dir")
      )

    assert [
             %{
               "chunk" => "LitT",
               "kind" => "binary",
               "term" => [],
               "parts" => ["", "deps", "/fx/c_include"]
             }
           ] =
             occs

    assert stripped(moved) == stripped(user)
    assert :beam_lib.md5(moved) == :beam_lib.md5(user)
    assert moved != user
  end

  test "paths deep in a literal: a map value, a keyword list, a tuple and the build path", ctx do
    body = """
    @cfg %{a: 1, file: Path.join(__DIR__, "x.ex"), opts: [priv: Path.join(@build, "lib/fx/priv"), n: {1, __DIR__}]}
    def cfg, do: @cfg
    def fun, do: fn -> :ok end
    """

    {occs, moved, user} = relocated(ctx, &compile_ex(&1, Deep, body))
    assert length(occs) == 3
    assert Enum.any?(occs, &(&1["parts"] == ["", "build", "/lib/fx/priv"]))
    assert stripped(moved) == stripped(user)
  end

  test "an atom holding the path is rewritten in the atom table", ctx do
    {occs, moved, user} =
      relocated(ctx, &compile_ex(&1, Atom, "@a String.to_atom(__DIR__)\ndef a, do: @a"))

    assert Enum.any?(occs, &(&1["chunk"] == "AtU8" and &1["kind"] == "atom"))
    assert stripped(moved) == stripped(user)
  end

  test "an Erlang ?FILE is a charlist, and the line table's file is rewritten too", ctx do
    {occs, moved, user} = relocated(ctx, &compile_erl(&1, :fx_file, "f() -> ?FILE.\n"))
    assert Enum.any?(occs, &(&1["chunk"] == "LitT" and &1["kind"] == "charlist"))
    assert Enum.any?(occs, &(&1["chunk"] == "Line"))
    assert stripped(moved) == stripped(user)
  end

  test "a beam without the path is the same at both roots", ctx do
    [{ra, a}, {rb, b}, _] = three(ctx, &compile_ex(&1, Plain, "def x, do: 1"))
    assert Relocation.prove(a, slots(ra), b, slots(rb)) == :same
  end

  test "a hashed path, its length, or a path in a built binary is not provable", ctx do
    for {name, body} <- [
          {Hashed, "@h :erlang.md5(__DIR__)\ndef h, do: @h"},
          {Length, "@n byte_size(__DIR__)\ndef n, do: @n"},
          {Built, "def b(x), do: <<__DIR__::binary, x::binary>>"},
          {Sliced, "@s String.slice(__DIR__, -16, 16)\ndef s, do: @s"}
        ] do
      [{ra, a}, {rb, b}, _] = three(ctx, &compile_ex(&1, name, body))
      assert {:refuse, _why} = Relocation.prove(a, slots(ra), b, slots(rb)), inspect(name)
    end
  end

  test "the project root itself, outside deps and the build path, is not provable", ctx do
    [{ra, a}, {rb, b}, _] =
      three(ctx, &compile_ex(&1, Root, "@r Path.expand(\"../../..\", __DIR__)\ndef r, do: @r"))

    assert {:refuse, _} = Relocation.prove(a, slots(ra), b, slots(rb))
  end

  test "a protocol holding the path is not relocated: consolidation recompiles its debug info",
       ctx do
    body = "@dir __DIR__\nKernel.def(dir, do: @dir)\n"

    [{ra, a}, {rb, b}, _] =
      three(ctx, fn root ->
        module = RelocationTest.Proto
        file = Path.join(root, "deps/fx/lib/proto.ex")
        source = "defprotocol #{inspect(module)} do\n#{body}\ndef p(x)\nend\n"
        beams = in_dep(root, fn -> Code.compile_string(source, file) end)
        for {m, _} <- beams, do: :code.delete(m) && :code.purge(m)
        {^module, beam} = List.keyfind(beams, module, 0)
        beam
      end)

    assert {:refuse, "a protocol" <> _} = Relocation.prove(a, slots(ra), b, slots(rb))
  end

  test "relocation refuses where two literals would become one at the user's path", ctx do
    [{ra, a}, {rb, b}, {ru, _}] =
      three(ctx, fn root ->
        user = Path.join(Path.dirname(Path.dirname(root)), "home/user/my app/deps/fx/lib")
        compile_ex(root, Dedup, "def a, do: __DIR__\ndef b, do: #{inspect(user)}")
      end)

    assert {:ok, occs} = Relocation.prove(a, slots(ra), b, slots(rb))
    assert {:refuse, "two literals" <> _} = Relocation.relocate(a, occs, slots(ra), slots(ru))
  end

  test "relocation checks the served bytes hold the recorded path", ctx do
    [{ra, a}, {rb, b}, {ru, _}] = three(ctx, &compile_ex(&1, Check, "def d, do: __DIR__"))
    assert {:ok, occs} = Relocation.prove(a, slots(ra), b, slots(rb))
    assert {:refuse, _} = Relocation.relocate(b, occs, slots(ra), slots(ru))
  end

  test "slots must be absolute and distinct" do
    assert {:refuse, _} = Relocation.prove(<<>>, %{"deps" => "deps"}, <<>>, %{"deps" => "/x"})
    assert {:refuse, _} = Relocation.prove(<<>>, slots("/a"), <<>>, slots("/a"))
  end

  test "prove_ebin proves every beam and keeps the others byte for byte", ctx do
    [{ra, a}, {rb, b}, _] = three(ctx, &compile_ex(&1, Ebin, "def d, do: __DIR__"))
    [{_, pa}, {_, pb}, _] = three(ctx, &compile_ex(&1, EbinPlain, "def d, do: 1"))

    ebin_a = %{"Elixir.A.beam" => a, "Elixir.P.beam" => pa, "fx.app" => "{application,fx,[]}.\n"}
    ebin_b = %{"Elixir.A.beam" => b, "Elixir.P.beam" => pb, "fx.app" => "{application,fx,[]}.\n"}

    assert {:ok, %{"Elixir.A.beam" => [_]} = relocated} =
             Relocation.prove_ebin(ebin_a, slots(ra), ebin_b, slots(rb))

    assert map_size(relocated) == 1

    assert {:refuse, _} =
             Relocation.prove_ebin(ebin_a, slots(ra), Map.delete(ebin_b, "fx.app"), slots(rb))
  end

  describe "record_problem/2" do
    @occ %{
      "chunk" => "LitT",
      "index" => 0,
      "term" => [1],
      "kind" => "binary",
      "parts" => ["", "deps", "/x"]
    }
    @record Map.put(Relocation.pinned_record(1), "files", [
              %{"path" => "ebin/Elixir.A.beam", "occurrences" => [@occ]}
            ])

    test "a well-formed record of the build's own beams has none" do
      assert Relocation.record_problem(@record, ["ebin/Elixir.A.beam", "ebin/a.app"]) == nil
    end

    test "every malformed shape is named" do
      ebin = ["ebin/Elixir.A.beam"]
      file = fn occ -> %{"path" => "ebin/Elixir.A.beam", "occurrences" => [occ]} end

      for record <- [
            nil,
            %{@record | "deps" => "deps"},
            %{@record | "build" => @record["deps"]},
            %{@record | "files" => []},
            %{@record | "files" => [%{"path" => "ebin/Elixir.B.beam", "occurrences" => [@occ]}]},
            %{@record | "files" => [%{"path" => "priv/x.beam", "occurrences" => [@occ]}]},
            %{@record | "files" => [%{"path" => "ebin/Elixir.A.beam", "occurrences" => []}]},
            %{@record | "files" => List.duplicate(hd(@record["files"]), 2)},
            %{@record | "files" => [file.(%{@occ | "chunk" => "StrT"})]},
            %{@record | "files" => [file.(%{@occ | "index" => -1})]},
            %{@record | "files" => [file.(%{@occ | "term" => ["x"]})]},
            %{@record | "files" => [file.(%{@occ | "kind" => "float"})]},
            %{@record | "files" => [file.(%{@occ | "parts" => ["", "home", "/x"]})]},
            %{@record | "files" => [file.(%{@occ | "parts" => ["/x"]})]},
            %{@record | "files" => [file.(%{@occ | "parts" => ["", "deps"]})]},
            Map.put(@record, "extra", 1),
            Map.delete(@record, "second"),
            Map.delete(@record, "third"),
            %{@record | "second" => %{"deps" => "/x/deps"}},
            %{@record | "third" => %{@record["third"] | "build" => "/x/b\u00e9"}},
            %{@record | "second" => %{@record["second"] | "deps" => "/x/d\u00e9ps"}},
            %{@record | "deps" => "/work/proj/de\tps"},
            %{@record | "files" => [file.(%{@occ | "parts" => ["\xff", "deps", ""]})]}
          ] do
        assert is_binary(Relocation.record_problem(record, ebin)), inspect(record)
      end
    end
  end

  describe "the three roots and the record's limits" do
    # The umbrella re-review's R1: three roots, the first the worker's own
    # project, the second under /home, the third under /Users, unlike one
    # another in every property a user path the client accepts can have,
    # and holding between them the words user paths hold.
    test "the three roots differ in length, case, space, project dir name and order" do
      %{"deps" => _, "build" => _} = a = Relocation.first_root()
      b = Relocation.second_layout("/home/nerves", 123)
      c = Relocation.third_layout("/Users", 123)

      assert String.starts_with?(b["deps"], "/home/")
      assert String.starts_with?(c["deps"], "/Users/")

      for slot <- ["deps", "build"] do
        lengths = Enum.map([a, b, c], &byte_size(&1[slot]))
        assert length(Enum.uniq(lengths)) == 3, slot
        assert Enum.all?([b, c], &(&1[slot] =~ ~r/\A[\x20-\x7e]+\z/)), slot
        refute b[slot] =~ ~r/[A-Z ]/, slot
        assert c[slot] =~ ~r/[A-Z]/ and c[slot] =~ " ", slot
        refute a[slot] =~ ~r/[A-Z 0-9]/, slot
      end

      names = Enum.map([a, b, c], &Path.basename(Path.dirname(&1["deps"])))
      assert length(Enum.uniq(names)) == 3

      assert a["build"] < a["deps"]
      assert b["deps"] < b["build"]
      assert c["build"] < c["deps"]

      words =
        [".cache/mix/installs", "Library", "Projects", "projects", "src", "code", "/app/"] ++
          ["nix/store", "/.", "@", "~"]

      for word <- words do
        assert Enum.any?([b, c], &String.contains?(&1["deps"], word)), word
        refute String.contains?(a["deps"], word), word
      end

      # Every letter, digit and the space, dot, dash and underscore are
      # among the three roots' characters, for each slot.
      for slot <- ["deps", "build"] do
        chars = MapSet.new(String.to_charlist(a[slot] <> b[slot] <> c[slot]))
        all = ~c"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-/@~"
        assert MapSet.subset?(MapSet.new(all), chars), slot
      end
    end

    test "pinned_problem/1 holds a record to the worker's three roots" do
      record = Relocation.pinned_record(42)
      assert Relocation.pinned_problem(record) == nil

      for bad <- [
            %{record | "deps" => "/w/proj/deps"},
            %{record | "build" => "/work/proj/_build/dev"},
            %{
              record
              | "second" =>
                  Map.take(Relocation.second_layout("/home/other", 42), ["deps", "build"])
            },
            %{record | "second" => Relocation.pinned_record(43)["second"]},
            %{
              record
              | "third" => Map.take(Relocation.third_layout("/Users/x", 42), ["deps", "build"])
            },
            %{record | "third" => %{record["third"] | "build" => record["third"]["deps"] <> "x"}},
            Map.delete(record, "third")
          ] do
        assert is_binary(Relocation.pinned_problem(bad)), inspect(bad)
      end
    end

    # The client re-review's R1: client 0.9.0 holds every record to the
    # same roots, copied into its own source (`Precompiled.Relocate`); its
    # test pins this literal too, so a change here fails there until both
    # move together.
    test "pinned_record/1 is the literal client 0.9.0 ships" do
      first = "/home/nerves/.cache/mix/installs/elixir-1.20.5-erts-16.4.0.2/ncc-relocate-7"
      second = first <> "/nix/store/src/code/projects/x_y@z~0.d/app"

      third =
        "/Users/Ncc-Relocate 7/Library/Mobile Documents/ABCDEFGHIJKLMNOPQRSTUVWXYZ/" <>
          "0123456789/abcdefghijklmnopqrstuvwxyz/Long Relocation.Path-0123456789 " <>
          "ABCDEFGHIJKLMNOPQRSTUVWXYZ abcdefghijklmnopqrstuvwxyz/x/Y/z-0/Projects/" <>
          "The Relocated.Project-2"

      assert Relocation.pinned_record(7) == %{
               "deps" => "/work/proj/deps",
               "build" => "/work/proj/_build/host",
               "second" => %{"deps" => second <> "/deps", "build" => second <> "/out.d/host-1"},
               "third" => %{
                 "deps" => third <> "/Deps vendored_d",
                 "build" => third <> "/Build-3/Host 4"
               }
             }
    end

    test "a record over 256 KiB of JSON is refused" do
      occ = fn i ->
        %{
          "chunk" => "LitT",
          "index" => i,
          "term" => [],
          "kind" => "binary",
          "parts" => ["", "deps", String.duplicate("x", 3000)]
        }
      end

      record =
        Map.put(Relocation.pinned_record(1), "files", [
          %{"path" => "ebin/Elixir.A.beam", "occurrences" => Enum.map(0..99, occ)}
        ])

      assert Relocation.record_problem(record, ["ebin/Elixir.A.beam"]) =~ "over 256 KiB"
    end

    test "a leaf that is not UTF-8, or over 4 KiB, is not provable", ctx do
      [{ra, a}, {rb, b}, _] =
        three(ctx, &compile_ex(&1, BadLeaf, "@d <<255>> <> __DIR__\ndef d, do: @d"))

      assert {:refuse, "a path in text that is not UTF-8"} =
               Relocation.prove(a, slots(ra), b, slots(rb))

      [{ra, a}, {rb, b}, _] =
        three(
          ctx,
          &compile_ex(&1, BigLeaf, "@d String.duplicate(\"x\", 5000) <> __DIR__\ndef d, do: @d")
        )

      assert {:refuse, "a path in text over 4 KiB"} = Relocation.prove(a, slots(ra), b, slots(rb))
    end
  end

  # The umbrella reviews' B1 and R1: the builder's roots must differ in what
  # a compile can derive from a path, or the proof cannot see a derived
  # value that is equal at them but not at the user's path. Each probe
  # derives one such value; at the worker's three roots (under this test's
  # tmp dir) each must refuse at the second root or the third.
  describe "derived values at the worker's three roots" do
    defp at_worker_roots(ctx, name, body) do
      base = Path.join(ctx.tmp_dir, "r")
      first = Path.join(base, "work/proj")
      second = Relocation.second_layout(Path.join(base, "home/nerves"), 7)
      third = Relocation.third_layout(Path.join(base, "Users"), 7)

      compile_at = fn deps ->
        module = Module.concat([RelocationTest, name])
        dir = Path.join(deps, "fx")
        File.mkdir_p!(dir)
        source = "defmodule #{inspect(module)} do\n#{body}\nend\n"

        [{^module, beam}] =
          File.cd!(dir, fn -> Code.compile_string(source, Path.join(dir, "lib/fx.ex")) end)

        :code.delete(module)
        :code.purge(module)
        beam
      end

      a = compile_at.(Path.join(first, "deps"))
      b = compile_at.(second["deps"])
      c = compile_at.(third["deps"])
      at = &Map.take(&1, ["deps", "build"])

      {Relocation.prove(a, slots(first), b, at.(second)),
       Relocation.prove(a, slots(first), c, at.(third))}
    end

    defp refused?({{:refuse, _}, _}), do: true
    defp refused?({_, {:refuse, _}}), do: true
    defp refused?(_), do: false

    for {name, body} <- [
          quoted: """
          @dir __DIR__
          @quoted if String.contains?(@dir, " "), do: "'" <> @dir <> "'", else: @dir
          def dir, do: @dir
          def quoted, do: @quoted
          """,
          project: """
          @dir __DIR__
          @project @dir |> Path.split() |> Enum.reverse() |> Enum.at(3)
          def dir, do: @dir
          def project, do: @project
          """,
          users: """
          @dir __DIR__
          @show if String.contains?(@dir, "/Users/"),
                  do: String.replace(@dir, ~r{^.*/Users/[^/]+}, "~"), else: @dir
          def dir, do: @dir
          def show, do: @show
          """,
          home: """
          @dir __DIR__
          @home String.contains?(@dir, "/home/")
          def dir, do: @dir
          def home?, do: @home
          """,
          install: """
          @dir __DIR__
          @install String.contains?(@dir, ".cache/mix/installs")
          def dir, do: @dir
          def install?, do: @install
          """,
          nix: """
          @dir __DIR__
          @nix String.contains?(@dir, "/nix/store/")
          def dir, do: @dir
          def nix?, do: @nix
          """
        ] do
      test "a #{name} test of the path refuses", ctx do
        assert refused?(
                 at_worker_roots(
                   ctx,
                   unquote(Macro.camelize(Atom.to_string(name))),
                   unquote(body)
                 )
               )
      end
    end

    test "a length limit between the first root and the others refuses", ctx do
      limit = byte_size(Path.join(ctx.tmp_dir, "r/work/proj/deps/fx/lib")) + 5

      body = """
      @short byte_size(__DIR__) < #{limit}
      @dir __DIR__
      def dir, do: @dir
      def short?, do: @short
      """

      assert refused?(at_worker_roots(ctx, "Short", body))
    end

    test "a plain __DIR__ literal proves at all three roots", ctx do
      assert {{:ok, [_]}, {:ok, [_]}} =
               at_worker_roots(ctx, "Plain", "@dir __DIR__\ndef dir, do: @dir")
    end
  end
end
