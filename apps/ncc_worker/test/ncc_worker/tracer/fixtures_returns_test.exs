defmodule NccWorker.Tracer.FixturesReturnsTest do
  # The tracer's return capture on real compiles: what each compile-time env
  # and config read returned, attached to its event. Starts real `elixir`
  # VMs: one such module at a time (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2]

  @moduletag timeout: 600_000

  @deps %{
    "fx_ret_env" =>
      lib("fx_ret_env", """
      defmodule FxRetEnv do
        @set System.get_env("FX_RET_SET")
        @unset System.get_env("FX_RET_UNSET_VAR")
        @two :os.getenv(~c"FX_RET_TWO", ~c"fallback")
        def v, do: {@set, @unset, @two}
      end
      """),
    # Elixir's Application.get_env/2 is get_env(app, key, nil), which reaches
    # application:get_env/3; Application.fetch_env/2 makes the get_env/2 read.
    "fx_ret_cfg" =>
      lib("fx_ret_cfg", """
      defmodule FxRetCfg do
        @k Application.fetch_env(:fx_ret_cfg, :k)
        @d Application.get_env(:fx_ret_cfg, :missing, :dflt)
        def v, do: {@k, @d}
      end
      """),
    "fx_ret_huge" =>
      lib("fx_ret_huge", """
      defmodule FxRetHuge do
        @n byte_size(System.get_env("FX_RET_HUGE") || "")
        def n, do: @n
      end
      """),
    "fx_ret_many" =>
      lib("fx_ret_many", """
      defmodule FxRetMany do
        @n Enum.count(1..2000, fn i -> Application.get_env(:fx_ret_many, :"k\#{rem(i, 7)}") end)
        def n, do: @n
      end
      """)
  }

  # 2000 reads of one 60 KB value, then 300 reads of 300 distinct ones:
  # 18 MB of distinct values against the 8 MiB a trace file records.
  @big_size 60_000
  @big %{
    "fx_ret_big" =>
      lib("fx_ret_big", """
      defmodule FxRetBig do
        @same Enum.count(1..2000, fn _ -> Application.fetch_env(:fx_ret_big, :same) end)
        @distinct Enum.count(1..300, fn i -> Application.fetch_env(:fx_ret_big, :"v\#{i}") end)
        def n, do: {@same, @distinct}
      end
      """)
  }
  @big_config """
  config :fx_ret_big, same: String.duplicate("s", #{@big_size})

  for i <- 1..300 do
    config :fx_ret_big, [{:"v\#{i}", String.pad_trailing("v\#{i}-", #{@big_size}, "d")}]
  end
  """

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-returns-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)
    TracerFixtures.put_config(proj, "config :fx_ret_cfg, k: 42\n")

    traced =
      TracerFixtures.trace(proj, Map.keys(@deps),
        extra_env: [
          {"FX_RET_SET", "on"},
          {"FX_RET_TWO", "two"},
          {"FX_RET_HUGE", String.duplicate("x", 70_000)}
        ]
      )

    # Its own trace: values past the value budget would otherwise take the
    # budget from the reads above, whichever dependency compiles first.
    big = TracerFixtures.project(Path.join(root, "b"), Map.keys(@big), @big)
    TracerFixtures.put_config(big, @big_config)
    big_traced = TracerFixtures.trace(big, Map.keys(@big))

    %{
      traced: traced,
      trace_file: Path.join([root, "p", "trace", "trace-main.jsonl"]),
      big: big_traced,
      big_file: Path.join([root, "b", "trace", "trace-main.jsonl"])
    }
  end

  defp rec(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp reads(ctx, mfa, pred),
    do: Enum.filter(ctx.traced.report.events, &(&1["mfa"] == mfa and pred.(&1)))

  defp named(name), do: &(&1["arg"]["name"] == name)
  defp keyed(key), do: &(&1["arg"]["key_name"] == key)

  test "the traced compile completed", ctx do
    assert {:ok, 0} = ctx.traced.result, ctx.traced.log
    assert ctx.traced.report.problems == []
  end

  test "an env read carries what it returned, set or unset", ctx do
    assert [%{"returned" => set} | _] = reads(ctx, "os:getenv/1", named("FX_RET_SET"))
    assert set == rec({:ok, "on"})
    assert [%{"returned" => unset} | _] = reads(ctx, "os:getenv/1", named("FX_RET_UNSET_VAR"))
    assert unset == rec(:error)
  end

  # OTP's os:getenv/2 reaches os:getenv/1 through a remote call: its read is
  # the getenv/1 event, with the variable's own value (not the default).
  test "os:getenv/2's read is the os:getenv/1 below it", ctx do
    assert [%{"returned" => two} | _] = reads(ctx, "os:getenv/1", named("FX_RET_TWO"))
    assert two == rec({:ok, "two"})
  end

  test "a config read carries the fetch_env shape, get_env/3's default is marked", ctx do
    assert [%{"returned" => k} | _] = reads(ctx, "application:get_env/2", keyed("k"))
    assert k == rec({:ok, 42})

    assert [%{"returned" => "default"} | _] =
             reads(ctx, "application:get_env/3", keyed("missing"))
  end

  test "a huge value is unrecordable and the compile still finishes", ctx do
    assert [%{"returned" => "unrecordable"} | _] = reads(ctx, "os:getenv/1", named("FX_RET_HUGE"))
  end

  # Review focus: the toolchain's own get_env calls are return-traced too,
  # but only a written event gets a returned line, and every frame drains.
  test "one returned line per recorded read, none pending at the end", ctx do
    lines = ctx.trace_file |> File.stream!() |> Enum.map(&JSON.decode!/1)
    ids = for %{"kind" => "event", "call_id" => id} <- lines, do: id
    returned = for %{"kind" => "returned", "call_id" => id} <- lines, do: id

    assert length(ids) >= 2000
    assert Enum.sort(returned) == Enum.sort(ids)
    assert %{"pending_returns" => 0} = Enum.find(lines, &(&1["kind"] == "stats"))
  end

  # A returned line follows its event one to one: it counts as a call, but
  # not against the user-event cap, which stays the events' own budget.
  test "returned lines do not count as user events", ctx do
    lines = ctx.trace_file |> File.stream!() |> Enum.map(&JSON.decode!/1)
    events = Enum.count(lines, &(&1["kind"] == "event"))
    assert Enum.count(lines, &(&1["kind"] == "returned")) >= 2000
    assert %{"user_events" => ^events} = Enum.find(lines, &(&1["kind"] == "stats"))
  end

  describe "the value budget" do
    test "the trace stays whole and within the report's budget", ctx do
      assert {:ok, 0} = ctx.big.result, ctx.big.log
      assert ctx.big.report.problems == []
      refute ctx.big.report.over_budget
    end

    test "a value read again and again is written once", ctx do
      same = rec({:ok, String.duplicate("s", @big_size)})
      reads = reads(%{traced: ctx.big}, "application:get_env/2", keyed("same"))

      assert length(reads) == 2000
      assert Enum.all?(reads, &(&1["returned"] == same))

      values =
        for %{"kind" => "value", "value" => v} <- big_lines(ctx), v == same, do: v

      assert length(values) == 1
    end

    test "values past the budget are unrecordable, those within it recorded", ctx do
      distinct =
        Enum.filter(
          ctx.big.report.events,
          &(&1["mfa"] == "application:get_env/2" and &1["arg"]["key_name"] =~ ~r/^v\d+$/)
        )

      assert length(distinct) == 300
      {kept, dropped} = Enum.split_with(distinct, &(&1["returned"] != "unrecordable"))

      assert dropped != []
      assert length(kept) in 100..140

      for %{"returned" => v, "arg" => %{"key_name" => "v" <> i}} <- kept do
        assert v == rec({:ok, String.pad_trailing("v#{i}-", @big_size, "d")})
      end

      value_bytes =
        for(%{"kind" => "value", "value" => v} <- big_lines(ctx), do: byte_size(v)) |> Enum.sum()

      assert value_bytes <= 8 * 1024 * 1024
    end
  end

  defp big_lines(ctx), do: ctx.big_file |> File.stream!() |> Enum.map(&JSON.decode!/1)
end
