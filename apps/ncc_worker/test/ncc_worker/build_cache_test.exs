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

    # Production caches hold entries under these keys. Moving the function to
    # apps/compatibility must not change one byte of its output, or every
    # cached entry silently becomes a miss.
    test "matches the key format production caches were written with" do
      closure = MapSet.new(["b", "c"])

      expected =
        [
          "v2",
          "elixir=" <> System.version(),
          "otp=" <> to_string(:erlang.system_info(:otp_release)),
          "target=rpi4",
          "dep=a " <> @lock["a"],
          "b " <> @lock["b"],
          "c " <> @lock["c"]
        ]
        |> Enum.join("\n")
        |> then(&:crypto.hash(:sha256, &1))
        |> Base.encode16(case: :lower)

      assert BuildCache.key_for("a", "rpi4", closure, @lock) == expected
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
               exclude: ["nerves_compatibility_test"],
               package: "a"
             ) == :disabled
    end

    test "restore and store are no-ops when disabled" do
      assert BuildCache.restore(:disabled) == {0, 0}
      assert BuildCache.store(:disabled, "/nonexistent") == []
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

  describe "restore/1 and store/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "ncc-cache-#{System.unique_integer([:positive])}")
      build = Path.join(tmp, "build")
      File.mkdir_p!(Path.join(tmp, "cache"))
      on_exit(fn -> File.rm_rf(tmp) end)

      {:ok, tmp: tmp, root: Path.join(tmp, "cache"), build: build}
    end

    test "stores a built dependency to the local tier and restores it into an empty build", ctx do
      dir = Path.join([ctx.build, "lib", "a"])
      File.mkdir_p!(Path.join(dir, "ebin"))
      File.write!(Path.join([dir, "ebin", "a.beam"]), "beam")

      local = Path.join(ctx.tmp, "local")
      out = Path.join(ctx.tmp, "out")

      plan = %{
        root: ctx.root,
        local_root: local,
        entries: [%{name: "a", key: "k1", dir: dir, restore?: true}]
      }

      assert BuildCache.store(plan, out) == []
      assert File.exists?(Path.join([local, "k1", "ebin", "a.beam"]))
      refute File.exists?(Path.join(ctx.root, "k1"))

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

      plan = %{root: ctx.root, entries: [%{name: "a", key: "k1", dir: dir, restore?: true}]}

      assert BuildCache.restore(plan) == {0, 1}
      assert File.read!(Path.join(dir, "marker")) == "fresh"
    end

    test "does not store a dependency the shared cache already holds", ctx do
      dir = Path.join([ctx.build, "lib", "a"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "marker"), "new")
      File.mkdir_p!(Path.join(ctx.root, "k1"))
      File.write!(Path.join([ctx.root, "k1", "marker"]), "first")

      local = Path.join(ctx.tmp, "local")
      out = Path.join(ctx.tmp, "out")

      plan = %{
        root: ctx.root,
        local_root: local,
        entries: [%{name: "a", key: "k1", dir: dir, restore?: true}]
      }

      assert BuildCache.store(plan, out) == []
      assert File.read!(Path.join([ctx.root, "k1", "marker"])) == "first"
      refute File.exists?(Path.join(local, "k1"))
    end

    test "leaves nothing behind when there is no build to store", ctx do
      local = Path.join(ctx.tmp, "local")
      out = Path.join(ctx.tmp, "out")

      plan = %{
        root: ctx.root,
        local_root: local,
        entries: [
          %{name: "a", key: "k1", dir: Path.join([ctx.build, "lib", "a"]), restore?: true}
        ]
      }

      assert BuildCache.store(plan, out) == []
      assert File.ls!(ctx.root) == []
      refute File.exists?(local)
      refute File.exists?(out)
    end

    test "store writes only the package under test, to the out dir, never the cache root", ctx do
      root = Path.join(ctx.tmp, "cache")
      local = Path.join(ctx.tmp, "local")
      out = Path.join(ctx.tmp, "out/build-cache")
      File.mkdir_p!(root)

      pkg_dir = Path.join(ctx.tmp, "_build/host/lib/pkg")
      dep_dir = Path.join(ctx.tmp, "_build/host/lib/dep")

      for d <- [pkg_dir, dep_dir],
          do:
            File.mkdir_p!(Path.join(d, "ebin")) &&
              File.write!(Path.join(d, "ebin/x.beam"), "beam")

      inputs = fn dep ->
        %{
          elixir: "1.20.3",
          otp: "29",
          target: "host",
          dep: dep,
          dep_lock: "1.0.0 aa bb",
          closure: [{"dep", "2.0.0 cc dd"}]
        }
      end

      plan = %{
        root: root,
        local_root: local,
        entries: [
          %{
            name: "pkg",
            key: String.duplicate("a", 64),
            dir: pkg_dir,
            shared: false,
            restore?: false,
            inputs: inputs.("pkg")
          },
          %{
            name: "dep",
            key: String.duplicate("b", 64),
            dir: dep_dir,
            shared: false,
            restore?: true,
            inputs: inputs.("dep")
          }
        ]
      }

      assert [
               %{
                 "key" => key,
                 "dep" => "pkg",
                 "dep_lock" => "1.0.0 aa bb",
                 "target" => "host",
                 "elixir" => "1.20.3",
                 "otp" => "29",
                 "closure" => [%{"name" => "dep", "lock" => "2.0.0 cc dd"}]
               }
             ] = BuildCache.store(plan, out)

      assert key == String.duplicate("a", 64)
      assert File.regular?(Path.join([out, key, "ebin/x.beam"]))
      refute File.exists?(Path.join(out, String.duplicate("b", 64)))
      assert File.ls!(root) == []
      assert File.regular?(Path.join([local, String.duplicate("b", 64), "ebin/x.beam"]))
    end

    test "restore never fills the package under test", ctx do
      root = Path.join(ctx.tmp, "cache")
      key = String.duplicate("a", 64)
      File.mkdir_p!(Path.join([root, key, "ebin"]))
      dir = Path.join(ctx.tmp, "_build/host/lib/pkg")

      plan = %{
        root: root,
        entries: [%{name: "pkg", key: key, dir: dir, shared: false, restore?: false, inputs: %{}}]
      }

      assert {0, 1} = BuildCache.restore(plan)
      refute File.exists?(dir)
    end

    test "store on a disabled plan writes nothing" do
      assert [] = BuildCache.store(:disabled, "/nonexistent")
    end

    # Amendment 5: one target's compile of a shared dependency is restored by
    # the next target in the same run, from the run-local tier, without ever
    # touching the shared root or the out dir.
    test "a dependency stored by one target is restored by the next from the run-local tier",
         ctx do
      root = Path.join(ctx.tmp, "cache")
      local = Path.join(ctx.tmp, "local")
      out = Path.join(ctx.tmp, "out/build-cache")
      File.mkdir_p!(root)
      File.mkdir_p!(local)
      key = String.duplicate("c", 64)

      first = Path.join(ctx.tmp, "_build/rpi4/lib/dep")
      File.mkdir_p!(Path.join(first, "ebin"))
      File.write!(Path.join(first, "ebin/d.beam"), "beam")

      entry = fn dir ->
        %{name: "dep", key: key, dir: dir, shared: true, restore?: true, inputs: %{}}
      end

      assert [] =
               BuildCache.store(%{root: root, local_root: local, entries: [entry.(first)]}, out)

      assert File.regular?(Path.join([local, key, "ebin/d.beam"]))
      assert File.ls!(root) == []
      refute File.exists?(out)

      second = Path.join(ctx.tmp, "_build/x86_64/lib/dep")

      assert {1, 1} =
               BuildCache.restore(%{root: root, local_root: local, entries: [entry.(second)]})

      assert File.regular?(Path.join(second, "ebin/d.beam"))
    end

    test "restore prefers the shared root over the run-local tier", ctx do
      root = Path.join(ctx.tmp, "cache")
      local = Path.join(ctx.tmp, "local")
      key = String.duplicate("f", 64)

      for {base, body} <- [{root, "shared"}, {local, "local"}] do
        File.mkdir_p!(Path.join([base, key, "ebin"]))
        File.write!(Path.join([base, key, "ebin/x.beam"]), body)
      end

      dir = Path.join(ctx.tmp, "_build/host/lib/dep")

      plan = %{
        root: root,
        local_root: local,
        entries: [%{name: "dep", key: key, dir: dir, shared: false, restore?: true, inputs: %{}}]
      }

      assert {1, 1} = BuildCache.restore(plan)
      assert File.read!(Path.join(dir, "ebin/x.beam")) == "shared"
    end
  end

  describe "missing_shared/1" do
    setup do
      root = Path.join(System.tmp_dir!(), "ncc-cache-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)
      {:ok, root: root}
    end

    test "counts only shared entries the cache does not hold", ctx do
      File.mkdir_p!(Path.join(ctx.root, "held"))

      plan = %{
        root: ctx.root,
        entries: [
          %{name: "a", key: "held", dir: "/x/a", shared: true},
          %{name: "b", key: "absent1", dir: "/x/b", shared: true},
          %{name: "c", key: "absent2", dir: "/x/c", shared: false}
        ]
      }

      assert BuildCache.missing_shared(plan) == 1
    end

    test "is zero when disabled" do
      assert BuildCache.missing_shared(:disabled) == 0
    end
  end
end
