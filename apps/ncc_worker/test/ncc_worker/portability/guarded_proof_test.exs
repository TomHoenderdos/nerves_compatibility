defmodule NccWorker.Portability.GuardedProofTest do
  # S9 fix round 1: the proof build's comparison and its `mix.exs` edits.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{GuardedProof, PrivRepro}

  @moduletag :tmp_dir

  defp beam(source) do
    source = String.replace(source, ~r/ do\n/, " do\n  @compile :debug_info\n", global: false)

    ExUnit.CaptureIO.capture_io(:stderr, fn ->
      send(self(), {:compiled, Code.compile_string(source)})
    end)

    receive do
      {:compiled, [{module, binary}]} ->
        :code.purge(module)
        :code.delete(module)
        binary
    end
  end

  # `binary` with chunk `id` set to `data`, added last when it has none.
  defp with_chunk(binary, id, data) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(binary)

    chunks =
      if List.keymember?(chunks, id, 0),
        do: List.keyreplace(chunks, id, 0, {id, data}),
        else: chunks ++ [{id, data}]

    {:ok, built} = :beam_lib.build_module(chunks)
    built
  end

  defp chunk(binary, id) do
    {:ok, _module, chunks} = :beam_lib.all_chunks(binary)
    {_, data} = List.keyfind(chunks, id, 0)
    data
  end

  # A two-pair map of atom keys, written in the order given (`MAP_EXT` of
  # `SMALL_ATOM_UTF8_EXT` keys and small integer values).
  defp map_etf(pairs) do
    body = for {k, v} <- pairs, into: <<>>, do: <<119, byte_size(k), k::binary, 97, v>>
    <<131, 116, length(pairs)::32, body::binary>>
  end

  test "a beam compared with itself, or rebuilt from the same chunks, is the same" do
    x = beam("defmodule GuardedProofSame do\n  def f, do: :ok\nend\n")
    assert GuardedProof.compare_beam(x, x) == :ok
    assert GuardedProof.compare_beam(x, with_chunk(x, ~c"ExCk", chunk(x, ~c"ExCk"))) == :ok
  end

  # `Dbgi`, `ExCk` and `Docs` hold maps whose encoded key order the
  # compiling VM decides: the same terms in another order are the same.
  test "ExCk, Dbgi and Docs compare as decoded terms, every other chunk as bytes" do
    x = beam("defmodule GuardedProofOrder do\n  def f, do: :ok\nend\n")
    a = map_etf([{"a", 1}, {"b", 2}])
    b = map_etf([{"b", 2}, {"a", 1}])
    c = map_etf([{"a", 1}, {"b", 3}])

    for id <- [~c"ExCk", ~c"Dbgi", ~c"Docs"] do
      assert GuardedProof.compare_beam(with_chunk(x, id, a), with_chunk(x, id, b)) == :ok

      assert GuardedProof.compare_beam(with_chunk(x, id, a), with_chunk(x, id, c)) ==
               {:differs, "#{id} differs"}
    end

    # Bytes for the rest: here the attributes chunk.
    assert {:differs, "Attr differs"} =
             GuardedProof.compare_beam(with_chunk(x, ~c"Attr", a), with_chunk(x, ~c"Attr", b))

    # An undecodable ExCk on one side cannot be compared.
    assert {:error, "ExCk cannot be decoded"} =
             GuardedProof.compare_beam(
               with_chunk(x, ~c"ExCk", a),
               with_chunk(x, ~c"ExCk", "junk")
             )
  end

  test "another body or another set of chunks differs" do
    x = beam("defmodule GuardedProofBody do\n  def f, do: :ok\nend\n")
    y = beam("defmodule GuardedProofBody do\n  def f, do: :other\nend\n")
    assert {:differs, _} = GuardedProof.compare_beam(x, y)

    {:ok, _module, chunks} = :beam_lib.all_chunks(x)
    {:ok, fewer} = chunks |> List.keydelete(~c"Dbgi", 0) |> :beam_lib.build_module()
    assert {:differs, "other chunks"} = GuardedProof.compare_beam(x, fewer)
    assert {:error, _} = GuardedProof.compare_beam(x, "not a beam")
  end

  test "two app dirs: ebin names and bytes, and the priv tree", %{tmp_dir: dir} do
    x = beam("defmodule GuardedProofApp do\n  def f, do: :ok\nend\n")

    make = fn name, files ->
      app = Path.join(dir, name)

      for {rel, data} <- files,
          do:
            File.mkdir_p!(Path.dirname(Path.join(app, rel))) &&
              File.write!(Path.join(app, rel), data)

      app
    end

    base = %{
      "ebin/x.app" => "{application,x,[]}.\n",
      "ebin/Elixir.X.beam" => x,
      "priv/a.txt" => "a"
    }

    first = make.("first", base)
    assert GuardedProof.compare_app(first, make.("same", base)) == :ok

    assert {:differs, "ebin/x.app: differs"} =
             GuardedProof.compare_app(
               first,
               make.("app", %{base | "ebin/x.app" => "{application,x,[{vsn,\"1\"}]}.\n"})
             )

    assert {:differs, "ebin holds other files"} =
             GuardedProof.compare_app(
               first,
               make.("more", Map.put(base, "ebin/Elixir.Y.beam", x))
             )

    assert {:differs, "priv differs"} =
             GuardedProof.compare_app(first, make.("priv", %{base | "priv/a.txt" => "b"}))

    linked = make.("linked", Map.delete(base, "priv/a.txt"))
    File.ln_s!(Path.join(first, "priv"), Path.join(linked, "priv"))
    assert GuardedProof.compare_app(first, linked) == :ok
  end

  test "the guarded packages go first in either deps list; a listed one is left alone" do
    plain = """
    defmodule P.MixProject do
      use Mix.Project

      def project do
        [
          app: :p,
          deps: deps()
        ]
      end

      defp deps do
        [
          {:pkg, "== 1.0.0"}
        ]
      end
    end
    """

    assert {:ok, added} = GuardedProof.inject(plain, [~s({:cowboy, ">= 0.0.0"})])

    assert added =~
             ~s(defp deps do\n    [\n      {:cowboy, ">= 0.0.0"},\n      {:pkg, "== 1.0.0"})

    assert GuardedProof.inject(added, [~s({:cowboy, "~> 2.0"})]) == {:ok, added}

    inline = ~s(def project, do: [app: :w, deps: [{:pkg, path: "deps/pkg"}]]\n)

    assert GuardedProof.inject(inline, [~s({:poison, ">= 0.0.0"})]) ==
             {:ok,
              ~s(def project, do: [app: :w, deps: [{:poison, ">= 0.0.0"}, {:pkg, path: "deps/pkg"}]]\n)}

    assert {:error, :no_deps_list} =
             GuardedProof.inject("defmodule X do\nend\n", [~s({:a, ">= 0.0.0"})])

    assert {:error, {:not_a_dep, _}} = GuardedProof.inject(inline, ["cowboy"])

    assert {:ok, unpruned} = GuardedProof.unpruned(plain)
    assert unpruned =~ "def project do\n    [prune_code_paths: false, \n      app: :p,"

    assert {:ok, ~s(def project, do: [prune_code_paths: false, app: :w) <> _} =
             GuardedProof.unpruned(inline)

    assert {:error, :no_project_list} = GuardedProof.unpruned("defmodule X do\nend\n")
  end

  # S9 re-review R1-1: one world per non-empty subset of the waived
  # entries, smallest first; more than three entries refuse.
  test "the proof worlds: every non-empty subset, at most three entries" do
    spec = fn n -> %{deps: [~s({:p#{n}, ">= 0.0.0"})], first: ["p#{n}"]} end
    entry = fn n -> {"e#{n}", spec.(n)} end

    assert {:ok, [[{"e1", _}]]} = GuardedProof.worlds([entry.(1)])

    assert {:ok, worlds} = GuardedProof.worlds([entry.(1), entry.(2)])

    assert Enum.map(worlds, fn w -> Enum.map(w, &elem(&1, 0)) end) == [
             ["e1"],
             ["e2"],
             ["e1", "e2"]
           ]

    assert {:ok, seven} = GuardedProof.worlds(Enum.map(1..3, entry))
    assert length(seven) == 7

    assert seven
           |> Enum.map(fn w -> w |> Enum.map(&elem(&1, 0)) |> Enum.sort() end)
           |> Enum.uniq()
           |> length() == 7

    assert Enum.map(seven, &length/1) == [1, 1, 1, 2, 2, 2, 3]

    assert GuardedProof.max_entries() == 3

    assert {:refuse, "more than 3 guarded entries are waived (4): not proved"} =
             GuardedProof.worlds(Enum.map(1..4, entry))

    assert {:refuse, _} = GuardedProof.worlds([])
  end

  test "hold: a waived pass waits; with PrivRepro's hold too it is could-not-judge for good" do
    waivers = %{
      "websock_adapter" => %{
        reasons: MapSet.new(["r"]),
        entries: ["websock_adapter:cowboy_adapter"]
      }
    }

    pass = %{
      status: :pass,
      reason: nil,
      compile_env: [],
      compile_inputs: [],
      observations: %{"problems" => []}
    }

    assert GuardedProof.hold(pass, %{}, %{}) == pass

    held = GuardedProof.hold(pass, waivers, %{build: "/b/lib/pkg", order: ["websock_adapter"]})
    assert %{status: :skip, reason: "portability could not be judged", compile_env: nil} = held
    assert held.guarded.refusal == "closure dependency observed the host: websock_adapter (r)"
    assert held.observations["problems"] == [GuardedProof.hold_problem()]

    repro =
      %{pass | status: :skip}
      |> Map.put(:priv_repro, %{})
      |> put_in([:observations, "problems"], [PrivRepro.hold_problem()])

    together = GuardedProof.hold(repro, waivers, %{build: nil, order: []})
    refute Map.has_key?(together, :priv_repro)
    refute Map.has_key?(together, :guarded)

    assert together.observations["problems"] == [
             "guarded modules and own priv writes are not settled together"
           ]
  end

  # S10: a waived probe the judge recorded as a `probe` compile input needs
  # no input while the proof holds. When the proof refuses and the first
  # build is untouched, the build is the all-absent world, so it passes with
  # the input put back (`fallback_inputs`): a user with the guarded package
  # misses. Without a fallback, or when the first build may have changed,
  # the proof's refusal stands.
  describe "a proof that refuses, with the waived probe inputs to fall back to" do
    @probe %{
      "kind" => "probe",
      "of" => "module",
      "name" => "Elixir.Poison",
      "answer" => "absent",
      "definers" => []
    }

    defp held_pass(fallback) do
      pass = %{
        status: :pass,
        reason: nil,
        compile_env: [],
        compile_inputs: [],
        observations: %{"problems" => [], "trace_stats" => %{}}
      }

      # No entry is waived: the proof refuses before it builds anything.
      waivers = %{"jose" => %{reasons: MapSet.new(["r"]), entries: ["no:such_entry"]}}

      GuardedProof.hold(pass, waivers, %{
        build: nil,
        order: ["jose"],
        fallback_inputs: fallback
      })
    end

    test "passes with the probe inputs put back", %{tmp_dir: dir} do
      held = held_pass([@probe])
      assert held.guarded.fallback_inputs == [@probe]

      v = GuardedProof.settle(held, dir, "pkg", [], fn _ -> {:ok, "d"} end)
      assert %{status: :pass, reason: nil, compile_inputs: [@probe], compile_env: []} = v
      refute Map.has_key?(v, :guarded)
      assert v.observations["problems"] == []
      assert v.observations["trace_stats"]["guarded_proof"]["result"] == "input"
      assert v.observations["trace_stats"]["guarded_proof"]["why"] =~ "no guarded entry is waived"
      assert v.observations["taint"] in [nil, %{}]
    end

    test "refuses as before without a fallback", %{tmp_dir: dir} do
      v = GuardedProof.settle(held_pass(nil), dir, "pkg", [], fn _ -> {:ok, "d"} end)
      assert %{status: :skip, reason: "closure dependency observed the host: jose (r)"} = v
      assert v.observations["trace_stats"]["guarded_proof"]["result"] == "refused"
    end
  end
end
