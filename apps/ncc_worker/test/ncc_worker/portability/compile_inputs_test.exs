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

  defp endian_read(owner \\ "pkg"),
    do: {owner, {:observe, "endian_reads", %{"mfa" => "erlang:system_info/1"}}}

  describe "the byte order" do
    test "a read records one endian item with the builder's byte order" do
      decided = [endian_read(), endian_read("dep"), endian_read(:outside)]

      for endian <- ["little", "big"] do
        assert CompileInputs.build(decided, [], endian) == [
                 %{"kind" => "endian", "value" => endian}
               ]
      end
    end

    test "no read, no item, whatever the byte order" do
      assert CompileInputs.build([read("A", rec(:error))], [], "little") == [
               %{"kind" => "env", "name" => "A", "value" => rec(:error), "set_by" => "host"}
             ]

      assert CompileInputs.build([], []) == []
    end

    # Fail closed: an input the build cannot state is one no client matches.
    test "a read without a known byte order records config_unrecorded, never nothing" do
      for endian <- [nil, "", "native", "LITTLE", :little] do
        assert CompileInputs.build([endian_read()], [], endian) == [
                 %{"kind" => "config_unrecorded"}
               ],
               inspect(endian)
      end
    end

    test "the item validates as the shared shape and needs a check" do
      items = CompileInputs.build([endian_read()], [], "little")
      assert {:ok, ^items} = Compatibility.CompileInputs.validate(items)
      assert Compatibility.CompileInputs.needs_check?(items)
    end
  end

  defp os_read(scope, owner \\ "pkg"),
    do: {owner, {:observe, "os_type_reads", %{"mfa" => "os:type/0", "scope" => scope}}}

  describe "the OS type" do
    @linux ["unix", "linux"]

    test "a read records one os_type item with the builder's whole OS type" do
      decided = [os_read("full"), os_read("full", "dep"), os_read("family", :outside)]

      for [family, name] = os_type <- [@linux, ["unix", "darwin"], ["win32", "nt"]] do
        assert CompileInputs.build(decided, [], nil, os_type) == [
                 %{"kind" => "os_type", "family" => family, "name" => name}
               ]
      end
    end

    test "only reads that reach the family alone record the family" do
      for scopes <- [["family"], ["family", "covered"], ["covered", "family", "family"]] do
        decided = Enum.map(scopes, &os_read/1)

        assert CompileInputs.build(decided, [], nil, @linux) == [
                 %{"kind" => "os_type", "family" => "unix"}
               ],
               inspect(scopes)
      end
    end

    # Fail closed: one read that may reach the name, or a scope this build
    # does not know, keeps the name.
    test "any other read keeps the name" do
      for scopes <- [["covered"], ["family", "full"], ["family", nil], ["family", "Family"]] do
        decided = Enum.map(scopes, &os_read/1)

        assert CompileInputs.build(decided, [], nil, @linux) == [
                 %{"kind" => "os_type", "family" => "unix", "name" => "linux"}
               ],
               inspect(scopes)
      end
    end

    test "no read, no item, whatever the OS type" do
      assert CompileInputs.build([], [], nil, @linux) == []
    end

    test "a read without a known OS type records config_unrecorded, never nothing" do
      for os_type <- [
            nil,
            [],
            ["unix"],
            ["vxworks", "x"],
            ["unix", "Linux"],
            ["unix", ""],
            "unix"
          ] do
        assert CompileInputs.build([os_read("family")], [], nil, os_type) == [
                 %{"kind" => "config_unrecorded"}
               ],
               inspect(os_type)
      end
    end

    test "next to an endian read, both items, each validating as the shared shape" do
      decided = [os_read("full"), endian_read()]
      items = CompileInputs.build(decided, [], "little", @linux)

      assert items == [
               %{"kind" => "endian", "value" => "little"},
               %{"kind" => "os_type", "family" => "unix", "name" => "linux"}
             ]

      assert {:ok, ^items} = Compatibility.CompileInputs.validate(items)
      assert Compatibility.CompileInputs.needs_check?(items)
    end
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

  # An unset variable reveals nothing: yamerl's rebar.config.script always
  # reads GITHUB_TOKEN, and a client without it must still match.
  test "a private-looking name that was unset records the unset value; a set one does not" do
    assert CompileInputs.build([read("GITHUB_TOKEN", rec(:error), owner: :outside)], []) == [
             %{
               "kind" => "env",
               "name" => "GITHUB_TOKEN",
               "value" => rec(:error),
               "set_by" => "host"
             }
           ]

    assert [%{"value" => "unrecordable"}] =
             CompileInputs.build([read("GITHUB_TOKEN", rec({:ok, "ghp_x"}))], [])

    for name <- ~w(NCC_INPUT DB_PASS AWS_ACCESS_KEY HTTP_PROXY AUTH) do
      assert [%{"value" => value}] = CompileInputs.build([read(name, rec(:error))], [])
      assert value == rec(:error), name
    end
  end

  test "names that hold credentials are unrecordable, whatever their case" do
    names =
      ~w(DB_PASS SMTP_PWD AWS_ACCESS_KEY AUTH BASIC_AUTH HTTP_PROXY http_proxy HTTPS_PROXY no_proxy) ++
        ~w(ALL_PROXY Fx_Key AWS_ACCESS_KEY_ID SIGNING_KEY_FILE)

    for name <- names do
      assert [%{"value" => "unrecordable"}] =
               CompileInputs.build([read(name, rec({:ok, "v"}))], []),
             name
    end
  end

  test "a name only containing those words keeps its value" do
    for name <- ~w(KEYBOARD PASSAGE AUTHOR PROXYING MONKEY_KEYS LANG) do
      assert [%{"value" => value}] = CompileInputs.build([read(name, rec({:ok, "v"}))], [])
      assert value == rec({:ok, "v"}), name
    end
  end

  test "a value that is a URL with userinfo is unrecordable, whatever the name" do
    for url <- [
          "postgres://user:pass@db.example/app",
          "https://token@example.com/x",
          "  redis://:pw@cache:6379",
          "git+ssh://u:p@example.com/r.git"
        ] do
      assert [%{"value" => "unrecordable"}] =
               CompileInputs.build([read("DATABASE_URL", rec({:ok, url}))], []),
             url
    end

    for url <- ["https://example.com/a@b", "https://example.com", "mailto:a@b.example"] do
      assert [%{"value" => value}] = CompileInputs.build([read("SITE", rec({:ok, url}))], [])
      assert value == rec({:ok, url}), url
    end
  end

  test "a config_order input with a name it cannot carry becomes config_unrecorded" do
    bad = for app <- ["a=b", "", String.duplicate("x", 257)], do: Map.put(order(1), "app", app)
    items = CompileInputs.build([], [order(2) | bad] ++ [%{"kind" => "config_unrecorded"}])
    assert Enum.sort_by(items, & &1["kind"]) == [order(2), %{"kind" => "config_unrecorded"}]
    assert Compatibility.CompileInputs.validate(items) == {:ok, items}
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

  # Judge revision 19: a write with no file (an alias fun's tail call) is
  # judged against every earlier read in its VM, not none.
  test "a write with no file is judged by its VM; a later different value is the host's" do
    nofile = write("X", rec({:ok, "1"}), ts: 4, file: nil)

    assert [%{"set_by" => "build", "inputs" => "recorded"}] =
             CompileInputs.build([nofile, read("X", rec({:ok, "1"}), ts: 9)], [])

    unrecorded = read("SOME_TOKEN", rec({:ok, "s"}), ts: 2, file: "lib/other.ex")

    assert %{"set_by" => "build", "inputs" => "unknown"} =
             [unrecorded, nofile, read("X", rec({:ok, "1"}), ts: 9)]
             |> CompileInputs.build([])
             |> Enum.find(&(&1["name"] == "X"))

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
    assert Compatibility.CompileInputs.validate(items) == {:ok, items}

    more = CompileInputs.build([read("V129", rec(:error)) | env], [order(97) | orders] ++ extras)
    assert Enum.sort(more) == [%{"kind" => "config_unrecorded"}, %{"kind" => "env_all"}]
  end

  test "other kinds over their cap collapse to one not-recorded item" do
    others = for i <- 1..33, do: %{"kind" => "config_other_#{i}"}
    assert CompileInputs.build([], others) == [%{"kind" => "config_unrecorded"}]
  end

  describe "a firmware build's inputs (target mode)" do
    @roots [{"NERVES_TOOLCHAIN", "/n/tc-15"}, {"NERVES_SYSTEM", "/n/sys-2"}]

    defp native(owner, ts, vm \\ "main"),
      do: {owner, {:observe, "native_build", %{"ts" => ts, "vm" => vm}}}

    defp target_read(owner \\ "pkg"),
      do: {owner, {:observe, "target_reads", %{"mfa" => "Mix.target/0"}}}

    test "a host value holding a Nerves path is cut at it, the rest kept as read" do
      decided = [
        read("CROSSCOMPILE", rec({:ok, "/n/tc-15/bin/aarch64-nerves-linux-gnu"})),
        read("CFLAGS", rec({:ok, "-I/n/sys-2/usr/include -O2"})),
        read("TARGET_ARCH", rec({:ok, "aarch64"})),
        read("UNSET", rec(:error))
      ]

      assert CompileInputs.build(decided, [], nil, nil, roots: @roots) == [
               %{
                 "kind" => "env",
                 "name" => "CFLAGS",
                 "set_by" => "nerves",
                 "value" => ["-I", %{"root" => "NERVES_SYSTEM"}, "/usr/include -O2"]
               },
               %{
                 "kind" => "env",
                 "name" => "CROSSCOMPILE",
                 "set_by" => "nerves",
                 "value" => [%{"root" => "NERVES_TOOLCHAIN"}, "/bin/aarch64-nerves-linux-gnu"]
               },
               %{
                 "kind" => "env",
                 "name" => "TARGET_ARCH",
                 "value" => rec({:ok, "aarch64"}),
                 "set_by" => "host"
               },
               %{"kind" => "env", "name" => "UNSET", "value" => rec(:error), "set_by" => "host"}
             ]
    end

    test "without roots, or for a value that cannot be one canonical split, the value stays" do
      cross = read("CROSSCOMPILE", rec({:ok, "/n/tc-15/bin/gcc"}))
      host = %{"kind" => "env", "name" => "CROSSCOMPILE", "set_by" => "host"}

      assert [%{"value" => value} = item] = CompileInputs.build([cross], [])
      assert item == Map.put(host, "value", value)

      bad = read("CROSSCOMPILE", rec({:ok, "/n/tc-15/" <> <<0xFF>>}))
      assert [%{"set_by" => "host"}] = CompileInputs.build([bad], [], nil, nil, roots: @roots)

      secret = read("NERVES_API_TOKEN", rec({:ok, "/n/tc-15/x"}))

      assert [%{"set_by" => "host", "value" => "unrecordable"}] =
               CompileInputs.build([secret], [], nil, nil, roots: @roots)
    end

    test "a write with no source file is the build's when every earlier read is recorded" do
      decided = [
        read("CROSSCOMPILE", rec({:ok, "/n/tc-15/bin/gcc"}), ts: 10, file: "/p/deps/pkg/mix.exs"),
        write("PKG_DEV", rec({:ok, "normal"}), ts: 20, file: nil),
        read("PKG_DEV", rec({:ok, "normal"}), ts: 30)
      ]

      assert %{"set_by" => "build", "inputs" => "recorded"} =
               decided
               |> CompileInputs.build([], nil, nil, roots: @roots)
               |> Enum.find(&(&1["name"] == "PKG_DEV"))
    end

    test "a write with no source file is unknown after any unrecorded read in its VM" do
      decided = [
        read("NERVES_API_TOKEN", rec({:ok, "x"}), ts: 5, owner: "dep", file: "lib/dep.ex"),
        write("PKG_DEV", rec({:ok, "normal"}), ts: 20, file: nil),
        read("PKG_DEV", rec({:ok, "normal"}), ts: 30)
      ]

      assert %{"set_by" => "build", "inputs" => "unknown"} =
               decided |> CompileInputs.build([]) |> Enum.find(&(&1["name"] == "PKG_DEV"))

      # A read in another VM, or after the write, does not count.
      later = [
        read("NERVES_API_TOKEN", rec({:ok, "x"}), ts: 5, vm: "child:dep"),
        read("NERVES_API_TOKEN", rec({:ok, "x"}), ts: 25),
        write("PKG_DEV", rec({:ok, "normal"}), ts: 20, file: nil),
        read("PKG_DEV", rec({:ok, "normal"}), ts: 30)
      ]

      assert %{"inputs" => "recorded"} =
               later |> CompileInputs.build([]) |> Enum.find(&(&1["name"] == "PKG_DEV"))
    end

    test "native build activity before a write in its window makes its inputs unknown" do
      write = write("PKG_DEV", rec({:ok, "normal"}), ts: 20)
      lib_read = read("PKG_DEV", rec({:ok, "normal"}), ts: 30)
      dev = &Enum.find(CompileInputs.build(&1, []), fn i -> i["name"] == "PKG_DEV" end)

      assert %{"inputs" => "unknown"} = dev.([native("pkg", 10), write, lib_read])
      assert %{"inputs" => "recorded"} = dev.([native("pkg", 25), write, lib_read])
      assert %{"inputs" => "recorded"} = dev.([native("dep", 10), write, lib_read])
      assert %{"inputs" => "recorded"} = dev.([native("pkg", 10, "child:x"), write, lib_read])
    end

    test "a target read records the target the build was made for" do
      assert CompileInputs.build([target_read(), target_read(:outside)], [], nil, nil, target: "rpi4") ==
               [%{"kind" => "mix_target", "value" => "rpi4"}]

      for target <- [nil, "", "a=b", :rpi4] do
        assert CompileInputs.build([target_read()], [], nil, nil, target: target) ==
                 [%{"kind" => "config_unrecorded"}],
               inspect(target)
      end

      assert CompileInputs.build([], [], nil, nil, target: "rpi4") == []
    end

    test "everything it records validates as the shared shape and needs a check" do
      decided = [
        target_read(),
        read("CROSSCOMPILE", rec({:ok, "/n/tc-15/bin/gcc"}), ts: 10),
        write("PKG_DEV", rec({:ok, "normal"}), ts: 20, file: nil),
        read("PKG_DEV", rec({:ok, "normal"}), ts: 30)
      ]

      items = CompileInputs.build(decided, [], nil, nil, roots: @roots, target: "rpi4")
      assert length(items) == 3
      assert Compatibility.CompileInputs.validate(items) == {:ok, items}
      assert Compatibility.CompileInputs.needs_check?(items)
    end
  end
end
