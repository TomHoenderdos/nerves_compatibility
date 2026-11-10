defmodule NccWorker.NativeBuildTest do
  use ExUnit.Case, async: true

  alias NccWorker.{BuildCache, BuildSelection, NativeBuild}

  @moduletag :tmp_dir

  # deps/<name> with `files` (path => body) and its lock entry's managers;
  # `nil` managers leave the dependency out of the lock.
  defp dep(root, name, files, managers) do
    dir = Path.join([root, "deps", name])
    File.mkdir_p!(dir)

    Enum.each(files, fn {path, body} ->
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), body)
    end)

    lock = Path.join(root, "mix.lock")
    {entries, _} = if File.exists?(lock), do: Code.eval_file(lock), else: {%{}, []}

    entries =
      if managers,
        do:
          Map.put(
            entries,
            name,
            {:hex, String.to_atom(name), "1.0.0", "i", managers, [], "hexpm", "o"}
          ),
        else: entries

    File.write!(lock, inspect(entries, limit: :infinity))
    dir
  end

  describe "computed/2 (Mix.Dep.Loader: lock managers, then files)" do
    test "mix wins over rebar3, which wins over the files", %{tmp_dir: root} do
      dir = dep(root, "x", %{"Makefile" => "all:\n", "rebar.config" => "{erl_opts, []}.\n"}, [])
      assert NativeBuild.computed(["make", "rebar3"], dir) == "rebar3"
      assert NativeBuild.computed(["rebar3", "mix"], dir) == "mix"
      assert NativeBuild.computed(["make"], dir) == "rebar3"
      assert NativeBuild.computed(nil, dir) == nil
    end

    test "an empty managers list falls to the files: mix.exs, rebar files, then Makefile",
         %{tmp_dir: root} do
      assert NativeBuild.computed([], dep(root, "m", %{"mix.exs" => ""}, [])) == "mix"
      assert NativeBuild.computed([], dep(root, "r", %{"rebar.lock" => ""}, [])) == "rebar3"
      assert NativeBuild.computed([], dep(root, "k", %{"Makefile" => ""}, [])) == "make"
      assert NativeBuild.computed([], dep(root, "e", %{}, [])) == nil
    end
  end

  test "split/1 declassifies only a native build file Mix never runs", %{tmp_dir: root} do
    dep(root, "ranch", %{"Makefile" => "all:\n", "src/ranch.erl" => "-module(ranch).\n"}, [
      :make,
      :rebar3
    ])

    dep(root, "makeonly", %{"Makefile" => "all:\n"}, [:make])
    dep(root, "csrc", %{"c_src/x.c" => "", "rebar.config" => "{erl_opts, []}.\n"}, [:rebar3])
    dep(root, "emake", %{"Makefile" => "", "mix.exs" => "compilers: [:elixir_make]"}, [:mix])
    dep(root, "unlocked", %{"Makefile" => "all:\n"}, nil)
    dep(root, "plain", %{"mix.exs" => "defmodule P.MixProject do end"}, [:mix])
    # A Makefile Mix never runs beside another rule-2 refusal stays native.
    dep(root, "portenv", %{"Makefile" => "", "rebar.config" => "{port_env, []}.\n"}, [
      :make,
      :rebar3
    ])

    dep(root, "target", %{"Makefile" => "", "lib/t.ex" => "Mix.target()"}, [:make, :rebar3])
    dep(root, "nerves_foo", %{"Makefile" => "", "src/f.erl" => "-module(f).\n"}, [:make, :rebar3])
    dep(root, "csrcmix", %{"Makefile" => "", "c_src/x.c" => "", "mix.exs" => ""}, [:mix])

    assert NativeBuild.split(root) ==
             {[
                "csrc",
                "csrcmix",
                "emake",
                "makeonly",
                "nerves_foo",
                "portenv",
                "target",
                "unlocked"
              ], %{"ranch" => "rebar3"}}
  end

  test "under make or no manager, the rule-2 predicate is dep_target_agnostic?/2",
       %{tmp_dir: root} do
    fixtures = %{
      "plain" => %{"mix.exs" => "defmodule P.MixProject do end"},
      "makefile" => %{"Makefile" => "all:\n", "src/a.erl" => "-module(a).\n"},
      "cmake" => %{"CMakeLists.txt" => "", "mix.exs" => ""},
      "gnumake" => %{"GNUmakefile" => ""},
      "csrc" => %{"c_src/x.c" => ""},
      "zig" => %{"zig_src/x.zig" => ""},
      "emake" => %{"mix.exs" => "compilers: [:elixir_make]"},
      "rustler" => %{"mix.exs" => "{:rustler, \"~> 0.30\"}"},
      "portspecs" => %{"rebar.config" => "{port_specs, []}.\n"},
      "portenv" => %{"rebar.config" => "{port_env, []}.\n"},
      "target" => %{"lib/t.ex" => "Mix.target()"},
      "nerves_foo" => %{"mix.exs" => ""}
    }

    Enum.each(fixtures, fn {name, files} -> dep(root, name, files, [:rebar3]) end)
    deps = Path.join(root, "deps")

    for name <- ["missing" | Map.keys(fixtures)], manager <- ["make", nil] do
      assert BuildCache.dep_target_agnostic_rule2?(deps, name, manager) ==
               BuildCache.dep_target_agnostic?(deps, name),
             "#{name} under #{inspect(manager)}"
    end

    # Only the plain one is agnostic, so the comparison above is not vacuous.
    assert Enum.filter(Map.keys(fixtures), &BuildCache.dep_target_agnostic?(deps, &1)) ==
             ["plain"]
  end

  test "rule 1, the build cache and the Nerves classification do not move", %{tmp_dir: root} do
    dep(root, "ranch", %{"Makefile" => "all:\n", "src/ranch.erl" => "-module(ranch).\n"}, [
      :make,
      :rebar3
    ])

    deps = Path.join(root, "deps")

    # `BuildCache.agnostic_deps/4`, and so the `plan/6` keys, and
    # `classify/4` read only this predicate.
    refute BuildCache.dep_target_agnostic?(deps, "ranch")
    assert BuildCache.dep_target_agnostic_rule2?(deps, "ranch", "rebar3")
    refute BuildCache.dep_target_agnostic_rule2?(deps, "ranch", "make")
    refute BuildCache.dep_target_agnostic_rule2?(deps, "ranch", nil)
    assert BuildSelection.classify(root, "ranch", "", %{"root" => ["ranch"]}) == :firmware
  end
end
