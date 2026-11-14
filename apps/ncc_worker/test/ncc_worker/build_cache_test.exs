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

    test "holds out every spelling of a target read", ctx do
      for {file, body} <- [
            {"lib/a.ex", "@t Mix.target"},
            {"lib/a.ex", "if Mix.target == :host, do: 1"},
            {"lib/a.ex", "f = &Mix.target/0"},
            {"lib/a.ex", "Mix .\n  target()"},
            {"lib/a.ex", ~s|:"Elixir.Mix".target()|},
            {"lib/a.ex", "apply(Mix, :target, [])"},
            {"lib/a.ex", "import Mix, only: [target: 0]\ntarget()"},
            {"lib/a.ex", "alias Mix, as: M\nM.target()"},
            {"lib/a.ex", ~s|System.get_env("MIX_TARGET")|},
            {"src/a.erl", "t() -> 'Elixir.Mix':target()."},
            {"src/a.erl", "t() -> 'Elixir.Mix':'target'()."},
            {"src/a.erl", "-import('Elixir.Mix', [target/0]).\nt() -> target()."},
            {"include/a.hrl", "-define(T, 'Elixir.Mix' : target())."},
            {"lib/a.ex", "import(Mix, only: [target: 0])"},
            {"lib/a.ex", "alias(Mix, as: M)\nM.target()"},
            {"lib/a.ex", ~s|alias :"Elixir.Mix", as: M\nM.target()|},
            {"lib/a.ex", "mod = Mix\nmod.target()"},
            {"lib/a.ex", "defmacro __using__(_), do: quote(do: import(Mix))"},
            {"include/m.hrl", "-define(M, 'Elixir.Mix')."},
            {"lib/t.eex", "<%= Mix.target() %>"},
            {"lib/t.heex", "<p>{Mix.target()}</p>"},
            {"config/config.exs", ~s|config :a, t: System.get_env("MIX_TARGET")|}
          ] do
        name = "dep#{System.unique_integer([:positive])}"
        write_dep(ctx.deps, name, [{"mix.exs", "defmodule X do end"}, {file, body}])
        refute BuildCache.dep_target_agnostic?(ctx.deps, name), inspect(body)
      end
    end

    test "holds out a __using__ that imports Mix and an Erlang macro for Mix", ctx do
      write_dep(ctx.deps, "user", [
        {"mix.exs", "defmodule X do end"},
        {"lib/using.ex",
         "defmodule U do\n  defmacro __using__(_) do\n    quote do\n      import Mix\n    end\n  end\nend"},
        {"lib/caller.ex", "defmodule C do\n  use U\n  def t, do: target()\nend"}
      ])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "user")

      write_dep(ctx.deps, "erlmacro", [
        {"mix.exs", "defmodule X do end"},
        {"include/m.hrl", "-define(M, 'Elixir.Mix')."},
        {"src/a.erl", "-include(\"m.hrl\").\nt() -> ?M:target()."}
      ])

      refute BuildCache.dep_target_agnostic?(ctx.deps, "erlmacro")
    end

    test "keeps a dependency that only mentions Mix in prose or uses its submodules", ctx do
      write_dep(ctx.deps, "prose", [
        {"mix.exs", "defmodule X.MixProject do\n  use Mix.Project\nend"},
        {"lib/a.ex",
         "@moduledoc \"Build it with Mix, the target dir is _build.\"\nalias Mix.Project\nimport Mix.Config"},
        {"priv/static/app.js", "const target = event.target; // Mix"}
      ])

      assert BuildCache.dep_target_agnostic?(ctx.deps, "prose")
    end

    test "keeps a dependency whose target mentions are not Mix's", ctx do
      write_dep(ctx.deps, "aimer", [
        {"mix.exs", "defmodule X do end"},
        {"lib/a.ex", "def target(x), do: x\nMix.targets_of(1)\nimport Mix.Config"}
      ])

      assert BuildCache.dep_target_agnostic?(ctx.deps, "aimer")
    end

    test "does not confuse a beam file for a source read", ctx do
      write_dep(ctx.deps, "compiled", [
        {"mix.exs", "defmodule X do end"},
        {"ebin/Elixir.Compiled.beam", "MIX_TARGET"}
      ])

      assert BuildCache.dep_target_agnostic?(ctx.deps, "compiled")
    end
  end

  describe "dep_target_agnostic_rule2?/3 text checks" do
    setup do
      deps = Path.join(System.tmp_dir!(), "ncc-deps2-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(deps) end)
      {:ok, deps: deps}
    end

    defp write_dep2(deps, name, files) do
      Enum.each(files, fn {path, contents} ->
        full = Path.join([deps, name, path])
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, contents)
      end)
    end

    # tds 2.3.x's mix.exs: a leftover `rustler_crates` key, no rustler
    # dependency, no compiler, no native sources.
    @tds_mix_exs """
    defmodule Tds.Mixfile do
      use Mix.Project
      def project do
        [
          app: :tds,
          deps: [{:decimal, "~> 2.0"}, {:db_connection, "~> 2.0"}],
          rustler_crates: [
            tds_encoding: [mode: if(Mix.env() == :prod, do: :release, else: :debug)]
          ]
        ]
      end
    end
    """

    test "a leftover rustler_crates key is not a native build under rule 2", ctx do
      write_dep2(ctx.deps, "tds", [
        {"mix.exs", @tds_mix_exs},
        {"lib/tds.ex", "defmodule Tds do end"}
      ])

      assert BuildCache.dep_target_agnostic_rule2?(ctx.deps, "tds", "mix")
      # Rule 1 and the cache keys keep the substring match.
      refute BuildCache.dep_target_agnostic?(ctx.deps, "tds")
    end

    test "a native tool named as a whole word still refuses under rule 2", ctx do
      for body <- [
            ~s|deps: [{:rustler, "~> 0.30"}]|,
            ~s|deps: [{:rustler_precompiled, "~> 0.8"}]|,
            "compilers: [:elixir_make] ++ Mix.compilers()",
            ~s|deps: [{:zigler, "~> 0.13"}]|,
            ~s|deps: [{:cc_precompiler, "~> 0.1"}]|,
            "make_precompiler: {:nif, CCPrecompiler}, x: :elixir_make",
            "# uses rustler\n"
          ] do
        name = "nat#{System.unique_integer([:positive])}"
        write_dep2(ctx.deps, name, [{"mix.exs", body}])
        refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix"), body
      end
    end

    test "erlang.mk's mixer description is not a target read under rule 2", ctx do
      write_dep2(ctx.deps, "ranch", [
        {"rebar.config", "{deps, []}.\n"},
        {"src/ranch.erl", "-module(ranch).\n"},
        {"erlang.mk",
         "pkg_mixer_name = mixer\npkg_mixer_description = Mix in functions from other modules\n"}
      ])

      assert BuildCache.dep_target_agnostic_rule2?(ctx.deps, "ranch", "rebar3")
      refute BuildCache.dep_target_agnostic?(ctx.deps, "ranch")
    end

    test "every spelling of a target read still refuses under rule 2", ctx do
      for {file, body} <- [
            {"lib/a.ex", "@t Mix.target"},
            {"lib/a.ex", "f = &Mix.target/0"},
            {"lib/a.ex", ~s|:"Elixir.Mix".target()|},
            {"lib/a.ex", "apply(Mix, :target, [])"},
            {"lib/a.ex", "import Mix, only: [target: 0]\ntarget()"},
            {"lib/a.ex", "alias Mix, as: M\nM.target()"},
            {"lib/a.ex", ~s|System.get_env("MIX_TARGET")|},
            {"src/a.erl", "t() -> 'Elixir.Mix':target()."},
            {"include/m.hrl", "-define(M, 'Elixir.Mix')."},
            {"lib/a.ex", "mod = Mix\nmod.target()"},
            {"lib/a.ex", "mod = Mix\n  in_list = 1\nmod.target()"},
            {"lib/a.ex", "mod = Mix inspect"},
            {"lib/a.ex", "mod = Mix; x in y"}
          ] do
        name = "dep#{System.unique_integer([:positive])}"
        write_dep2(ctx.deps, name, [{"mix.exs", "defmodule X do end"}, {file, body}])
        refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix"), inspect(body)
      end
    end
  end

  describe "dep_target_agnostic_rule2?/4 for the package under test (own: true)" do
    setup do
      deps = Path.join(System.tmp_dir!(), "ncc-deps-own-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(deps) end)
      {:ok, deps: deps}
    end

    defp write_own(deps, name, files) do
      Enum.each(files, fn {path, contents} ->
        full = Path.join([deps, name, path])
        File.mkdir_p!(Path.dirname(full))
        File.write!(full, contents)
      end)
    end

    # The real elixir_make 0.10.1 tree (Hex tarball contents), stored with a
    # `.txt` suffix so nothing formats or compiles it.
    @elixir_make Path.expand("../fixtures/elixir_make-0.10.1", __DIR__)

    defp copy_elixir_make(deps) do
      for src <- Path.wildcard(Path.join(@elixir_make, "**/*.txt"), match_dot: true) do
        rel = src |> Path.relative_to(@elixir_make) |> String.replace_suffix(".txt", "")
        dest = Path.join([deps, "elixir_make", rel])
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(src, dest)
      end
    end

    test "elixir_make itself passes; as a dependency, or without own:, it does not", ctx do
      copy_elixir_make(ctx.deps)

      assert BuildCache.dep_target_agnostic_rule2?(ctx.deps, "elixir_make", "mix", own: true)
      refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, "elixir_make", "mix")
      refute BuildCache.dep_target_agnostic?(ctx.deps, "elixir_make")
    end

    test "another native tool, a native dir or port_specs still refuses", ctx do
      for {files, why} <- [
            {[{"mix.exs", "app: :elixir_make, compilers: [:rustler]"}], "another tool"},
            {[{"mix.exs", "app: :elixir_make"}, {"c_src/a.c", ""}], "native dir"},
            {[{"mix.exs", "app: :elixir_make"}, {"rebar.config", "{port_specs, []}."}],
             "port_specs"},
            {[{"mix.exs", "app: :x, deps: [{:elixir_make, \"~> 0.9\"}]"}], "uses elixir_make"}
          ] do
        name = if why == "uses elixir_make", do: "x", else: "elixir_make"
        File.rm_rf!(Path.join(ctx.deps, name))
        write_own(ctx.deps, name, files)
        refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix", own: true), why
      end
    end

    test "a target read only in a function body, docs, a comment or a doc file passes", ctx do
      for {file, body} <- [
            {"lib/a.ex", "defmodule A do\n  def t, do: Mix.target()\nend\n"},
            {"lib/a.ex",
             "defmodule A do\n  defp e, do: %{\"MIX_TARGET\" => System.get_env(\"MIX_TARGET\")}\nend\n"},
            {"lib/a.ex",
             "defmodule A do\n  @moduledoc \"\"\"\n  Set `MIX_TARGET`.\n  \"\"\"\n  @doc \"Mix.target\"\n  def x, do: 1\nend\n"},
            {"lib/a.ex", "defmodule A do\n  # Mix.target() is not used\n  def x, do: 1\nend\n"},
            {"lib/a.ex",
             "defmodule A do\n  def t(x) when x == 1 do\n    mod = Mix\n    mod.target()\n  end\nend\n"},
            {"README.md", "export MIX_TARGET=rpi0\n"},
            {"CHANGELOG.markdown", "Mix.target\n"},
            {"NOTES.txt", "MIX_TARGET\n"},
            {"LICENSE.md", "MIX_TARGET\n"}
          ] do
        name = "own#{System.unique_integer([:positive])}"
        write_own(ctx.deps, name, [{"mix.exs", "defmodule X do end"}, {file, body}])
        assert BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix", own: true), body
        refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix"), body
      end
    end

    test "a target read that can run at compile time still refuses", ctx do
      for {file, body} <- [
            # Module level, an attribute, a macro body, an unquote fragment
            # in a def, a non-literal doc, a mix.exs anywhere.
            {"lib/a.ex", "defmodule A do\n  @t Mix.target()\n  def t, do: @t\nend\n"},
            {"lib/a.ex", "defmodule A do\n  if Mix.target() == :host, do: def(x, do: 1)\nend\n"},
            {"lib/a.ex",
             "defmodule A do\n  @e System.get_env(\"MIX_TARGET\")\n  def e, do: @e\nend\n"},
            {"lib/a.ex", "defmodule A do\n  defmacro t, do: Mix.target()\nend\n"},
            {"lib/a.ex",
             "defmodule A do\n  defmacro __using__(_) do\n    quote do\n      @t Mix.target()\n    end\n  end\nend\n"},
            {"lib/a.ex", "defmodule A do\n  def t, do: unquote(Mix.target())\nend\n"},
            {"lib/a.ex", "defmodule A do\n  def unquote(Mix.target())(), do: 1\nend\n"},
            {"lib/a.ex", "defmodule A do\n  @doc \"on \#{Mix.target()}\"\n  def x, do: 1\nend\n"},
            {"lib/a.ex", "defmodule A do\n  mod = Mix\n  @t mod.target()\nend\n"},
            {"lib/a.ex", "defmodule A do\n  import Mix, only: [target: 0]\nend\n"},
            {"lib/a.ex", "defmodule A do\n  @t :\"Elixir.Mix\".target()\nend\n"},
            {"lib/a.ex", "defmodule A do\n  @t apply(Mix, :target, [])\nend\n"},
            {"lib/a.exs", "IO.puts(Mix.target())\n"},
            {"mix.exs",
             "defmodule X do\n  def project, do: [t: Mix.target()]\n  def t, do: Mix.target()\nend\n"},
            {"lib/sub/mix.exs", "defmodule Y do\n  def t, do: Mix.target()\nend\n"},
            # Not Elixir: the raw pattern.
            {"src/a.erl", "t() -> 'Elixir.Mix':target()."},
            {"lib/a.eex", "<%= Mix.target() %>"},
            # Does not parse: the raw pattern.
            {"lib/a.ex", "defmodule A do\n  def t, do: Mix.target(\n"}
          ] do
        name = "own#{System.unique_integer([:positive])}"

        files =
          if file == "mix.exs",
            do: [{file, body}],
            else: [{"mix.exs", "defmodule X do end"}, {file, body}]

        write_own(ctx.deps, name, files)
        refute BuildCache.dep_target_agnostic_rule2?(ctx.deps, name, "mix", own: true), body
      end
    end
  end

  describe "match_or_error?/2" do
    test "an engine error counts as a match" do
      # Catastrophic backtracking: PCRE gives up with a match limit error,
      # which `:re.run/3` without `:report_errors` reports as no match (and
      # `Regex.match?/2` reports as no match before Elixir 1.20, which raises).
      regex = ~r/(.*a){25}/
      subject = String.duplicate("a", 30) <> "!"

      assert :re.run(subject, Regex.source(regex), Regex.opts(regex) ++ [capture: :none]) ==
               :nomatch

      assert BuildCache.match_or_error?(regex, subject)
    end

    test "answers like Regex.match?/2 otherwise" do
      assert BuildCache.match_or_error?(~r/Mix\.target/, "x = Mix.target()")
      refute BuildCache.match_or_error?(~r/Mix\.target/, "x = Mix.env()")
      assert BuildCache.match_or_error?(~r/mix/i, "MIX")
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

    # A cache problem must not crash the worker (exit 10): no candidate.
    test "store with an out dir that cannot be created stores no candidate", ctx do
      dir = Path.join(ctx.tmp, "_build/host/lib/pkg")
      File.mkdir_p!(Path.join(dir, "ebin"))
      File.write!(Path.join(dir, "ebin/x.beam"), "beam")

      plan = %{
        root: ctx.root,
        local_root: Path.join(ctx.tmp, "local"),
        entries: [
          %{
            name: "pkg",
            key: String.duplicate("a", 64),
            dir: dir,
            shared: false,
            restore?: false,
            inputs: %{}
          }
        ]
      }

      assert [] = BuildCache.store(plan, "/dev/null/build-cache")
    end

    test "local_tier/1 is nil when the run-local tier cannot be created", ctx do
      assert BuildCache.local_tier("/dev/null/ncc-build-cache") == nil

      local = Path.join(ctx.tmp, "local")
      assert BuildCache.local_tier(local) == local
      assert File.dir?(local)
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

    test "looks in both tiers and never counts the package under test", ctx do
      local = Path.join(ctx.root, "local")
      File.mkdir_p!(Path.join(local, "only-local"))

      plan = %{
        root: Path.join(ctx.root, "shared"),
        local_root: local,
        entries: [
          %{name: "a", key: "only-local", dir: "/x/a", shared: true, restore?: true},
          %{name: "b", key: "absent", dir: "/x/b", shared: true, restore?: true},
          %{name: "pkg", key: "pkg-key", dir: "/x/pkg", shared: true, restore?: false}
        ]
      }

      assert BuildCache.missing_shared(plan) == 1
    end

    test "is zero when disabled" do
      assert BuildCache.missing_shared(:disabled) == 0
    end
  end
end
