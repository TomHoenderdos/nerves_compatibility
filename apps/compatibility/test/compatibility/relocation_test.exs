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

  # The pilot's refusal: Elixir writes `ExCk` (and the compiler `Attr`)
  # with plain term_to_binary/1, and OTP orders a small map's atom keys by
  # atom index, so two compiles of the same source can write the same term
  # in other bytes (bamboo's Bamboo.Formatter.Map: `fun` and `tuple`
  # swapped). Both are compared as terms, in one normal form
  # (`term_to_binary(term, [:deterministic])`), as Elixir and beam_lib read
  # them; any other difference still refuses.
  describe "ExCk and Attr compared as terms" do
    @exck_term {:elixir_checker_v3, %{exports: [], mode: :elixir}}

    # `term` encoded as term_to_binary/1 would, every map's keys in reverse
    # term order: the bytes another VM's atom table order gives the same
    # term.
    defp reversed(term), do: <<131>> <> enc(term)

    defp enc(atom) when is_atom(atom) do
      name = Atom.to_string(atom)
      <<119, byte_size(name), name::binary>>
    end

    defp enc(n) when is_integer(n) and n in 0..255, do: <<97, n>>
    defp enc([]), do: <<106>>

    defp enc(list) when is_list(list),
      do: <<108, length(list)::32>> <> Enum.map_join(list, &enc/1) <> <<106>>

    defp enc(tuple) when is_tuple(tuple),
      do: <<104, tuple_size(tuple)>> <> Enum.map_join(Tuple.to_list(tuple), &enc/1)

    defp enc(map) when is_map(map) do
      pairs = map |> Enum.sort() |> Enum.reverse()
      <<116, length(pairs)::32>> <> Enum.map_join(pairs, fn {k, v} -> enc(k) <> enc(v) end)
    end

    # Anything else (a big integer, a binary) as term_to_binary/1 writes it.
    defp enc(other) do
      <<131, rest::binary>> = :erlang.term_to_binary(other)
      rest
    end

    defp with_chunk(beam, id, data) do
      {:ok, _, chunks} = :beam_lib.all_chunks(beam)
      {:ok, bytes} = :beam_lib.build_module(List.keystore(chunks, id, 0, {id, data}))
      bytes
    end

    test "the reversed bytes are the same term" do
      assert reversed(@exck_term) != :erlang.term_to_binary(@exck_term, [:deterministic])
      assert :erlang.binary_to_term(reversed(@exck_term)) == @exck_term
    end

    test "an ExCk in other bytes but the same term proves; another term refuses", ctx do
      [{ra, a}, {rb, b}, {ru, u}] = three(ctx, &compile_ex(&1, "Exck", "def d, do: __DIR__"))
      a = with_chunk(a, ~c"ExCk", :erlang.term_to_binary(@exck_term, [:deterministic]))
      b = with_chunk(b, ~c"ExCk", reversed(@exck_term))
      assert {:ok, occs} = Relocation.prove(a, slots(ra), b, slots(rb))

      other =
        with_chunk(b, ~c"ExCk", reversed({:elixir_checker_v3, %{exports: [], mode: :erlang}}))

      assert {:refuse, "ExCk differs at another root"} =
               Relocation.prove(a, slots(ra), other, slots(rb))

      # The relocated beam's ExCk is the user's own compile's, as Elixir
      # reads it: the same normal form.
      u = with_chunk(u, ~c"ExCk", reversed(@exck_term))
      {:ok, moved} = Relocation.relocate(a, occs, slots(ra), slots(ru))
      assert Relocation.normal_chunk(moved, "ExCk") == Relocation.normal_chunk(u, "ExCk")
      refute :beam_lib.chunks(moved, [~c"ExCk"]) == :beam_lib.chunks(u, [~c"ExCk"])
    end

    test "an Attr in other bytes but the same term proves; another term refuses", ctx do
      [{ra, a}, {rb, b}, _] = three(ctx, &compile_ex(&1, "Attr", "def d, do: __DIR__"))

      # Each beam's own attributes (its vsn is its md5) and a map in them.
      attrs = fn beam, map ->
        {:ok, {_, [{~c"Attr", attr}]}} = :beam_lib.chunks(beam, [~c"Attr"])
        :erlang.binary_to_term(attr) ++ [meta: [map]]
      end

      map = %{exports: [], mode: :elixir}
      a = with_chunk(a, ~c"Attr", :erlang.term_to_binary(attrs.(a, map), [:deterministic]))
      same = with_chunk(b, ~c"Attr", reversed(attrs.(b, map)))
      assert {:ok, _} = Relocation.prove(a, slots(ra), same, slots(rb))

      changed = with_chunk(b, ~c"Attr", reversed(attrs.(b, %{exports: [], mode: :erlang})))

      assert {:refuse, "Attr differs at another root"} =
               Relocation.prove(a, slots(ra), changed, slots(rb))
    end
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

    # The umbrella re-review's Q1: a dependent that passed because a
    # dependency was held is stored as a relocated build with nothing to
    # rewrite, so the same gates and the client's envelope hold it.
    test "a record with no files to rewrite is well formed" do
      assert Relocation.record_problem(%{@record | "files" => []}, ["ebin/Elixir.A.beam"]) == nil
    end

    # The client re-review's R5: Mix's layout under a build path is `lib/`
    # and `consolidated/`; a build slot followed by anything else is not a
    # path Mix gave the compile.
    test "a build slot is followed by nothing, /lib/ or /consolidated/" do
      ebin = ["ebin/Elixir.A.beam"]

      file = fn parts ->
        [%{"path" => hd(ebin), "occurrences" => [%{@occ | "parts" => parts}]}]
      end

      for tail <- [
            "",
            "/lib/fx/priv",
            "/lib/fx/ebin",
            "/lib/fx/include/a.hrl",
            "/lib/fx/.mix/compile.lock",
            "/consolidated/Elixir.P.beam"
          ] do
        assert Relocation.record_problem(%{@record | "files" => file.(["", "build", tail])}, ebin) ==
                 nil,
               tail
      end

      # The client re-review's R9: under `lib`, only an app's own dir and
      # Mix's layout in it; `/lib/x/lib/fx/priv` is a build root moved
      # down one app.
      for tail <- [
            "_x/lib/fx/priv",
            "/x/lib/fx/priv",
            "/lib",
            "/libx/a",
            "/consolidated",
            "/lib/x/lib/fx/priv",
            "/lib/fx",
            "/lib/fx/src/a.ex",
            "/lib/../priv",
            "/lib//priv"
          ] do
        assert Relocation.record_problem(%{@record | "files" => file.(["", "build", tail])}, ebin) =~
                 "a build path followed by",
               tail
      end

      assert Relocation.record_problem(
               %{@record | "files" => file.(["", "build", "", "deps", "/x"])},
               ebin
             ) == nil

      # With the build's closure apps named, the app must be one of them.
      priv = %{@record | "files" => file.(["", "build", "/lib/fx/priv"])}
      assert Relocation.record_problem(priv, ebin, ["fx", "decimal"]) == nil
      assert Relocation.record_problem(priv, ebin, ["decimal"]) =~ "a build path followed by"
    end

    test "every malformed shape is named" do
      ebin = ["ebin/Elixir.A.beam"]
      file = fn occ -> %{"path" => "ebin/Elixir.A.beam", "occurrences" => [occ]} end

      for record <- [
            nil,
            %{@record | "deps" => "deps"},
            %{@record | "build" => @record["deps"]},
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

  # The client re-review's R7: every beam of a relocated build was compiled
  # from its package's own dir under the record's deps path (its `CInf`
  # source), read without making an atom (the portal checks it at ingest).
  describe "compiled_in_problem/3" do
    test "a beam compiled in the package's dir has none; elsewhere, or no source, refuses",
         ctx do
      root = Path.join(ctx.tmp_dir, "w")
      deps = slots(root)["deps"]
      beam = compile_ex(root, "Where", "def a, do: 1")
      erl = compile_erl(root, :reloc_where, "f() -> ok.\n")

      ebin = %{
        "Elixir.RelocationTest.Where.beam" => beam,
        "reloc_where.beam" => erl,
        "fx.app" => "x"
      }

      assert Relocation.compiled_in_problem(ebin, deps, "fx") == nil
      assert Relocation.compiled_in_problem(ebin, deps, "fy") =~ "not compiled from"
      assert Relocation.compiled_in_problem(ebin, deps <> "2", "fx") =~ "not compiled from"

      assert Relocation.compiled_in_problem(ebin, Path.join(root, "dep"), "s/fx") =~
               "not compiled"

      {:ok, _, det} =
        :compile.file(String.to_charlist(Path.join(deps, "fx/src/reloc_where.erl")), [
          :binary,
          :deterministic
        ])

      assert Relocation.compiled_in_problem(%{"reloc_where.beam" => det}, deps, "fx") =~
               "not compiled from"

      assert Relocation.compiled_in_problem(%{"x.beam" => "junk"}, deps, "fx") =~ "unreadable"
    end

    test "a source with .. in it, or options with atoms no VM knows, are read safely", ctx do
      root = Path.join(ctx.tmp_dir, "w")
      deps = slots(root)["deps"]
      beam = compile_ex(root, "Odd", "def a, do: 1")
      {:ok, _, chunks} = :beam_lib.all_chunks(beam)

      with_cinf = fn info ->
        cinf = :erlang.term_to_binary(info)

        {:ok, bytes} =
          :beam_lib.build_module(List.keystore(chunks, ~c"CInf", 0, {~c"CInf", cinf}))

        %{"Elixir.RelocationTest.Odd.beam" => bytes}
      end

      escaped = String.to_charlist(Path.join(deps, "fx/../other/lib/x.ex"))

      assert Relocation.compiled_in_problem(with_cinf.(source: escaped), deps, "fx") =~
               "not compiled"

      # A compile option naming an atom this VM has never seen: read as a
      # name, never made.
      name = "ncc_never_seen_#{System.unique_integer([:positive])}"
      unseen = :erlang.term_to_binary([{:options, [{:parse_transform, :x}]}, {:source, ~c"/a"}])
      unseen = :binary.replace(unseen, <<119, 1, ?x>>, <<119, byte_size(name)>> <> name)
      ok = String.to_charlist(Path.join(deps, "fx/lib/fx.ex"))

      unseen =
        :binary.replace(
          unseen,
          <<107, 0, 2, ?/, ?a>>,
          <<107, length(ok)::16>> <> List.to_string(ok)
        )

      {:ok, bytes} =
        :beam_lib.build_module(List.keystore(chunks, ~c"CInf", 0, {~c"CInf", unseen}))

      assert Relocation.compiled_in_problem(%{"o.beam" => bytes}, deps, "fx") == nil
      assert_raise ArgumentError, fn -> String.to_existing_atom(name) end
    end
  end

  describe "the three roots and the record's limits" do
    # The umbrella re-review's R1: three roots, the first the worker's own
    # project, the second under /home, the third under /Users, unlike one
    # another in every property a user path the client accepts can have,
    # and holding between them the words user paths hold.
    test "the three roots differ in length, case, space, project dir name and order" do
      %{"deps" => _, "build" => _} = a = Relocation.first_root()
      %{second: home, third: users} = Relocation.bases()
      b = Relocation.second_layout(home, 123)
      c = Relocation.third_layout(users, 123)

      assert String.starts_with?(b["deps"], "/home/")
      assert String.starts_with?(c["deps"], "/Users/")

      # The umbrella re-review's Q2: the container's HOME is one of R2's
      # roots, and a root that holds it cannot be told from it.
      refute String.starts_with?(b["deps"], "/home/nerves/")
      refute String.starts_with?(b["deps"], "/home/nerves")

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
                  Map.take(Relocation.second_layout("/home/nerves", 42), ["deps", "build"])
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
      first = "/home/ncc-relocate/.cache/mix/installs/elixir-1.20.5-erts-16.4.0.2/ncc-relocate-7"
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
    # The probes below test the path for words such as "/home/" and
    # "/Users/", so the roots' common prefix must hold none of them. ExUnit's
    # tmp_dir lies under the checkout, which on a CI runner is under
    # /home/runner: every probe would then answer alike at all three roots.
    setup do
      base = Path.join("/tmp", "ncc-relocation-#{System.unique_integer([:positive])}")
      File.mkdir_p!(base)
      # The real path (macOS's /tmp is a link to /private/tmp), so a compile
      # that cds into a root sees the same prefix it was given.
      base = File.cd!(base, &File.cwd!/0)
      on_exit(fn -> File.rm_rf!(base) end)

      for word <- ["/home/", "/Users/", " ", ".cache/mix/installs", "/nix/store/"],
          do: refute(String.contains?(base, word))

      %{roots_base: base}
    end

    defp at_worker_roots(ctx, name, body) do
      base = Path.join(ctx.roots_base, "r")
      first = Path.join(base, "work/proj")
      second = Relocation.second_layout(Path.join(base, "home/ncc-relocate"), 7)
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
      limit = byte_size(Path.join(ctx.roots_base, "r/work/proj/deps/fx/lib")) + 5

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
