defmodule Compatibility.CompileInputsTest do
  use ExUnit.Case, async: true

  alias Compatibility.CompileInputs

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  @host %{
    "kind" => "env",
    "name" => "GITHUB_ACTIONS",
    "value" => "g3cFZXJyb3I",
    "set_by" => "host"
  }

  test "every item kind is accepted in its exact shape" do
    items = [
      @host,
      %{@host | "value" => "unrecordable"},
      Map.merge(@host, %{"set_by" => "build", "inputs" => "recorded"}),
      Map.merge(@host, %{"set_by" => "build", "inputs" => "unknown"}),
      %{"kind" => "env_all"},
      %{"kind" => "config_unrecorded"}
    ]

    assert CompileInputs.validate(items) == {:ok, items}
    assert CompileInputs.validate(nil) == {:ok, nil}
    assert CompileInputs.validate([]) == {:ok, []}
  end

  test "anything else is malformed, all or nothing" do
    for bad <- [
          [Map.put(@host, "extra", 1)],
          [%{@host | "set_by" => "elsewhere"}],
          [Map.merge(@host, %{"set_by" => "build", "inputs" => "maybe"})],
          [%{@host | "name" => "A=B"}],
          [%{@host | "name" => ""}],
          [%{@host | "value" => rec(fn -> :ok end)}],
          [%{"kind" => "env_all", "name" => "X"}],
          [%{"kind" => "teleport"}],
          [@host, :not_a_map],
          List.duplicate(%{"kind" => "env_all"}, 257),
          %{"kind" => "env_all"}
        ] do
      assert CompileInputs.validate(bad) == :error, inspect(bad, limit: 3)
    end
  end

  @order %{
    "kind" => "config_order",
    "app" => "phoenix_view",
    "path" => ["template_engines"],
    "reader" => "phoenix_live_dashboard",
    "default" => "g3cFZXJyb3I",
    "seen" => "unrecordable"
  }

  test "a config_order item is accepted in its exact shape and needs a check" do
    assert CompileInputs.validate([@order]) == {:ok, [@order]}
    assert CompileInputs.needs_check?([@order])
  end

  test "a malformed config_order item is malformed" do
    for bad <- [
          Map.put(@order, "extra", 1),
          Map.delete(@order, "seen"),
          %{@order | "path" => []},
          %{@order | "path" => ["a", "b"]},
          %{@order | "path" => "template_engines"},
          %{@order | "app" => ""},
          %{@order | "reader" => 1},
          %{@order | "default" => rec(fn -> :ok end)},
          %{@order | "seen" => "default"}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end
  end

  test "only build-set items with recorded inputs need no check" do
    refute CompileInputs.needs_check?(nil)
    refute CompileInputs.needs_check?([])

    refute CompileInputs.needs_check?([
             Map.merge(@host, %{"set_by" => "build", "inputs" => "recorded"})
           ])

    assert CompileInputs.needs_check?([@host])

    assert CompileInputs.needs_check?([
             Map.merge(@host, %{"set_by" => "build", "inputs" => "unknown"})
           ])

    assert CompileInputs.needs_check?([%{"kind" => "env_all"}])
    assert CompileInputs.needs_check?([%{"kind" => "config_unrecorded"}])
  end

  @endian %{"kind" => "endian", "value" => "little"}

  test "an endian item is accepted in its exact shape and needs a check" do
    big = %{@endian | "value" => "big"}
    assert CompileInputs.validate([@endian, big]) == {:ok, [@endian, big]}
    assert CompileInputs.needs_check?([@endian])
  end

  test "a malformed endian item is malformed" do
    for bad <- [
          Map.put(@endian, "extra", 1),
          Map.delete(@endian, "value"),
          %{@endian | "value" => "native"},
          %{@endian | "value" => "Little"},
          %{@endian | "value" => :little},
          %{@endian | "value" => nil}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end
  end

  @os_full %{"kind" => "os_type", "family" => "unix", "name" => "linux"}
  @os_family %{"kind" => "os_type", "family" => "unix"}

  test "an os_type item is accepted with its family, with or without the name" do
    win = %{@os_full | "family" => "win32", "name" => "nt"}
    items = [@os_full, @os_family, win, %{@os_full | "name" => "darwin"}]
    assert CompileInputs.validate(items) == {:ok, items}
    assert CompileInputs.needs_check?([@os_full])
    assert CompileInputs.needs_check?([@os_family])
  end

  test "a malformed os_type item is malformed" do
    for bad <- [
          Map.put(@os_full, "extra", 1),
          Map.delete(@os_family, "family"),
          %{@os_full | "family" => "Unix"},
          %{@os_full | "family" => "vxworks"},
          %{@os_full | "family" => :unix},
          %{@os_full | "name" => "Linux"},
          %{@os_full | "name" => ""},
          %{@os_full | "name" => nil},
          %{@os_full | "name" => :linux},
          %{@os_full | "name" => "linux\n"},
          %{@os_full | "name" => "1linux"},
          %{@os_full | "name" => String.duplicate("a", 65)},
          %{"kind" => "os_type", "value" => "unix/linux"}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end
  end

  @config_all %{
    "kind" => "config_all",
    "app" => "tz",
    "entries" => [
      %{"key" => "data_dir", "value" => "g2gCdwJva20AAAAEL3RtcA"},
      %{"key" => "http_client", "value" => "unrecordable"}
    ]
  }

  test "a config_all item is accepted in its exact shape, empty too, and needs a check" do
    empty = %{@config_all | "entries" => []}
    assert CompileInputs.validate([@config_all, empty]) == {:ok, [@config_all, empty]}
    assert CompileInputs.needs_check?([empty])
  end

  test "a malformed config_all item is malformed" do
    [a, b] = @config_all["entries"]

    for bad <- [
          Map.put(@config_all, "extra", 1),
          Map.delete(@config_all, "entries"),
          %{@config_all | "app" => ""},
          %{@config_all | "app" => "a=b"},
          %{@config_all | "app" => :tz},
          %{@config_all | "entries" => %{"data_dir" => a["value"]}},
          %{@config_all | "entries" => [b, a]},
          %{@config_all | "entries" => [a, a]},
          %{@config_all | "entries" => [Map.put(a, "extra", 1)]},
          %{@config_all | "entries" => [%{a | "key" => ""}]},
          %{@config_all | "entries" => [%{a | "value" => rec(fn -> :ok end)}]},
          %{@config_all | "entries" => [%{a | "value" => nil}]},
          %{@config_all | "entries" => for(i <- 1..129, do: %{a | "key" => "k#{1000 + i}"})}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad, limit: 5)
    end
  end

  @define %{"kind" => "platform_define", "regex" => "R14", "matched" => false}

  test "a platform_define item is accepted in its exact shape and needs a check" do
    matched = %{@define | "matched" => true, "regex" => "^(linux|darwin)"}
    assert CompileInputs.validate([@define, matched]) == {:ok, [@define, matched]}
    assert CompileInputs.needs_check?([@define])
  end

  test "a malformed platform_define item is malformed" do
    for bad <- [
          Map.put(@define, "extra", 1),
          Map.delete(@define, "matched"),
          Map.delete(@define, "regex"),
          %{@define | "matched" => "false"},
          %{@define | "matched" => nil},
          %{@define | "regex" => ""},
          %{@define | "regex" => 14},
          %{@define | "regex" => "a" <> <<0>>},
          %{@define | "regex" => <<0xFF>>},
          %{@define | "regex" => String.duplicate("a", 1025)}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end

    assert CompileInputs.validate([%{@define | "regex" => String.duplicate("a", 1024)}]) ==
             {:ok, [%{@define | "regex" => String.duplicate("a", 1024)}]}
  end

  @nerves %{
    "kind" => "env",
    "name" => "CROSSCOMPILE",
    "set_by" => "nerves",
    "value" => [%{"root" => "NERVES_TOOLCHAIN"}, "/bin/aarch64-nerves-linux-gnu"]
  }

  test "a nerves env item is accepted in its exact shape and needs a check" do
    system = %{@nerves | "name" => "CFLAGS", "value" => ["-I", %{"root" => "NERVES_SYSTEM"}]}

    both = %{
      @nerves
      | "value" => [%{"root" => "NERVES_SYSTEM"}, ":", %{"root" => "NERVES_TOOLCHAIN"}]
    }

    assert CompileInputs.validate([@nerves, system, both]) == {:ok, [@nerves, system, both]}
    assert CompileInputs.needs_check?([@nerves])
  end

  test "a nerves env item that is not one canonical split is malformed" do
    for bad <- [
          Map.put(@nerves, "extra", 1),
          Map.delete(@nerves, "value"),
          %{@nerves | "value" => []},
          %{@nerves | "value" => ["/bin/gcc"]},
          %{@nerves | "value" => "/opt/toolchain/bin/gcc"},
          %{@nerves | "value" => [%{"root" => "HOME"}, "/bin"]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN", "x" => 1}]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, ""]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, "/bin", "/gcc"]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, <<0xFF>>]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, "a" <> <<0>>]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, 7]},
          %{@nerves | "value" => [%{"root" => "NERVES_TOOLCHAIN"}, String.duplicate("a", 4097)]},
          %{@nerves | "name" => "A=B"}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end
  end

  @target %{"kind" => "mix_target", "value" => "rpi4"}

  test "a mix_target item is accepted in its exact shape and needs a check" do
    assert CompileInputs.validate([@target]) == {:ok, [@target]}
    assert CompileInputs.needs_check?([@target])
  end

  test "a malformed mix_target item is malformed" do
    for bad <- [
          Map.put(@target, "extra", 1),
          Map.delete(@target, "value"),
          %{@target | "value" => ""},
          %{@target | "value" => :rpi4},
          %{@target | "value" => "a=b"},
          %{@target | "value" => String.duplicate("a", 257)}
        ] do
      assert CompileInputs.validate([bad]) == :error, inspect(bad)
    end
  end

  test "split/2 cuts a value at every root, leftmost and longest first" do
    roots = [
      {"NERVES_TOOLCHAIN", "/n/toolchain-1"},
      {"NERVES_SYSTEM", "/n/system"}
    ]

    assert CompileInputs.split("/n/toolchain-1/bin/aarch64-nerves-linux-gnu", roots) ==
             [%{"root" => "NERVES_TOOLCHAIN"}, "/bin/aarch64-nerves-linux-gnu"]

    assert CompileInputs.split("-I/n/system/usr -L/n/system/lib", roots) ==
             ["-I", %{"root" => "NERVES_SYSTEM"}, "/usr -L", %{"root" => "NERVES_SYSTEM"}, "/lib"]

    assert CompileInputs.split("/n/system/n/toolchain-1", roots) ==
             [%{"root" => "NERVES_SYSTEM"}, %{"root" => "NERVES_TOOLCHAIN"}]

    assert CompileInputs.split("/usr/bin", roots) == ["/usr/bin"]
    assert CompileInputs.split("", roots) == []

    # The longer of two roots that start at the same place wins.
    nested = [{"NERVES_SYSTEM", "/n"}, {"NERVES_TOOLCHAIN", "/n/t"}]
    assert CompileInputs.split("/n/t/x", nested) == [%{"root" => "NERVES_TOOLCHAIN"}, "/x"]

    # An empty root cuts nothing.
    assert CompileInputs.split("/usr/bin", [{"NERVES_SYSTEM", ""}]) == ["/usr/bin"]
  end
end
