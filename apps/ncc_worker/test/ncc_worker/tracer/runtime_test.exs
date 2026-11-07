defmodule NccWorker.Tracer.RuntimeTest do
  # Starts separate VMs with the tracer on their code path; each test owns its
  # dir. One such module at a time (the :real_vm group), alongside the unit
  # suites, so their compiles do not contend.
  use ExUnit.Case, async: true, group: :real_vm

  @moduletag :tmp_dir
  @moduletag timeout: 180_000

  defp ebin, do: :ncc_tracer |> :code.which() |> List.to_string() |> Path.dirname()

  defp lines(file) do
    file |> File.read!() |> String.split("\n", trim: true) |> Enum.map(&JSON.decode!/1)
  end

  defp kind(lines, kind), do: Enum.filter(lines, &(&1["kind"] == kind))

  defp run_script(dir, body, env \\ []) do
    script = Path.join(dir, "script.exs")
    File.write!(script, body)

    {out, status} =
      System.cmd("elixir", ["-pa", ebin(), script],
        env: [{"NCC_TRACE_DIR", dir} | env],
        stderr_to_stdout: true
      )

    {status, out}
  end

  defp compile_fixture(dir, name, source) do
    fx = Path.join(dir, name)
    File.write!(fx, source)

    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      Code.compile_file(#{inspect(fx)})
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    {dir |> Path.join("trace-main.jsonl") |> lines(), out}
  end

  test "a module-body read inside a window is a user event with its file and line",
       %{tmp_dir: dir} do
    fx = Path.join(dir, "fx_attr.ex")

    File.write!(fx, """
    defmodule FxAttr do
      @os :os.type()
      def os, do: @os
      def runtime, do: :os.version()
    end
    """)

    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx_attr")
      _ = :ncc_tracer.fire("fx_attr")
      Code.compile_file(#{inspect(fx)})
      :ok = :ncc_tracer.window_close(tok, "fx_attr")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"role" => "main", "depth" => 64}] = kind(lines, "start")
    [open] = kind(lines, "window_open")
    [%{"app" => "fx_attr", "depth_ok" => true} = close] = kind(lines, "window_close")

    assert Enum.any?(
             kind(lines, "sentinel"),
             &(&1["app"] == "fx_attr" and &1["ts"] >= open["ts"] and &1["ts"] <= close["ts"])
           )

    # The test script is itself evaluated code with no object file, so its
    # own Path calls are user events too; pick the module body's read.
    event =
      Enum.find(
        kind(lines, "event"),
        &(&1["mfa"] == "os:type/0" and String.ends_with?(&1["user"]["file"] || "", "fx_attr.ex"))
      )

    assert %{"channel" => "os_identity", "extent" => "frame"} = event
    assert event["user"]["line"] == 2
    # The stack was seen whole, so its bottom frame (where the process
    # started) is recorded too.
    assert %{"module" => bottom} = event["bottom"]
    assert is_binary(bottom)
    # The module body runs as elixir_compiler_N, which has no object file:
    # not toolchain, so it is the user frame (not the script further down).
    assert event["user"]["module"] =~ ~r/^elixir_compiler_\d+$/
    assert event["ts"] >= open["ts"] and event["ts"] <= close["ts"]

    # The runtime-only function body never ran.
    refute Enum.any?(kind(lines, "event"), &(&1["mfa"] == "os:version/0"))

    assert [
             %{
               "status" => "ok",
               "final_sentinel" => true,
               "depth_ok" => true,
               "overflow" => false
             }
           ] =
             kind(lines, "end")

    assert [%{"calls" => calls}] = kind(lines, "stats")
    assert calls > 0
  end

  test "System.user_home, File.lstat and File.read_link in a module body are user events",
       %{tmp_dir: dir} do
    {lines, _out} =
      compile_fixture(dir, "fx_home.ex", """
      defmodule FxHome do
        @home System.user_home()
        @lstat File.lstat("/nonexistent-ncc")
        @link File.read_link("/nonexistent-ncc")
        def all, do: {@home, @lstat, @link}
      end
      """)

    events =
      for %{"user" => %{"file" => file}} = e <- kind(lines, "event"),
          String.ends_with?(file || "", "fx_home.ex"),
          do: {e["channel"], e["mfa"], e["user"]["line"]}

    assert {"env", "init:get_argument/1", 2} in events
    assert {"file_read", "file:read_link_info/2", 3} in events
    assert {"file_read", "file:read_link/1", 4} in events
  end

  test "an event records its immediate caller: big integer literals read the word size",
       %{tmp_dir: dir} do
    {lines, _out} =
      compile_fixture(dir, "fx_bigint.ex", """
      defmodule FxBigint do
        @big :erlang.binary_to_integer(String.duplicate("7", 20_000))
        def big, do: @big
      end
      """)

    event =
      Enum.find(
        kind(lines, "event"),
        &(&1["mfa"] == "erlang:system_info/1" and &1["arg"]["key"] == "wordsize")
      )

    assert %{"caller" => %{"module" => "erlang", "function" => "big_binary_to_int", "arity" => 2}} =
             event

    assert String.ends_with?(event["user"]["file"], "fx_bigint.ex")
  end

  test "a task spawned by a module body is a user process", %{tmp_dir: dir} do
    {lines, _} =
      compile_fixture(dir, "fx_task.ex", """
      defmodule FxTask do
        @os Task.async(fn -> :os.type() end) |> Task.await()
        def os, do: @os
      end
      """)

    assert Enum.any?(
             kind(lines, "event"),
             &(&1["mfa"] == "os:type/0" and &1["extent"] in ["lineage", "frame"])
           )
  end

  test "an MFA task or an external-capture spawn from a module body is a user process",
       %{tmp_dir: dir} do
    {lines, _} =
      compile_fixture(dir, "fx_mfa.ex", """
      defmodule FxMfa do
        @a Task.async(System, :get_env, ["NCC_FX_MFA"]) |> Task.await()
        @b (
             parent = self()
             spawn(fn -> send(parent, {:done, :erlang.apply(&System.get_env/1, ["NCC_FX_CAP"])}) end)
             receive do
               {:done, v} -> v
             end
           )
        @c (
             pid = spawn(&System.get_env/0)
             ref = Process.monitor(pid)
             receive do
               {:DOWN, ^ref, _, _, _} -> :ok
             end
           )
        def x, do: {@a, @b, @c}
      end
      """)

    events = kind(lines, "event")

    assert Enum.any?(
             events,
             &(&1["mfa"] == "os:getenv/1" and &1["arg"]["name"] == "NCC_FX_MFA" and
                 &1["extent"] == "lineage")
           )

    assert Enum.any?(
             events,
             &(&1["mfa"] == "os:getenv/1" and &1["arg"]["name"] == "NCC_FX_CAP" and
                 &1["extent"] in ["lineage", "frame"])
           )

    assert Enum.any?(
             events,
             &(&1["mfa"] in ["os:getenv/0", "os:env/0"] and &1["extent"] == "lineage")
           )
  end

  test "a process started by a user process from toolchain code is a user process",
       %{tmp_dir: dir} do
    {lines, _} =
      compile_fixture(dir, "fx_grand.ex", """
      defmodule FxGrand do
        # The child runs Task.start/3 from toolchain frames only; the
        # grandchild it starts is a user process because its parent is.
        @t Task.async(Task, :start, [System, :get_env, ["NCC_FX_GRAND"]]) |> Task.await()
        @wait Process.sleep(300)
        def t, do: {@t, @wait}
      end
      """)

    assert Enum.any?(
             kind(lines, "event"),
             &(&1["mfa"] == "os:getenv/1" and &1["arg"]["name"] == "NCC_FX_GRAND" and
                 &1["extent"] == "lineage")
           )
  end

  test "a lowered backtrace_depth is caught at the next window close", %{tmp_dir: dir} do
    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      :erlang.system_flag(:backtrace_depth, 1)
      :ok = :ncc_tracer.window_close(tok, "fx")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"depth_ok" => false}] = kind(lines, "window_close")
    # The close put the flag back, so the run's end is clean again.
    assert [%{"depth_ok" => true}] = kind(lines, "end")
    # The package's own system_flag call is an integrity event in user extent.
    assert Enum.any?(
             kind(lines, "event"),
             &(&1["mfa"] == "erlang:system_flag/2" and &1["channel"] == "integrity")
           )
  end

  test "stacks cut at a lowered depth are judged against that depth, and a restored flag still fails the window",
       %{tmp_dir: dir} do
    # An Agent started before the trace is a toolchain process: its stack
    # running System.get_env has only toolchain frames.
    {0, out} =
      run_script(dir, """
      # Agent.get/4 calls System.get_env(state): the state is the name.
      {:ok, agent} = Agent.start(fn -> "NCC_FX_FULL" end)
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      Agent.get(agent, System, :get_env, [])
      :erlang.system_flag(:backtrace_depth, 2)
      # Trace messages from two processes are not ordered: the flush makes
      # sure the collector has seen the lowering before the agent's read.
      # Without it a read can be judged at the old depth, and the window
      # check below (which does not depend on ordering) is the guarantee.
      :ok = :ncc_tracer.flush()
      Agent.update(agent, fn _ -> "NCC_FX_CUT" end)
      Agent.get(agent, System, :get_env, [])
      :erlang.system_flag(:backtrace_depth, 64)
      :ok = :ncc_tracer.flush()
      Agent.update(agent, fn _ -> "NCC_FX_BACK" end)
      Agent.get(agent, System, :get_env, [])
      :ok = :ncc_tracer.window_close(tok, "fx")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    events = kind(lines, "event")
    names = for e <- events, e["mfa"] == "os:getenv/1", do: {e["arg"]["name"], e["extent"]}

    refute Enum.any?(names, &match?({"NCC_FX_FULL", _}, &1)), out
    assert {"NCC_FX_CUT", "truncated"} in names, inspect(names)
    # Until the next check the lowest depth set holds, so a stack the raise
    # overtook in the collector's queue is still judged cut (fail closed):
    # the read after the raise is truncated too, in a window that fails.
    assert {"NCC_FX_BACK", "truncated"} in names, inspect(names)
    assert [%{"depth_ok" => false}] = kind(lines, "window_close")
    assert [%{"depth_ok" => true}] = kind(lines, "end")
  end

  test "a package switching off legacy tracing neither stops the session nor goes unrecorded",
       %{tmp_dir: dir} do
    {lines, _} =
      compile_fixture(dir, "fx_trace.ex", """
      defmodule FxTrace do
        @off :erlang.trace(:all, false, [:all])
        @pat :erlang.trace_pattern({:os, :type, 0}, false, [:global])
        @info :trace.session_info(:all)
        @os :os.type()
        def x, do: {@off, @pat, @info, @os}
      end
      """)

    events = kind(lines, "event")
    integrity = for e <- events, e["channel"] == "integrity", do: e["mfa"]

    assert "erlang:trace/3" in integrity
    assert "erlang:trace_pattern/3" in integrity
    assert "trace:session_info/1" in integrity
    assert Enum.any?(events, &(&1["mfa"] == "os:type/0" and &1["extent"] == "frame"))
    assert [%{"final_sentinel" => true}] = kind(lines, "end")
  end

  test "a stack the classifier cannot judge is an unjudged event, never dropped" do
    tc? = fn _ -> true end

    assert {:user, :unjudged, :none, :none} =
             :ncc_tracer.safe_extent([:not_a_frame], 64, tc?, false)

    assert {:user, :unjudged, :none, :none} =
             :ncc_tracer.safe_extent([{:m, :f, 0, []}], 64, fn _ -> raise "boom" end, false)

    assert :toolchain = :ncc_tracer.safe_extent([{:m, :f, 0, []}], 64, tc?, false)
  end

  test "the partitions variable makes the tracer refuse to start", %{tmp_dir: dir} do
    {0, out} =
      run_script(
        dir,
        "IO.inspect(:ncc_tracer.start_main(), label: \"started\")",
        [{"MIX_OS_DEPS_COMPILE_PARTITION_COUNT", "2"}]
      )

    assert out =~ "started: {:error, :partitions}"

    assert [%{"kind" => "refused_start", "why" => "partitions"}] =
             lines(Path.join(dir, "trace-main.jsonl"))
  end

  test "an event cap overflows, stops tracing and still ends the file", %{tmp_dir: dir} do
    {0, _} =
      run_script(
        dir,
        """
        {:ok, tok} = :ncc_tracer.start_main()
        for _ <- 1..50, do: Path.expand("x")
        :ok = :ncc_tracer.finish(tok, "ok")
        """,
        [{"NCC_TRACE_MAX_CALLS", "5"}]
      )

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"what" => "calls"}] = kind(lines, "overflow")
    assert [%{"overflow" => true}] = kind(lines, "end")
  end

  @tag :tracer_child
  test "a rebar3-style child VM records its sentinel and every compile:file", %{tmp_dir: dir} do
    src = Path.join(dir, "r3.erl")
    File.write!(src, "-module(r3).\n-export([f/0]).\nf() -> ok.\n")
    out = Path.join(dir, "out")
    File.mkdir_p!(out)
    escript = Path.join(dir, "compile.escript")

    # The compile runs in a process the escript waits on, and the escript
    # syncs with the tracer before it halts: erlang:halt/1 stops the VM at
    # once, so without the sync the last compile line can still be queued.
    File.write!(escript, """
    #!/usr/bin/env escript
    main([Src, Out]) ->
        {Pid, Ref} = spawn_monitor(fun() ->
            {ok, _} = compile:file(Src, [{outdir, Out}, no_spawn_compiler_process])
        end),
        receive {'DOWN', Ref, process, Pid, normal} -> ok end,
        ok = ncc_tracer:flush(),
        erlang:halt(0).
    """)

    {_, 0} =
      System.cmd("escript", [escript, src, out],
        env: [
          {"NCC_TRACE_DIR", dir},
          {"REBAR_BARE_COMPILER_OUTPUT_DIR", Path.join(dir, "_build/host/lib/r3")},
          {"ERL_AFLAGS", "-pa #{ebin()} -s ncc_tracer start_child"}
        ],
        stderr_to_stdout: true
      )

    [file] = Path.wildcard(Path.join(dir, "trace-child-r3-*.jsonl"))
    lines = lines(file)
    assert [%{"role" => "child", "app" => "r3"}] = kind(lines, "start")
    assert [%{"app" => "r3"}] = kind(lines, "sentinel")
    assert [%{"result" => "ok", "module" => "r3", "source" => source}] = kind(lines, "compile")
    assert source =~ "r3.erl"

    if File.exists?("/proc/self/maps") do
      assert [%{"nif_check" => "ok", "mapped_libs" => [_ | _]}] = kind(lines, "start")
      assert [%{"nif_check" => "ok", "mapped_libs" => [_ | _]} | _] = kind(lines, "libs")
    else
      assert [%{"nif_check" => "unavailable"}] = kind(lines, "start")
      assert [%{"nif_check" => "unavailable"} | _] = kind(lines, "libs")
    end
  end

  # The non-legacy session, as a package would find it.
  @find_session ~S"""
  [weak] = for {name, _} = w <- :trace.session_info(:all), name != :legacy, do: w
  """

  test "a package untracing a function through the session's BIF is recorded and fails the window",
       %{tmp_dir: dir} do
    fx = Path.join(dir, "fx_untrace.ex")

    File.write!(fx, """
    defmodule FxUntrace do
      @x (
           #{@find_session}
           :erts_internal.trace_pattern(weak, {:os, :getenv, 1}, false, [:global])
         )
      def x, do: @x
    end
    """)

    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      Code.compile_file(#{inspect(fx)})
      :ok = :ncc_tracer.window_close(tok, "fx")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    integrity = for e <- kind(lines, "event"), e["channel"] == "integrity", do: e["mfa"]
    assert "erts_internal:trace_pattern/4" in integrity
    assert [%{"integrity_ok" => false}] = kind(lines, "window_close")
    # The close set the pattern again, so the run's end checks clean.
    assert [%{"integrity_ok" => true}] = kind(lines, "end")
  end

  test "a forged final sentinel before the package destroys the session does not count",
       %{tmp_dir: dir} do
    fx = Path.join(dir, "fx_destroy.ex")

    File.write!(fx, """
    defmodule FxDestroy do
      @x (
           #{@find_session}
           :ncc_tracer_probe.fire(~c"__final__")
           :erts_internal.trace_session_destroy(weak)
         )
      def x, do: @x
    end
    """)

    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      Code.compile_file(#{inspect(fx)})
      :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    integrity = for e <- kind(lines, "event"), e["channel"] == "integrity", do: e["mfa"]
    assert "erts_internal:trace_session_destroy/1" in integrity
    assert "ncc_tracer_probe:fire/1" in integrity
    assert [%{"final_sentinel" => false}] = kind(lines, "end")
  end

  test "a reloaded module loses its patterns: the check fails the window and sets them again",
       %{tmp_dir: dir} do
    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      true = :code.unstick_mod(:os)
      {:module, :os} = :code.load_file(:os)
      :code.stick_mod(:os)
      :ok = :ncc_tracer.window_close(tok, "fx")
      :os.type()
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"integrity_ok" => false}] = kind(lines, "window_close"), out
    assert [%{"integrity_ok" => true}] = kind(lines, "end")
    integrity = for e <- kind(lines, "event"), e["channel"] == "integrity", do: e["mfa"]
    assert "code:unstick_mod/1" in integrity
    # Traced again after the close.
    assert Enum.any?(kind(lines, "event"), &(&1["mfa"] == "os:type/0"))
  end

  test "a killed collector leaves a collector_down line and the API reports it",
       %{tmp_dir: dir} do
    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      pid = :ncc_tracer.collector()
      true = is_pid(pid)
      # A process taking the old registered name does not receive the calls.
      true = Process.register(self(), :ncc_tracer_collector)
      :ok = :ncc_tracer.window_open(tok, "fx")
      ref = Process.monitor(pid)
      Process.exit(pid, :kill)
      receive do
        {:DOWN, ^ref, _, _, _} -> :ok
      end
      Process.sleep(100)
      IO.inspect(:ncc_tracer.finish(tok, "ok"), label: "finish")
      """)

    assert out =~ "finish: {:error, :no_tracer}"
    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [_] = kind(lines, "window_open")
    assert [%{"reason" => "killed"}] = kind(lines, "collector_down")
    assert [] = kind(lines, "end")
  end

  test "an undelivered trace fails the window and the end", %{tmp_dir: dir} do
    {0, _} =
      run_script(
        dir,
        """
        {:ok, tok} = :ncc_tracer.start_main()
        :ok = :ncc_tracer.window_open(tok, "fx")
        :ok = :ncc_tracer.window_close(tok, "fx")
        :ncc_tracer.finish(tok, "ok")
        """,
        [{"NCC_TRACE_DELIVER_TIMEOUT_MS", "0"}]
      )

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"delivered" => false, "integrity_ok" => false}] = kind(lines, "window_close")
    assert [%{"delivered" => false, "integrity_ok" => false}] = kind(lines, "end")
  end

  test "stacks the tracer cannot judge are written as unjudged events and counted",
       %{tmp_dir: dir} do
    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      c = :ncc_tracer.collector()
      ts = :erlang.monotonic_time(:nanosecond)
      # A frame whose location is not a list: the frame renderer crashes.
      send(c, {:trace_ts, self(), :call, {:os, :getenv, ["NCC_FX_BAD"]}, [{:m, :f, 0, :nope}], ts})
      # A call message with no stack (a replaced match spec).
      send(c, {:trace_ts, self(), :call, {:os, :getenv, ["NCC_FX_NOSTACK"]}, ts})
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    events = kind(lines, "event")

    for name <- ["NCC_FX_BAD", "NCC_FX_NOSTACK"] do
      assert Enum.any?(events, &(&1["arg"]["name"] == name and &1["extent"] == "unjudged")),
             name
    end

    assert [%{"unjudged" => 2}] = kind(lines, "stats")
  end

  test "start_main hands child VMs the tracer through ERL_AFLAGS, quoting the path",
       %{tmp_dir: dir} do
    spaced = Path.join(dir, "with space/ebin")
    File.mkdir_p!(spaced)

    for beam <- Path.wildcard(Path.join(ebin(), "ncc_tracer*.beam")),
        do: File.cp!(beam, Path.join(spaced, Path.basename(beam)))

    script = Path.join(dir, "script.exs")

    File.write!(script, """
    {:ok, tok} = :ncc_tracer.start_main()
    IO.puts("AFLAGS=" <> System.get_env("ERL_AFLAGS"))
    {_, 0} = System.cmd("erl", ["-noshell", "-eval", "halt()."],
      env: [{"REBAR_BARE_COMPILER_OUTPUT_DIR", "/x/lib/kid"}])
    :ok = :ncc_tracer.finish(tok, "ok")
    """)

    {out, 0} =
      System.cmd("elixir", ["-pa", spaced, script],
        env: [{"NCC_TRACE_DIR", dir}, {"ERL_AFLAGS", "+pc unicode"}],
        stderr_to_stdout: true
      )

    assert out =~ ~s(AFLAGS=+pc unicode -pa "#{spaced}" -s ncc_tracer start_child)
    assert [file] = Path.wildcard(Path.join(dir, "trace-child-kid-*.jsonl"))

    assert [%{"role" => "child", "app" => "kid", "tracer" => tracer}] =
             file |> lines() |> kind("start")

    # Both VMs loaded the same tracer modules, and say which by md5.
    assert [%{"tracer" => ^tracer}] =
             dir |> Path.join("trace-main.jsonl") |> lines() |> kind("start")

    assert Map.keys(tracer) == ~w(ncc_tracer ncc_tracer_channels ncc_tracer_stack)
    assert tracer["ncc_tracer"] == Base.encode16(:ncc_tracer.module_info(:md5))
  end

  test "requests without the driver's token are rejected and recorded, never a clean end",
       %{tmp_dir: dir} do
    fx = Path.join(dir, "fx_forge.ex")

    File.write!(fx, """
    defmodule FxForge do
      @x (
           c = :ncc_tracer.collector()
           ts = :erlang.monotonic_time(:nanosecond)
           send(c, {:ncc_call, self(), make_ref(), :final_nonce})
           send(c, {:ncc_call, self(), make_ref(), "guess", {:finish, "ok", ts, true}})
           send(c, {:ncc_call, self(), make_ref(), {:finish, "ok", ts, true}})
           :ncc_tracer.finish(:forged, "ok")
         )
      def x, do: @x
    end
    """)

    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      Code.compile_file(#{inspect(fx)})
      IO.inspect(:ncc_tracer.finish(tok, "ok"), label: "finish")
      """)

    assert out =~ "finish: :ok"
    lines = lines(Path.join(dir, "trace-main.jsonl"))
    integrity = for e <- kind(lines, "event"), e["channel"] == "integrity", do: e["mfa"]
    # Three raw sends, and the package's finish/2 call makes two requests
    # (its nonce, its finish) with a token it does not have.
    assert Enum.count(integrity, &(&1 == "ncc_tracer:forged_request")) == 5, inspect(integrity)
    assert "ncc_tracer:finish/2" in integrity
    # Only the driver's finish ended the file, and it is not clean.
    assert [%{"integrity_ok" => false, "final_sentinel" => true}] = kind(lines, "end")
  end

  test "forged requests count against the user event cap", %{tmp_dir: dir} do
    {0, out} =
      run_script(
        dir,
        """
        {:ok, tok} = :ncc_tracer.start_main()
        c = :ncc_tracer.collector()
        for _ <- 1..50, do: send(c, {:ncc_call, self(), make_ref(), :final_nonce})
        Process.sleep(200)
        IO.inspect(:ncc_tracer.finish(tok, "ok"), label: "finish")
        """,
        [{"NCC_TRACE_MAX_USER_EVENTS", "3"}]
      )

    assert out =~ "finish: :ok"
    lines = lines(Path.join(dir, "trace-main.jsonl"))
    forged = for e <- kind(lines, "event"), e["mfa"] == "ncc_tracer:forged_request", do: e
    assert length(forged) <= 3, inspect(forged)
    assert [%{"what" => "user_events"}] = kind(lines, "overflow")
    assert [%{"overflow" => true, "integrity_ok" => false}] = kind(lines, "end")
  end

  test "a watcher killed over and over writes a bounded number of lines", %{tmp_dir: dir} do
    {0, out} =
      run_script(
        dir,
        """
        {:ok, tok} = :ncc_tracer.start_main()
        c = :ncc_tracer.collector()

        for _ <- 1..20 do
          {:monitors, monitors} = Process.info(c, :monitors)
          for {:process, p} when is_pid(p) <- monitors, do: Process.exit(p, :kill)
          Process.sleep(20)
        end

        IO.inspect(:ncc_tracer.finish(tok, "ok"), label: "finish")
        """,
        [{"NCC_TRACE_MAX_USER_EVENTS", "3"}]
      )

    assert out =~ "finish: :ok"
    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert length(kind(lines, "watcher_down")) <= 3, out
    assert [%{"what" => "user_events"}] = kind(lines, "overflow")
    assert [%{"overflow" => true, "integrity_ok" => false}] = kind(lines, "end")
  end

  test "reading another process's dictionary is recorded", %{tmp_dir: dir} do
    {lines, _} =
      compile_fixture(dir, "fx_peek.ex", """
      defmodule FxPeek do
        @x Process.info(self(), :dictionary) |> elem(0)
        def x, do: @x
      end
      """)

    assert Enum.any?(
             kind(lines, "event"),
             &(&1["mfa"] == "erlang:process_info/2" and &1["channel"] == "integrity")
           )
  end

  test "a traced module deleted and purged without a reload fails the check",
       %{tmp_dir: dir} do
    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      # Version is not sticky: deleted and purged, nothing loads it again
      # before the close.
      true = :code.delete(Version)
      _ = :code.purge(Version)
      false = :erlang.module_loaded(Version)
      :ok = :ncc_tracer.window_close(tok, "fx")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"integrity_ok" => false}] = kind(lines, "window_close"), out
    # The close loaded it and set its patterns again.
    assert [%{"integrity_ok" => true}] = kind(lines, "end")
  end

  test "a killed watcher is recorded and fails the end", %{tmp_dir: dir} do
    {0, out} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      {:monitors, monitors} = Process.info(:ncc_tracer.collector(), :monitors)
      [watcher] = for {:process, p} when is_pid(p) <- monitors, do: p
      Process.exit(watcher, :kill)
      Process.sleep(100)
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert [%{"reason" => "killed"}] = kind(lines, "watcher_down"), out
    assert [%{"integrity_ok" => false}] = kind(lines, "end")
  end

  test "killing the watcher and then the collector still leaves a line", %{tmp_dir: dir} do
    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      c = :ncc_tracer.collector()
      {:monitors, monitors} = Process.info(c, :monitors)
      [watcher] = for {:process, p} when is_pid(p) <- monitors, do: p
      Process.exit(watcher, :kill)
      Process.sleep(100)
      Process.exit(c, :kill)
      Process.sleep(100)
      {:error, :no_tracer} = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    assert kind(lines, "watcher_down") != [] or kind(lines, "collector_down") != []
    assert [] = kind(lines, "end")
  end

  test "the script run with -S is toolchain, by its real path; files it compiles are not",
       %{tmp_dir: dir} do
    bin = Path.join(dir, "bin")
    real = Path.join(dir, "real")
    File.mkdir_p!(bin)
    File.mkdir_p!(real)
    fx = Path.join(dir, "fx_other.ex")

    File.write!(
      fx,
      "defmodule FxOther do\n  @v System.get_env(\"NCC_FX_OTHER\")\n  def v, do: @v\nend\n"
    )

    fx_after = Path.join(dir, "fx_after.ex")

    File.write!(fx_after, """
    defmodule FxAfter do
      @after_compile __MODULE__
      def __after_compile__(_env, _bytecode),
        do: Code.compile_string(~s|System.get_env("NCC_FX_FORGED_AFTER")|, #{inspect(Path.join(real, "fakemix"))})
    end
    """)

    # Like bin/mix: found on PATH, through a symlink, run by elixir -S.
    File.write!(Path.join(real, "fakemix"), """
    {:ok, tok} = :ncc_tracer.start_main()
    System.get_env("NCC_FX_SCRIPT")
    # Spawned from the script's frame: toolchain lineage (bin/mix itself
    # spawns nothing; Mix does, from its own modules).
    spawn(System, :get_env, ["NCC_FX_SCRIPT_CHILD"])
    # A fun's module is elixir_compiler_N, a name that is reused across
    # evaluated files: it cannot be told apart from a package's, so a
    # process running one stays user (fail closed).
    spawn(fn -> System.get_env("NCC_FX_SCRIPT_FUN") end)
    Process.sleep(100)
    Code.compile_file(#{inspect(fx)})
    script = #{inspect(Path.join(real, "fakemix"))}
    # (d) a forged script frame above the real one,
    # reached by a tail call from __after_compile__, in the driver.
    Code.compile_file(#{inspect(fx_after)})
    # (c) a forged script frame at the bottom of a process that is not the
    # driver, spawned from the script's own frame (toolchain lineage).
    spawn(Code, :compile_string, [~s|System.get_env("NCC_FX_FORGED_SPAWN")|, script])
    Process.sleep(200)
    :ok = :ncc_tracer.finish(tok, "ok")
    """)

    File.chmod!(Path.join(real, "fakemix"), 0o755)
    File.ln_s!(Path.join(real, "fakemix"), Path.join(bin, "fakemix"))

    {out, 0} =
      System.cmd("elixir", ["-pa", ebin(), "-S", "fakemix"],
        env: [{"NCC_TRACE_DIR", dir}, {"PATH", bin <> ":" <> System.get_env("PATH")}],
        stderr_to_stdout: true
      )

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    # The symlink's target, not the PATH entry.
    assert [%{"mix_script" => script}] = kind(lines, "start"), out
    assert Path.type(script) == :absolute and String.ends_with?(script, "/real/fakemix")

    names = for e <- kind(lines, "event"), e["mfa"] == "os:getenv/1", do: e["arg"]["name"]
    refute "NCC_FX_SCRIPT" in names, inspect(names)
    refute "NCC_FX_SCRIPT_CHILD" in names, inspect(names)
    assert "NCC_FX_OTHER" in names, inspect(names)
    assert "NCC_FX_SCRIPT_FUN" in names, inspect(names)
    assert "NCC_FX_FORGED_AFTER" in names, inspect(names)
    assert "NCC_FX_FORGED_SPAWN" in names, inspect(names)
  end

  test "without -S there is no mix script", %{tmp_dir: dir} do
    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    assert [%{"mix_script" => nil}] =
             dir |> Path.join("trace-main.jsonl") |> lines() |> kind("start")
  end

  # Trace messages from two processes reach the collector in any order: a
  # child's own events can arrive before its parent's `spawn` message.
  @race """
  {:ok, tok} = :ncc_tracer.start_main()
  c = :ncc_tracer.collector()
  ts = :erlang.monotonic_time(:nanosecond)
  child = :erlang.list_to_pid(~c"<0.9999.0>")
  mfa = {Mix.Task, :run, [["compile"]]}
  stack = [{Mix.Project, :get, 0, []}]
  send(c, {:trace_ts, child, :spawned, self(), mfa, ts})
  send(c, {:trace_ts, child, :call, {:os, :getenv, ["NCC_FX_RACE"]}, stack, ts})
  PARENT
  :ok = :ncc_tracer.finish(tok, "ok")
  """

  defp race(dir, parent, env \\ []) do
    {0, out} = run_script(dir, String.replace(@race, "PARENT", parent), env)

    names =
      for e <- dir |> Path.join("trace-main.jsonl") |> lines() |> kind("event"),
          do: {e["arg"]["name"], e["extent"]}

    {names, out}
  end

  test "a child's events waiting on a late parent spawn message get the parent's lineage",
       %{tmp_dir: dir} do
    {names, out} =
      race(dir, ~S"""
      Process.sleep(200)
      send(c, {:trace_ts, self(), :spawn, child, mfa, ts})
      """)

    refute {"NCC_FX_RACE", "lineage"} in names, inspect({names, out})
  end

  test "a parent spawn message that never comes leaves the child a user process",
       %{tmp_dir: dir} do
    {names, out} = race(dir, "", [{"NCC_TRACE_LINEAGE_TIMEOUT_MS", "50"}])
    assert {"NCC_FX_RACE", "lineage"} in names, inspect({names, out})
  end

  test "every file-backed mapping of a maps file, each once, whatever its name" do
    maps = """
    aaaa-bbbb r--p 00000000 fe:01 1 /usr/lib/aarch64-linux-gnu/libc.so.6
    bbbb-cccc r-xp 00001000 fe:01 1 /usr/lib/aarch64-linux-gnu/libc.so.6
    cccc-dddd r-xp 00000000 fe:01 2 /tmp/a dir/evil.so (deleted)
    dddd-eeee rw-p 00000000 00:00 0
    eeee-ffff r--p 00000000 fe:01 3 /usr/local/lib/erlang/erts-16/bin/beam.smp
    ffff-1111 r-xp 00000000 00:00 0 [vdso]
    1111-2222 r-xp 00000000 fe:01 4 /opt/lib/libfoo.so.1.2.3
    2222-3333 r-xp 00000000 fe:01 5 /tmp/payload
    3333-4444 rw-p 00000000 00:00 0 [heap]
    """

    # x.so -> payload: the map shows the link's target, with no .so in it.
    assert :ncc_tracer.maps_libs(maps) ==
             {:ok,
              [
                "/opt/lib/libfoo.so.1.2.3",
                "/tmp/a dir/evil.so (deleted)",
                "/tmp/payload",
                "/usr/lib/aarch64-linux-gnu/libc.so.6",
                "/usr/local/lib/erlang/erts-16/bin/beam.smp"
              ]}
  end

  test "a file-backed mapping whose path cannot be read makes the check unavailable" do
    assert :unavailable = :ncc_tracer.maps_libs("aaaa-bbbb r-xp 00000000 fe:01 7\n")
    assert :unavailable = :ncc_tracer.maps_libs("aaaa-bbbb r-xp 00000000 fe:01 7 relative/x\n")
    assert :unavailable = :ncc_tracer.maps_libs("garbage\n")
    assert {:ok, []} = :ncc_tracer.maps_libs("aaaa-bbbb rw-p 00000000 00:00 0\n")
  end

  @maps? File.exists?("/proc/self/maps")

  test "start and end record the mapped libraries, or that they cannot", %{tmp_dir: dir} do
    {0, _} =
      run_script(dir, """
      {:ok, tok} = :ncc_tracer.start_main()
      :ok = :ncc_tracer.window_open(tok, "fx")
      :ok = :ncc_tracer.window_close(tok, "fx")
      :ok = :ncc_tracer.finish(tok, "ok")
      """)

    lines = lines(Path.join(dir, "trace-main.jsonl"))
    [start] = kind(lines, "start")
    [close] = kind(lines, "window_close")
    [ending] = kind(lines, "end")

    if @maps? do
      for l <- [start, close, ending] do
        assert %{"nif_check" => "ok", "mapped_libs" => [_ | _] = libs} = l
        assert Enum.all?(libs, &String.starts_with?(&1, "/"))
      end

      # crypto is loaded before the start snapshot, with the libraries it maps.
      assert Enum.any?(start["mapped_libs"], &(&1 =~ "crypto"))
    else
      for l <- [start, close, ending],
          do: assert(%{"nif_check" => "unavailable", "mapped_libs" => nil} = l)
    end
  end
end
