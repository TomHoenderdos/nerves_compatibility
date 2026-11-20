defmodule NccWorker.Portability.PrivReproTest do
  # `PrivRepro.settle/6` with the second build and the digest stubbed: what
  # each outcome of the second build makes of a held verdict. The real
  # compiles are `NccWorker.Tracer.FixturesOwnPrivTest`'s.
  use ExUnit.Case, async: true

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.PrivRepro

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    build = Path.join(dir, "proj/_build/host/lib/pkg")
    File.mkdir_p!(Path.join(build, "priv/assets"))
    File.write!(Path.join(build, "priv/assets/a.txt"), "a")

    pass = %{
      status: :pass,
      reason: nil,
      observations: %{"problems" => [], "trace_stats" => %{"judge_compile" => "finished"}},
      compile_env: [],
      compile_inputs: [%{"kind" => "os_type", "family" => "unix"}],
      manager: "mix"
    }

    own = %{
      observed?: true,
      dir: Path.join(build, "priv"),
      build: build,
      built: ["assets/a.txt"],
      roots: [Path.join(dir, "proj")],
      trees: %{"pkg" => {:ok, %{"lib/pkg.ex" => "sha"}}}
    }

    %{dir: dir, build: build, pass: pass, own: own, held: PrivRepro.hold(pass, own)}
  end

  # A second build that writes `files` (`rel => bytes`) into its own priv and
  # returns `verdict`.
  defp second(files, verdict \\ :held) do
    fn _project, "pkg", opts ->
      assert opts[:priv_repro] == false
      assert opts[:mode] == :judge
      # The tree snapshot the first build was judged on (`Trees`).
      assert opts[:trees] == %{"pkg" => {:ok, %{"lib/pkg.ex" => "sha"}}}
      {"MIX_BUILD_PATH", path} = List.keyfind(opts[:env], "MIX_BUILD_PATH", 0)
      send(self(), {:second_build, path})

      for {rel, bytes} <- files do
        file = Path.join([path, "lib/pkg/priv", rel])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, bytes)
      end

      case verdict do
        :held -> held_second()
        other -> other
      end
    end
  end

  defp held_second do
    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      priv_repro: %{},
      observations: %{
        "problems" => [PrivRepro.hold_problem()],
        "trace_stats" => %{"judge_compile" => "finished"}
      }
    }
  end

  # The second build under the system temp dir, which shares no directory
  # but `/` with the test's own tmp dir (under the checkout).
  defp settle(held, dir, run, digest \\ fn _ -> {:ok, "d"} end, extra \\ []) do
    opts = [env: [{"MIX_BUILD_PATH", "/first"}], repro_gap_ms: 0] ++ extra
    PrivRepro.settle(held, Path.join(dir, "proj"), "pkg", opts, run, digest)
  end

  test "the same priv passes with the held compile inputs and built_priv", ctx do
    v = settle(ctx.held, ctx.dir, second(%{"assets/a.txt" => "a"}))

    assert %{status: :pass, reason: nil, built_priv: ["assets/a.txt"], compile_env: []} = v
    assert v.compile_inputs == [%{"kind" => "os_type", "family" => "unix"}]
    assert v.observations["problems"] == []
    assert v.observations["trace_stats"]["priv_repro"] == "same"
    refute Map.has_key?(v, :priv_repro)
    assert_received {:second_build, path}
    refute File.exists?(Path.dirname(path))
  end

  # Then no directory above one build's priv is above the other's.
  test "a second build root that shares a directory with the first cannot be judged", ctx do
    run = fn _, _, _ -> flunk("no second build") end
    v = settle(ctx.held, ctx.dir, run, fn _ -> {:ok, "d"} end, repro_root: ctx.dir)
    assert v.reason == Reasons.could_not_judge()
    assert "second build path shares a directory with the first" in v.observations["problems"]
    assert v.observations["trace_stats"]["priv_repro"] == "not_judged"
  end

  test "different bytes, an extra file or a missing one refuse", ctx do
    for files <- [
          %{"assets/a.txt" => "b"},
          %{"assets/a.txt" => "a", "assets/b.txt" => "b"},
          %{}
        ] do
      v = settle(ctx.held, ctx.dir, second(files))
      assert v.status == :skip
      assert String.starts_with?(v.reason, Reasons.priv_not_reproduced() <> "priv/assets")
      assert v.reason =~ "differs between two builds"
      assert v.compile_inputs == nil
      assert v.observations["trace_stats"]["priv_repro"] == "differs"
      refute Map.has_key?(v, :built_priv)
    end
  end

  # The first build's archive is the one published; the second's may differ
  # in its members' times alone.
  test "a tar.gz whose times alone differ passes; any other difference refuses", ctx do
    archive = fn mtime, body ->
      path = Path.join(ctx.dir, "a-#{System.unique_integer([:positive])}.tar.gz")
      entries = [{~c"main.js", body}]
      :ok = :erl_tar.create(String.to_charlist(path), entries, [:compressed, mtime: mtime])
      File.read!(path)
    end

    first = archive.(5, "x")
    File.write!(Path.join(ctx.build, "priv/assets/m.tar.gz"), first)
    files = &%{"assets/a.txt" => "a", "assets/m.tar.gz" => &1}

    v = settle(ctx.held, ctx.dir, second(files.(archive.(6, "x"))))
    assert %{status: :pass} = v
    assert v.observations["priv_tar_times"] == ["assets/m.tar.gz"]
    assert v.observations["trace_stats"]["priv_repro"] == "same_but_tar_times"
    assert File.read!(Path.join(ctx.build, "priv/assets/m.tar.gz")) == first

    v = settle(ctx.held, ctx.dir, second(files.(archive.(6, "y"))))

    assert v.reason ==
             Reasons.priv_not_reproduced() <> "priv/assets/m.tar.gz differs between two builds"

    # Named otherwise, it is compared byte for byte.
    File.rename!(
      Path.join(ctx.build, "priv/assets/m.tar.gz"),
      Path.join(ctx.build, "priv/assets/m.bin")
    )

    second_files = %{"assets/a.txt" => "a", "assets/m.bin" => archive.(6, "x")}
    v = settle(ctx.held, ctx.dir, second(second_files))

    assert v.reason ==
             Reasons.priv_not_reproduced() <> "priv/assets/m.bin differs between two builds"
  end

  test "a link in priv cannot be compared", ctx do
    File.ln_s!("a.txt", Path.join(ctx.build, "priv/assets/l"))
    v = settle(ctx.held, ctx.dir, second(%{"assets/a.txt" => "a"}))
    assert v.reason == Reasons.could_not_judge()
    assert Enum.any?(v.observations["problems"], &(&1 =~ "is a symlink"))
  end

  test "a second build that refuses names its reason", ctx do
    refused = %{
      status: :skip,
      reason: "compile-time write outside ebin: file:open/2 /x",
      observations: %{"problems" => [], "trace_stats" => %{"judge_compile" => "finished"}}
    }

    v = settle(ctx.held, ctx.dir, second(%{}, refused))

    assert v.reason ==
             Reasons.priv_not_reproduced() <>
               "a second build refused (compile-time write outside ebin: file:open/2 /x)"
  end

  test "a second build that did not finish is transient could-not-judge", ctx do
    unfinished = %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      observations: %{
        "problems" => [],
        "trace_stats" => %{"judge_compile" => "not_finished", "tracer_error" => "timeout"}
      }
    }

    v = settle(ctx.held, ctx.dir, second(%{}, unfinished))
    assert v.reason == Reasons.could_not_judge()
    assert v.observations["trace_stats"]["priv_repro"] == "not_finished"
    assert "second build did not finish: timeout" in v.observations["problems"]
    refute PrivRepro.hold_problem() in v.observations["problems"]
  end

  test "a first build that changed while the second ran cannot be judged", ctx do
    counter = :counters.new(1, [])

    digest = fn _dir ->
      :counters.add(counter, 1, 1)
      {:ok, "d#{:counters.get(counter, 1)}"}
    end

    v = settle(ctx.held, ctx.dir, second(%{"assets/a.txt" => "a"}), digest)
    assert v.reason == Reasons.could_not_judge()
    assert "the first build changed while the second ran" in v.observations["problems"]
  end

  test "the second build itself, and any verdict not held, is left as it is", ctx do
    run = fn _, _, _ -> flunk("no second build") end
    opts = [env: [], priv_repro: false]
    assert PrivRepro.settle(ctx.held, ctx.dir, "pkg", opts, run, & &1) == ctx.held

    pass = %{status: :pass, built_priv: []}
    assert PrivRepro.settle(pass, ctx.dir, "pkg", [env: []], run, & &1) == pass
  end

  # R2 for priv (`NccWorker.Portability.PrivRoots`): a root both builds
  # share (the project dir, so every source path under it) refuses before
  # any second build, in a plain file and inside a gzip.
  test "a priv file that holds a root refuses before any second build", ctx do
    root = Path.join(ctx.dir, "proj")
    file = Path.join(ctx.build, "priv/assets/a.txt")

    File.write!(file, "from " <> Path.join(root, "deps/pkg/lib/pkg.ex"))
    v = PrivRepro.hold(ctx.pass, ctx.own)
    assert %{status: :skip, reason: "bakes the build path: priv/assets/a.txt"} = v
    assert v.compile_env == nil and v.compile_inputs == nil
    refute Map.has_key?(v, :priv_repro)
    refute Map.has_key?(v, :built_priv)

    File.write!(file, :zlib.gzip("x" <> root <> "/deps/pkg/lib/pkg.ex"))

    assert %{reason: "bakes the build path: priv/assets/a.txt"} =
             PrivRepro.hold(ctx.pass, ctx.own)
  end

  test "a priv that cannot be searched for the roots cannot be judged", ctx do
    v = PrivRepro.hold(ctx.pass, Map.delete(ctx.own, :roots))
    assert %{status: :skip, compile_env: nil, compile_inputs: nil} = v
    assert v.reason == Reasons.could_not_judge()
    refute Map.has_key?(v, :priv_repro)

    File.write!(Path.join(ctx.build, "priv/assets/a.txt"), <<0x1F, 0x8B, "not gzip">>)
    v = PrivRepro.hold(ctx.pass, ctx.own)
    assert v.reason == Reasons.could_not_judge()
    assert "priv/assets/a.txt: does not inflate" in v.observations["problems"]
  end

  test "a held pass keeps its foreign priv entries until the second build gives them back",
       %{dir: dir, pass: pass, own: own} do
    entry = %{"path" => "priv/assets/X/uxwh53kfq2wszgf23hqwgkuiza.tar.gz"}
    pass = Map.merge(pass, %{foreign_priv: [entry], foreign_priv_rule: "kino_js_v1"})
    held = PrivRepro.hold(pass, own)
    assert %{status: :skip, foreign_priv: nil, foreign_priv_rule: nil} = held
    assert %{foreign_priv: [^entry], foreign_priv_rule: "kino_js_v1"} = held.priv_repro

    assert %{status: :pass, foreign_priv: [^entry], foreign_priv_rule: "kino_js_v1"} =
             settle(held, dir, second(%{"assets/a.txt" => "a"}))
  end
end
