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

    %{traced: traced, trace_file: Path.join([root, "p", "trace", "trace-main.jsonl"])}
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
end
