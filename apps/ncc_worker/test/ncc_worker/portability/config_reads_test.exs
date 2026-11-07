defmodule NccWorker.Portability.ConfigReadsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{ConfigReads, Context}

  @elixir "1.19.5"

  # Every owner's dependency tree, as `ConfigReads.trees/1` gives it.
  @trees %{
    "pkg" => ["dep", "fx", "phoenix_live_view", "pkg"],
    "dep" => ["dep", "phoenix_live_view"]
  }

  defp read(app, key, opts \\ []) do
    %{
      "mfa" => Keyword.get(opts, :mfa, "application:get_env/2"),
      "arg" => %{
        "app" => app,
        "key" => key,
        "app_name" => app,
        "key_name" => key,
        "atoms" => Keyword.get(opts, :atoms, true)
      },
      "module" => "Elixir.Pkg",
      "file" => "lib/pkg.ex",
      "line" => 3,
      "first" => Keyword.get(opts, :first, "Elixir.Pkg"),
      "first_kind" => Keyword.get(opts, :kind, "user"),
      "extent" => "frame"
    }
  end

  defp obs(owner, item), do: {owner, {:observe, "config_reads", item}}
  defp snap(entries, truncated \\ false), do: %{entries: entries, truncated: truncated}

  defp enc(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp keys(result), do: Enum.map(result.items, &{&1.app, &1.path})
  defp judge(decided, snapshot), do: ConfigReads.judge(decided, @elixir, snapshot, @trees)

  test "the closure's reads are recorded once, valued from the snapshot, :error when unset" do
    decided = [
      obs("pkg", read("fx", "k")),
      obs("dep", read("phoenix_live_view", "root_tag_attribute")),
      obs("pkg", read("fx", "k")),
      {"pkg", :ignore}
    ]

    result = judge(decided, snap(%{{"fx", "k"} => enc({:ok, 42})}))

    assert %{refusals: [], problems: [], unreviewed: []} = result

    assert result.items == [
             %{app: "fx", path: ["k"], value: enc({:ok, 42})},
             %{app: "phoenix_live_view", path: ["root_tag_attribute"], value: enc(:error)}
           ]

    assert ConfigReads.unset() == enc(:error)
  end

  test "a key the snapshot holds records its value, whoever reads it" do
    decided = [obs(:outside, read("other", "k")), obs("dep", read("fx", "k"))]
    entries = %{{"other", "k"} => enc({:ok, :set}), {"fx", "k"} => enc({:ok, 1})}

    assert %{problems: [], items: items} = judge(decided, snap(entries))

    assert items == [
             %{app: "fx", path: ["k"], value: enc({:ok, 1})},
             %{app: "other", path: ["k"], value: enc({:ok, :set})}
           ]
  end

  # The two-dependency closure that shows the compile-order dependence: `a`
  # sets `k` in its .app env, `r` reads `Application.get_env(:a, :k)` at
  # compile time. Mix loads a dependency's .app once it has compiled it, so
  # `r` sees the default when `a` is in its tree (always compiled first) and
  # otherwise only when the consumer's dependency graph happens to compile
  # `a` first.
  describe "a read of a key the project leaves unset" do
    defp ctx(r_children) do
      dep = %{dest: nil, build: nil, manager: "mix", native?: false, hex_files: nil}

      %Context{
        deps: %{
          "a" => Map.put(dep, :children, []),
          "r" => Map.put(dep, :children, r_children)
        }
      }
    end

    test "is unset when the app is in the reader's dependency tree" do
      trees = ConfigReads.trees(ctx(["a"]))
      assert trees == %{"a" => ["a"], "r" => ["a", "r"]}

      result = ConfigReads.judge([obs("r", read("a", "k"))], @elixir, snap(%{}), trees)
      assert %{problems: [], items: [%{app: "a", path: ["k"], value: value}]} = result
      assert value == ConfigReads.unset()
    end

    test "is unset when the reader reads its own app" do
      trees = ConfigReads.trees(ctx([]))
      result = ConfigReads.judge([obs("r", read("r", "k"))], @elixir, snap(%{}), trees)
      assert %{problems: [], items: [%{app: "r", value: value}]} = result
      assert value == ConfigReads.unset()
    end

    test "cannot be told when the app is outside the reader's tree" do
      trees = ConfigReads.trees(ctx([]))

      assert %{items: [], problems: ["config value cannot be told: a k"]} =
               ConfigReads.judge([obs("r", read("a", "k"))], @elixir, snap(%{}), trees)
    end

    test "cannot be told when any of its readers has the app outside its tree" do
      trees = ConfigReads.trees(ctx([]))
      decided = [obs("a", read("a", "k")), obs("r", read("a", "k"))]

      assert %{items: [], problems: ["config value cannot be told: a k"]} =
               ConfigReads.judge(decided, @elixir, snap(%{}), trees)
    end

    test "cannot be told outside every window" do
      assert %{items: [], problems: ["config value cannot be told: fx k"]} =
               judge([obs(:outside, read("fx", "k"))], snap(%{}))
    end

    test "is unset for an application Mix loads before every compile" do
      decided =
        for app <- ~w(elixir mix ex_unit iex logger),
            owner <- [:outside, "dep"],
            do: obs(owner, read(app, "unset_key"))

      result = judge(decided, snap(%{}))
      assert result.problems == []
      assert length(result.items) == 5
      assert Enum.all?(result.items, &(&1.value == ConfigReads.unset()))
    end
  end

  test "toolchain reads: reviewed ones recorded or dropped, unknown ones recorded and flagged" do
    decided = [
      obs(
        "pkg",
        read("logger", "compile_time_purge_matching", kind: "toolchain", first: "Elixir.Logger")
      ),
      obs("pkg", read("elixir", "ansi_enabled", kind: "toolchain", first: "Elixir.IO")),
      obs("dep", read("mix", "unknown_key", kind: "toolchain", first: "Elixir.Mix.Project"))
    ]

    result = judge(decided, snap(%{}))

    assert keys(result) == [{"logger", ["compile_time_purge_matching"]}, {"mix", ["unknown_key"]}]
    assert result.problems == []
    assert result.dropped == 1
    assert [%{"owner" => "dep", "arg" => %{"key_name" => "unknown_key"}}] = result.unreviewed
  end

  test "IO.warn's :elixir ansi_enabled is never recorded, set or not" do
    decided = [obs("pkg", read("elixir", "ansi_enabled", kind: "toolchain", first: "Elixir.IO"))]
    entries = %{{"elixir", "ansi_enabled"} => enc({:ok, true})}

    assert %{items: [], problems: [], dropped: 1} = judge(decided, snap(entries))
  end

  test "a read reached through glue, or with no first frame, is the package's own" do
    decided = [
      obs("pkg", read("elixir", "ansi_enabled", kind: "glue", first: "Elixir.Enum")),
      obs("pkg", read("fx", "y", kind: "none"))
    ]

    assert keys(judge(decided, snap(%{}))) == [{"elixir", ["ansi_enabled"]}, {"fx", ["y"]}]
  end

  test "a toolchain read on a toolchain with no reviewed lists cannot be judged" do
    decided = [obs("pkg", read("logger", "level", kind: "toolchain", first: "Elixir.Logger"))]

    assert %{items: [], problems: ["no reviewed config reads for Elixir 1.99"]} =
             ConfigReads.judge(decided, "1.99.0", snap(%{}), @trees)

    assert ConfigReads.reviewed("1.99.0") == nil
    assert ConfigReads.reviewed(nil) == nil
    assert %{record: [_ | _], drop: [{"elixir", "ansi_enabled"}]} = ConfigReads.reviewed("1.20.4")
    assert %{record: [_ | _], drop: [{"elixir", "ansi_enabled"}]} = ConfigReads.reviewed("1.19.5")
  end

  test "get_all_env refuses from package code, is flagged from the toolchain's; get_env/1 is ignored" do
    all = fn kind ->
      %{
        read("phoenix", nil, kind: kind, mfa: "application:get_all_env/1")
        | "arg" => %{"app" => "phoenix", "app_name" => "phoenix", "all" => true}
      }
    end

    assert %{refusals: [{"pkg", {:refuse, reason}}], items: []} =
             judge([obs("pkg", all.("user"))], snap(%{}))

    assert reason ==
             "compile-time config read: application:get_all_env/1 (phoenix) has no key to match on" <>
               " in Pkg (lib/pkg.ex:3)"

    assert %{refusals: [], items: [], unreviewed: [_]} =
             judge([obs("pkg", all.("toolchain"))], snap(%{}))

    one = %{
      read(nil, "k", mfa: "application:get_env/1")
      | "arg" => %{"app" => nil, "key_name" => "k", "atoms" => false}
    }

    assert %{items: [], refusals: []} = judge([obs("pkg", one)], snap(%{}))
  end

  test "a non-atom application or key refuses" do
    assert %{refusals: [{"pkg", {:refuse, "compile-time config read: " <> _}}]} =
             judge([obs("pkg", read("fx", "k", atoms: false))], snap(%{}))
  end

  test "values that cannot be told cannot be judged" do
    decided = [obs("pkg", read("fx", "k"))]

    assert %{items: [], problems: ["no config snapshot"]} = judge(decided, nil)
    assert %{problems: ["no config snapshot"]} = judge(decided, :error)
    assert %{problems: ["config snapshot truncated"]} = judge(decided, snap(%{}, true))

    assert %{problems: ["config value too large: fx k"]} =
             judge(decided, snap(%{{"fx", "k"} => :oversize}))

    # Nothing recorded, nothing to value.
    assert %{items: [], problems: []} = judge([], nil)
  end

  test "more than 500 distinct reads cannot be judged" do
    decided = for i <- 1..501, do: obs("pkg", read("fx", "k#{i}"))

    assert %{items: [], problems: ["more than 500 config reads"]} = judge(decided, snap(%{}))
  end

  test "merge/2 keeps the .app's items first and never repeats a path" do
    app = [%{app: "fx", path: ["k"], value: "A"}, %{app: "fx", path: ["k", "sub"], value: "B"}]
    r5 = [%{app: "fx", path: ["k"], value: "C"}, %{app: "lv", path: ["x"], value: "D"}]

    assert ConfigReads.merge(app, r5) == app ++ [%{app: "lv", path: ["x"], value: "D"}]
    assert ConfigReads.merge([], r5) == r5
    assert ConfigReads.merge(nil, r5) == nil
  end
end
