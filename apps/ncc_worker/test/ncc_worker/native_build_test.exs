defmodule NccWorker.NativeBuildTest do
  use ExUnit.Case, async: true

  alias NccWorker.{BuildCache, BuildSelection, NativeBuild}

  @moduletag :tmp_dir

  # A Hex tarball whose `metadata.config` lists `build_tools` (`nil`: no key).
  defp tools_tarball(build_tools) do
    meta =
      [{"name", "x"}, {"version", "1.0.0"}] ++
        if(build_tools, do: [{"build_tools", build_tools}], else: [])

    meta = Enum.map_join(meta, "", &IO.chardata_to_string(:io_lib.format(~c"~p.~n", [&1])))
    path = Path.join(System.tmp_dir!(), "ncc-tools-#{System.unique_integer([:positive])}.tar")
    :ok = :erl_tar.create(String.to_charlist(path), [{~c"metadata.config", meta}])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  # The verified tarball of each dependency `dep/4` made, by name.
  defp tarball_of(root), do: &read_tarball(root, &1)

  defp read_tarball(root, name) do
    case File.read(Path.join([root, "tarballs", name <> ".tar"])) do
      {:ok, bytes} -> bytes
      _ -> nil
    end
  end

  # deps/<name> with `files` (path => body), its lock entry's managers and
  # a verified tarball whose `build_tools` are the same; `nil` managers
  # leave the dependency out of the lock and give it no tarball.
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

    if managers do
      File.mkdir_p!(Path.join(root, "tarballs"))
      tools = Enum.map(managers, &Atom.to_string/1)
      File.write!(Path.join([root, "tarballs", name <> ".tar"]), tools_tarball(tools))
    end

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

    assert NativeBuild.split(root, tarball_of(root)) ==
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

  describe "the build tools come from the verified tarball, never mix.lock" do
    test "build_tools/1 reads metadata.config and fails closed" do
      assert NativeBuild.build_tools(tools_tarball(["make", "rebar3"])) == ["make", "rebar3"]
      assert NativeBuild.build_tools(tools_tarball(nil)) == nil
      assert NativeBuild.build_tools(tools_tarball([])) == nil
      assert NativeBuild.build_tools("not a tar") == nil
      assert NativeBuild.build_tools(nil) == nil
    end

    test "a lock saying rebar3 over a tarball saying make stays native", %{tmp_dir: root} do
      dep(root, "ranch", %{"Makefile" => "all:\n", "src/ranch.erl" => "-module(ranch).\n"}, [
        :rebar3
      ])

      File.write!(Path.join([root, "tarballs", "ranch.tar"]), tools_tarball(["make"]))
      assert NativeBuild.split(root, tarball_of(root)) == {["ranch"], %{}}

      # No verified tarball: native, whatever the lock says.
      assert NativeBuild.split(root, fn _ -> nil end) == {["ranch"], %{}}

      # The tarball agreeing declassifies it.
      File.write!(Path.join([root, "tarballs", "ranch.tar"]), tools_tarball(["rebar3"]))
      assert NativeBuild.split(root, tarball_of(root)) == {[], %{"ranch" => "rebar3"}}

      dest = Path.join([root, "deps", "ranch"])
      assert NativeBuild.manager({:binary, tools_tarball(["make"])}, dest) == "make"
      assert NativeBuild.manager({:binary, tools_tarball(["make", "rebar3"])}, dest) == "rebar3"
      assert NativeBuild.manager(nil, dest) == nil
    end
  end
end
