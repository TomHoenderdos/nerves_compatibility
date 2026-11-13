defmodule NccWorker.Portability.CompileInputsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.CompileInputs

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp read(name, returned, opts \\ []) do
    {Keyword.get(opts, :owner, "pkg"),
     {:observe, "env_reads",
      %{
        "name" => name,
        "returned" => returned,
        "ts" => Keyword.get(opts, :ts, 50),
        "vm" => Keyword.get(opts, :vm, "main"),
        "file" => Keyword.get(opts, :file, "lib/pkg.ex"),
        "all" => false,
        "slice_allowed" => Keyword.get(opts, :slice_allowed, false)
      }}}
  end

  defp write(name, value, opts) do
    {Keyword.get(opts, :owner, "pkg"),
     {:observe, "env_writes",
      %{
        "name" => name,
        "value" => value,
        "ts" => Keyword.fetch!(opts, :ts),
        "vm" => Keyword.get(opts, :vm, "main"),
        "file" => Keyword.get(opts, :file, "/p/deps/pkg/mix.exs")
      }}}
  end

  test "a host read records its value, deduplicated and sorted" do
    decided = [read("B", rec(:error)), read("A", rec({:ok, "1"})), read("B", rec(:error))]

    assert CompileInputs.build(decided, []) == [
             %{"kind" => "env", "name" => "A", "value" => rec({:ok, "1"}), "set_by" => "host"},
             %{"kind" => "env", "name" => "B", "value" => rec(:error), "set_by" => "host"}
           ]
  end

  test "a missing, unrecordable or private value is unrecordable" do
    decided = [
      read("A", nil),
      read("B", "unrecordable"),
      read("NCC_INPUT", rec({:ok, "{}"})),
      read("FX_API_TOKEN", rec({:ok, "s3cret"}))
    ]

    values = CompileInputs.build(decided, []) |> Enum.map(& &1["value"]) |> Enum.uniq()
    assert values == ["unrecordable"]
  end

  # The circuits shape: mix.exs reads CROSS, then sets BACKEND; lib reads BACKEND.
  test "a read of a value the build wrote is set by the build, its inputs recorded" do
    mix = "/p/deps/pkg/mix.exs"

    decided = [
      read("CROSS", rec(:error), ts: 3, file: mix, owner: :outside),
      write("BACKEND", rec({:ok, "host"}), ts: 4, file: mix),
      read("BACKEND", rec({:ok, "host"}), ts: 35)
    ]

    assert CompileInputs.build(decided, []) == [
             %{
               "kind" => "env",
               "name" => "BACKEND",
               "value" => rec({:ok, "host"}),
               "set_by" => "build",
               "inputs" => "recorded"
             },
             %{"kind" => "env", "name" => "CROSS", "value" => rec(:error), "set_by" => "host"}
           ]
  end

  test "a writer whose earlier read was not recorded has unknown inputs" do
    mix = "/p/deps/pkg/mix.exs"

    decided = [
      read("CROSS", "unrecordable", ts: 3, file: mix),
      write("BACKEND", rec({:ok, "host"}), ts: 4, file: mix),
      read("BACKEND", rec({:ok, "host"}), ts: 35)
    ]

    assert %{"set_by" => "build", "inputs" => "unknown"} =
             Enum.find(CompileInputs.build(decided, []), &(&1["name"] == "BACKEND"))
  end

  test "a write with no file has unknown inputs; a later different value is the host's" do
    nofile = write("X", rec({:ok, "1"}), ts: 4, file: nil)

    assert [%{"set_by" => "build", "inputs" => "unknown"}] =
             CompileInputs.build([nofile, read("X", rec({:ok, "1"}), ts: 9)], [])

    assert [%{"set_by" => "host"}] =
             CompileInputs.build([nofile, read("X", rec({:ok, "2"}), ts: 9)], [])
  end

  test "an unrecordable write never matches an unrecordable read" do
    decided = [write("X", "unrecordable", ts: 4), read("X", "unrecordable", ts: 9)]
    assert [%{"set_by" => "host", "value" => "unrecordable"}] = CompileInputs.build(decided, [])

    child = read("X", "unrecordable", ts: 1, vm: "child:dep")

    assert [%{"set_by" => "host"}] =
             CompileInputs.build([write("X", "unrecordable", ts: 4), child], [])
  end

  test "a child VM's read matches a main-VM write by value" do
    decided = [
      write("X", rec({:ok, "1"}), ts: 900),
      read("X", rec({:ok, "1"}), ts: 1, vm: "child:dep")
    ]

    assert [%{"set_by" => "build"}] = CompileInputs.build(decided, [])
  end

  test "a slice-allowed mix.exs read counts only when its file writes the environment" do
    mix = "/p/deps/pkg/mix.exs"
    allowed = read("DOCS", rec(:error), ts: 2, file: mix, slice_allowed: true)
    assert CompileInputs.build([allowed], []) == []

    assert [%{"name" => "DOCS"}, %{"name" => "W"}] =
             CompileInputs.build(
               [
                 allowed,
                 write("W", rec({:ok, "1"}), ts: 3, file: mix),
                 read("W", rec({:ok, "1"}), ts: 40)
               ],
               []
             )
  end

  test "the whole environment, too many variables, and config inputs" do
    all = {"pkg", {:observe, "env_reads", %{"all" => true, "ts" => 1, "vm" => "main"}}}
    assert CompileInputs.build([all], []) == [%{"kind" => "env_all"}]

    many = for i <- 1..201, do: read("V#{i}", rec(:error))
    assert CompileInputs.build(many, []) == [%{"kind" => "env_all"}]

    assert CompileInputs.build([], [
             %{"kind" => "config_unrecorded"},
             %{"kind" => "config_unrecorded"}
           ]) ==
             [%{"kind" => "config_unrecorded"}]
  end

  test "what it builds always passes the shared shape check" do
    decided = [
      read("A", rec(:error)),
      read("B", nil),
      write("C", rec({:ok, "1"}), ts: 1),
      read("C", rec({:ok, "1"}), ts: 2)
    ]

    items = CompileInputs.build(decided, [%{"kind" => "config_unrecorded"}])
    assert Compatibility.CompileInputs.validate(items) == {:ok, items}

    # Names the shared shape rejects: the package passed something no
    # variable can be named, so the read is recorded as reading anything.
    for bad <- ["", "A=B", "A" <> <<0>>, String.duplicate("x", 257), <<255>>, nil, 7] do
      items = CompileInputs.build([read("A", rec(:error)), read(bad, rec(:error))], [])
      assert Compatibility.CompileInputs.validate(items) == {:ok, items}, inspect(bad)
      assert %{"kind" => "env_all"} in items

      assert %{"kind" => "env", "name" => "A", "value" => rec(:error), "set_by" => "host"} in items
    end
  end

  test "a bad name in mix.exs follows the slice, and leaves its file's writes unknown" do
    mix = "/p/deps/pkg/mix.exs"

    assert CompileInputs.build([read("", rec(:error), ts: 2, file: mix, slice_allowed: true)], []) ==
             []

    decided = [
      read("", rec(:error), ts: 2, file: mix),
      write("W", rec({:ok, "1"}), ts: 3, file: mix),
      read("W", rec({:ok, "1"}), ts: 40)
    ]

    assert [%{"name" => "W", "inputs" => "unknown"}, %{"kind" => "env_all"}] =
             CompileInputs.build(decided, [])
  end

  test "a read before the write, or after a later write of another value, is the host's" do
    assert [%{"set_by" => "host"}] =
             CompileInputs.build(
               [read("X", rec({:ok, "1"}), ts: 3), write("X", rec({:ok, "1"}), ts: 4)],
               []
             )

    decided = [
      write("X", rec({:ok, "1"}), ts: 2),
      write("X", rec({:ok, "2"}), ts: 3),
      read("X", rec({:ok, "1"}), ts: 9)
    ]

    assert [%{"set_by" => "host"}] = CompileInputs.build(decided, [])
  end

  test "a write outside the package's closure is not the build's" do
    decided = [
      write("X", rec({:ok, "1"}), ts: 4, owner: :outside),
      read("X", rec({:ok, "1"}), ts: 9)
    ]

    assert [%{"set_by" => "host"}] = CompileInputs.build(decided, [])

    child = read("X", rec({:ok, "1"}), ts: 1, vm: "child:dep")

    assert [%{"set_by" => "host"}] =
             CompileInputs.build([write("X", rec({:ok, "1"}), ts: 4, owner: :outside), child], [])
  end

  defp order(i),
    do: %{
      "kind" => "config_order",
      "app" => "a",
      "path" => ["k#{i}"],
      "reader" => "r",
      "default" => rec(:error),
      "seen" => rec(:error)
    }

  test "each kind has its own cap, and over it records that the kind was not recorded" do
    env = fn n -> for i <- 1..n, do: read("V#{i}", rec(:error)) end
    assert length(CompileInputs.build(env.(128), [])) == 128
    assert CompileInputs.build(env.(129), []) == [%{"kind" => "env_all"}]

    orders = fn n -> for i <- 1..n, do: order(i) end
    assert CompileInputs.build([], orders.(96)) == orders.(96)
    assert CompileInputs.build([], orders.(97)) == [%{"kind" => "config_unrecorded"}]
  end

  # Every kind at its cap at once still fits the shared item cap, and one
  # more of any kind records "not recorded" for that kind, never dropping
  # the list.
  test "every kind at its cap together stays within the shared cap" do
    env = for i <- 1..128, do: read("V#{i}", rec(:error))
    all = {"pkg", {:observe, "env_reads", %{"all" => true, "ts" => 1, "vm" => "main"}}}
    orders = for i <- 1..96, do: order(i)
    extras = [%{"kind" => "config_unrecorded"}, %{"kind" => "config_unrecorded"}]

    items = CompileInputs.build([all | env], orders ++ extras)
    assert length(items) == 128 + 96 + 2
    assert length(items) <= 256
    assert %{"kind" => "env_all"} in items
    assert %{"kind" => "config_unrecorded"} in items
    assert valid_but_order?(items)

    more = CompileInputs.build([read("V129", rec(:error)) | env], [order(97) | orders] ++ extras)
    assert Enum.sort(more) == [%{"kind" => "config_unrecorded"}, %{"kind" => "env_all"}]
  end

  test "other kinds over their cap collapse to one not-recorded item" do
    others = for i <- 1..33, do: %{"kind" => "config_other_#{i}"}
    assert CompileInputs.build([], others) == [%{"kind" => "config_unrecorded"}]
  end

  # config_order items are checked by the shared shape once it knows them;
  # everything else must already pass it.
  defp valid_but_order?(items) do
    rest = Enum.reject(items, &(&1["kind"] == "config_order"))
    Compatibility.CompileInputs.validate(rest) == {:ok, rest}
  end
end
