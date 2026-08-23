defmodule NccWorker.BuildCacheTest do
  use ExUnit.Case, async: true

  alias NccWorker.BuildCache

  # "a" depends on "b", "b" on "c", and "d" on nothing anyone else needs.
  # "j" and "k" point at each other, the way jason and decimal do.
  @graph %{
    "root" => ["a", "d", "j"],
    "a" => ["b"],
    "b" => ["c"],
    "j" => ["k"],
    "k" => ["j"]
  }

  @lock %{
    "a" => "1.0.0 aaa",
    "b" => "1.0.0 bbb",
    "c" => "1.0.0 ccc",
    "d" => "1.0.0 ddd",
    "j" => "1.0.0 jjj",
    "k" => "1.0.0 kkk"
  }

  defp key(name, lock \\ @lock, graph \\ @graph) do
    BuildCache.key_for(name, "rpi4", BuildCache.closure(graph, name), lock)
  end

  describe "closure/2" do
    test "reaches transitively and excludes the dependency itself" do
      assert BuildCache.closure(@graph, "a") == MapSet.new(["b", "c"])
    end

    test "terminates on mutually optional dependencies" do
      assert BuildCache.closure(@graph, "j") == MapSet.new(["k"])
    end

    test "is empty for a leaf" do
      assert BuildCache.closure(@graph, "c") == MapSet.new()
    end
  end

  describe "key_for/4" do
    test "changes when a transitive dependency changes version" do
      bumped = Map.put(@lock, "c", "2.0.0 ccc2")

      refute key("a") == key("a", bumped)
    end

    test "does not change when an unrelated dependency changes" do
      # This is the whole reason the key is a closure and not the full lock: if
      # every package's lock invalidated every entry, nothing would ever hit.
      unrelated = Map.put(@lock, "d", "9.9.9 zzz")

      assert key("a") == key("a", unrelated)
    end

    test "separates targets" do
      closure = BuildCache.closure(@graph, "a")

      refute BuildCache.key_for("a", "rpi4", closure, @lock) ==
               BuildCache.key_for("a", "x86_64", closure, @lock)
    end

    test "ignores the order dependencies come back in" do
      shuffled = %{@graph | "root" => ["j", "d", "a"], "a" => ["b"]}

      assert key("a") == key("a", @lock, shuffled)
    end
  end

  describe "plan/6" do
    test "is disabled when no cache is mounted" do
      assert BuildCache.plan(
               "/nonexistent",
               "/nonexistent/deps",
               "/nonexistent/_build",
               "rpi4",
               [],
               []
             ) == :disabled
    end

    test "restore and store are no-ops when disabled" do
      assert BuildCache.restore(:disabled) == {0, 0}
      assert BuildCache.store(:disabled) == 0
    end
  end

  describe "dep_target_agnostic?/2" do
    setup do
      deps = Path.join(System.tmp_dir!(), "ncc-deps-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(deps) end)
      {:ok, deps: deps}
    end

    defp write_dep(deps, name, files) do
      Enum.each(files, fn {path, contents} ->
        full = Path.join([deps, name, path])
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, contents)
      end)
    end

    test "clears a plain Elixir dependency", ctx do
      write_dep(ctx.deps, "jason", [
        {"mix.exs", "defmodule X do end"},
        {"lib/jason.ex", "defmodule Jason do end"}
      ])

      assert BuildCache.dep_target_agnostic?(ctx.deps, "jason")
    end

    test "holds out a dependency that is missing entirely", ctx do
      refute BuildCache.dep_target_agnostic?(ctx.deps, "absent")
    end

    test "holds out anything Nerves-owned by name", ctx do
      write_dep(ctx.deps, "nerves_system_rpi4", [{"mix.exs", "defmodule X do end"}])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "nerves_system_rpi4")
    end

    test "holds out a native build, by directory or by makefile", ctx do
      write_dep(ctx.deps, "with_c", [{"mix.exs", "x"}, {"c_src/port.c", "int main(){}"}])
      write_dep(ctx.deps, "with_make", [{"mix.exs", "x"}, {"Makefile", "all:"}])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "with_c")
      refute BuildCache.dep_target_agnostic?(ctx.deps, "with_make")
    end

    test "holds out a native build declared only in mix.exs", ctx do
      write_dep(ctx.deps, "porcelain", [
        {"mix.exs", "compilers: [:elixir_make] ++ Mix.compilers()"}
      ])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "porcelain")
    end

    test "holds out a rebar dependency with port specs", ctx do
      write_dep(ctx.deps, "reb", [
        {"rebar.config", "{port_specs, [{\"priv/x.so\", [\"c_src/*.c\"]}]}."}
      ])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "reb")
    end

    test "holds out a dependency that reads the target at compile time", ctx do
      write_dep(ctx.deps, "peeker", [
        {"mix.exs", "defmodule X do end"},
        {"lib/peeker.ex", "defmodule Peeker do @t Mix.target() end"}
      ])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "peeker")
    end

    test "does not confuse a beam file for a source read", ctx do
      write_dep(ctx.deps, "compiled", [
        {"mix.exs", "defmodule X do end"},
        {"ebin/Elixir.Compiled.beam", "MIX_TARGET"}
      ])

      assert BuildCache.dep_target_agnostic?(ctx.deps, "compiled")
    end
  end

  describe "restore/1 and store/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "ncc-cache-#{System.unique_integer([:positive])}")
      build = Path.join(root, "build")
      File.mkdir_p!(Path.join(root, "cache"))
      on_exit(fn -> File.rm_rf(root) end)

      {:ok, root: Path.join(root, "cache"), build: build}
    end

    test "stores a built dependency and restores it into an empty build", ctx do
      dir = Path.join([ctx.build, "lib", "a"])
      File.mkdir_p!(Path.join(dir, "ebin"))
      File.write!(Path.join([dir, "ebin", "a.beam"]), "beam")

      plan = %{root: ctx.root, entries: [%{name: "a", key: "k1", dir: dir}]}

      assert BuildCache.store(plan) == 1
      assert File.exists?(Path.join([ctx.root, "k1", "ebin", "a.beam"]))

      File.rm_rf!(dir)
      assert BuildCache.restore(plan) == {1, 1}
      assert File.read!(Path.join([dir, "ebin", "a.beam"])) == "beam"
    end

    test "leaves an already-present build directory alone", ctx do
      dir = Path.join([ctx.build, "lib", "a"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "marker"), "fresh")
      File.mkdir_p!(Path.join(ctx.root, "k1"))
      File.write!(Path.join([ctx.root, "k1", "marker"]), "cached")

      plan = %{root: ctx.root, entries: [%{name: "a", key: "k1", dir: dir}]}

      assert BuildCache.restore(plan) == {0, 1}
      assert File.read!(Path.join(dir, "marker")) == "fresh"
    end

    test "does not overwrite an entry the cache already holds", ctx do
      dir = Path.join([ctx.build, "lib", "a"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "marker"), "new")
      File.mkdir_p!(Path.join(ctx.root, "k1"))
      File.write!(Path.join([ctx.root, "k1", "marker"]), "first")

      plan = %{root: ctx.root, entries: [%{name: "a", key: "k1", dir: dir}]}

      assert BuildCache.store(plan) == 0
      assert File.read!(Path.join([ctx.root, "k1", "marker"])) == "first"
    end

    test "leaves nothing behind when there is no build to store", ctx do
      plan = %{
        root: ctx.root,
        entries: [%{name: "a", key: "k1", dir: Path.join([ctx.build, "lib", "a"])}]
      }

      assert BuildCache.store(plan) == 0
      assert File.ls!(ctx.root) == []
    end
  end
end
