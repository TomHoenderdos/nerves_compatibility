defmodule NccWorker.Tracer.ReportTest do
  use ExUnit.Case, async: true

  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @tracer %{"ncc_tracer" => "AA", "ncc_tracer_channels" => "BB", "ncc_tracer_stack" => "CC"}
  @start %{"kind" => "start", "role" => "main", "app" => "main", "ts" => 1, "tracer" => @tracer}

  defp child_start(app, tracer \\ @tracer),
    do: %{"kind" => "start", "role" => "child", "app" => app, "tracer" => tracer}

  defp child_sentinel(app, checks \\ %{}),
    do:
      Map.merge(
        %{
          "kind" => "sentinel",
          "app" => app,
          "ts" => 1,
          "depth_ok" => true,
          "integrity_ok" => true
        },
        checks
      )

  @snapshot %{
    "kind" => "config_env",
    "truncated" => false,
    "entries" => [
      %{"app" => "logger", "key" => "level", "value" => "g2gCZAACb2tkAARpbmZv"},
      %{"app" => "fx", "key" => "big", "value" => nil, "oversize" => true}
    ]
  }

  @closure %{
    "kind" => "closure",
    "packages" => ["pkg"],
    "deps" => [
      %{"app" => "r3", "manager" => "rebar3", "children" => []},
      %{"app" => "pkg", "manager" => "mix", "children" => ["r3"]}
    ]
  }

  defp window(app, open, close, checks \\ %{}) do
    [
      %{"kind" => "window_open", "app" => app, "ts" => open},
      %{
        "kind" => "sentinel",
        "app" => app,
        "ts" => open + 1,
        "depth_ok" => true,
        "integrity_ok" => true
      },
      Map.merge(
        %{
          "kind" => "window_close",
          "app" => app,
          "ts" => close,
          "depth_ok" => true,
          "integrity_ok" => true,
          "delivered" => true
        },
        checks
      )
    ]
  end

  @stats %{
    "kind" => "stats",
    "calls" => 10,
    "user_events" => 0,
    "unjudged" => 0,
    "truncated" => 0
  }
  @ending %{
    "kind" => "end",
    "status" => "ok",
    "ts" => 100,
    "depth_ok" => true,
    "integrity_ok" => true,
    "delivered" => true,
    "final_sentinel" => true,
    "overflow" => false,
    "late_loaded" => []
  }

  defp clean,
    do:
      [@start, @snapshot, @closure] ++
        window("r3", 10, 20) ++ window("pkg", 30, 40) ++ [@stats, @ending]

  defp without_snapshot, do: Enum.reject(clean(), &(&1["kind"] == "config_env"))

  defp write(dir, name, lines),
    do: File.write!(Path.join(dir, name), Enum.map_join(lines, "", &(JSON.encode!(&1) <> "\n")))

  defp read(dir, lines) do
    write(dir, "trace-main.jsonl", lines)
    Report.read(dir)
  end

  defp replace(lines, kind, app, changes) do
    Enum.map(lines, fn
      %{"kind" => ^kind} = l when app == nil or :erlang.map_get("app", l) == app ->
        Map.merge(l, changes)

      l ->
        l
    end)
  end

  test "a clean trace has no problems and keeps every check", %{tmp_dir: dir} do
    r = read(dir, clean())
    assert r.problems == []

    assert [
             %{
               app: "r3",
               open: 10,
               close: 20,
               depth_ok: true,
               integrity_ok: true,
               delivered: true
             },
             %{app: "pkg", open: 30, close: 40}
           ] = r.windows

    assert [%{app: "r3", ts: 11, integrity_ok: true}, %{app: "pkg", ts: 31}] = r.sentinels
    assert %{"status" => "ok"} = r.ending
    assert %{"unjudged" => 0} = r.stats
  end

  test "every failed integrity or delivery check is a problem", %{tmp_dir: dir} do
    for {lines, problem} <- [
          {replace(clean(), "window_close", "r3", %{"integrity_ok" => false}),
           "r3's window failed its integrity check"},
          {replace(clean(), "window_close", "pkg", %{"delivered" => false}),
           "pkg's window was not fully delivered"},
          {replace(clean(), "sentinel", "pkg", %{"integrity_ok" => false}),
           "pkg's sentinel failed its integrity check"},
          {replace(clean(), "end", nil, %{"integrity_ok" => false}),
           "the end failed its integrity check"},
          {replace(clean(), "end", nil, %{"delivered" => false}),
           "the end was not fully delivered"},
          {replace(clean(), "stats", nil, %{"unjudged" => 3}), "3 unjudged trace events"},
          {clean() ++ [%{"kind" => "unencodable"}], "unencodable trace line"},
          {clean() ++ [%{"kind" => "collector_down", "reason" => "killed", "ts" => 5}],
           "trace collector died: killed"},
          {clean() ++ [%{"kind" => "watcher_down", "reason" => "killed", "ts" => 5}],
           "trace watcher died: killed"},
          {clean() ++
             [
               %{"kind" => "quiet_open", "app" => "r3", "ts" => 21},
               %{"kind" => "quiet_close", "app" => "r3", "ts" => 22, "delivered" => false}
             ], "r3's native patterns were not fully delivered"},
          {clean() ++ [%{"kind" => "mystery"}], "unexpected line kind mystery"}
        ] do
      r = read(dir, lines)
      assert problem in r.problems, inspect({problem, r.problems})
    end
  end

  test "a missing end line leaves ending nil and is a problem", %{tmp_dir: dir} do
    r = read(dir, Enum.reject(clean(), &(&1["kind"] == "end")))
    assert r.ending == nil
    assert "no end line" in r.problems
  end

  test "an end that is not a clean finish is a problem", %{tmp_dir: dir} do
    for {changes, problem} <- [
          {%{"status" => "compile_failed"}, ~s(traced compile ended "compile_failed")},
          {%{"final_sentinel" => false}, "final sentinel missing"},
          {%{"depth_ok" => false}, "the end lost its backtrace depth"},
          {%{"overflow" => true}, "the end reports an overflow"},
          {%{"late_loaded" => ["json"]}, "the tracer loaded modules after it started: json"},
          {%{"late_loaded" => nil}, "the end does not say what the tracer loaded late"}
        ] do
      r = read(dir, replace(clean(), "end", nil, changes))
      assert problem in r.problems, inspect({problem, r.problems})
    end
  end

  test "a broken structure is a problem", %{tmp_dir: dir} do
    drop = fn kind -> Enum.reject(clean(), &(&1["kind"] == kind)) end
    [start, snapshot, closure | rest] = clean()

    for {lines, problem} <- [
          {[], "trace-main.jsonl is empty"},
          {drop.("start"), "no start line"},
          {[start, start, snapshot, closure | rest], "2 start lines"},
          {drop.("closure"), "no closure line"},
          {[start, snapshot, closure, closure | rest], "2 closure lines"},
          {clean() ++ [@ending], "2 end lines"},
          {clean() ++ [%{"kind" => "event", "ts" => 200}], "1 lines after the end line"},
          {drop.("stats"), "no stats line"},
          {replace(clean(), "stats", nil, %{"unjudged" => nil}), "stats has no unjudged count"},
          {Enum.reject(clean(), &(&1["kind"] == "window_close" and &1["app"] == "pkg")),
           "pkg's window was never closed"},
          {clean() ++
             [
               %{
                 "kind" => "window_close",
                 "app" => "zz",
                 "integrity_ok" => true,
                 "delivered" => true,
                 "depth_ok" => true
               }
             ], "zz's window was closed without being opened"},
          {replace(clean(), "window_close", "r3", %{"depth_ok" => false}),
           "r3's window lost its backtrace depth"},
          {replace(clean(), "sentinel", "pkg", %{"depth_ok" => false}),
           "pkg's sentinel lost its backtrace depth"},
          {[start, snapshot, closure] ++
             window("pkg", 10, 20) ++ window("r3", 30, 40) ++ [@stats, @ending],
           "windows [pkg, r3] do not match the closure [r3, pkg]"},
          {[start, snapshot, closure] ++ window("pkg", 30, 40) ++ [@stats, @ending],
           "windows [pkg] do not match the closure [r3, pkg]"},
          {clean() ++ [%{"kind" => "overflow", "what" => "calls"}], "trace overflowed: calls"},
          {clean() ++ [%{"kind" => "quiet_close", "app" => "r3", "ts" => 22, "delivered" => true}],
           "r3's native patterns closed without opening"},
          {clean() ++ [%{"kind" => "quiet_open", "app" => "r3", "ts" => 22}],
           "r3's native patterns were never closed"}
        ] do
      r = read(dir, lines)
      assert problem in r.problems, inspect({problem, r.problems})
    end
  end

  test "without a closure line a broken child trace is still a problem", %{tmp_dir: dir} do
    write(dir, "trace-child-r3-11.jsonl", [child_start("r3"), %{"kind" => "unencodable"}])
    r = read(dir, Enum.reject(clean(), &(&1["kind"] == "closure")))
    assert "child trace of r3: unencodable trace line" in r.problems
  end

  test "a child VM that loaded a different tracer is a problem", %{tmp_dir: dir} do
    for tracer <- [Map.put(@tracer, "ncc_tracer", "FF"), nil] do
      write(dir, "trace-child-r3-11.jsonl", [child_start("r3", tracer), child_sentinel("r3")])
      r = read(dir, clean())
      assert "child trace of r3: loaded a different tracer" in r.problems, inspect(r.problems)
    end
  end

  test "quiet intervals keep their app and delivery", %{tmp_dir: dir} do
    {head, tail} = Enum.split(clean(), -2)

    quiet = [
      %{"kind" => "quiet_open", "app" => "r3", "ts" => 21},
      %{"kind" => "quiet_close", "app" => "r3", "ts" => 22, "delivered" => true}
    ]

    r = read(dir, head ++ quiet ++ tail)
    assert [%{app: "r3", open: 21, close: 22, delivered: true}] = r.quiet
    assert r.problems == []
  end

  test "child traces are read per app; a stray child with no app is kept apart and ignored",
       %{tmp_dir: dir} do
    write(dir, "trace-child-r3-11.jsonl", [
      child_start("r3"),
      child_sentinel("r3"),
      %{"kind" => "compile", "source" => "src/r3.erl", "result" => "ok", "module" => "r3"},
      %{"kind" => "libs", "nif_check" => "ok", "mapped_libs" => ["/l/a.so"]},
      %{"kind" => "event", "ts" => 2, "mfa" => "os:type/0"}
    ])

    write(dir, "trace-child-unknown-12.jsonl", [
      child_start("unknown", nil),
      %{"kind" => "collector_down", "reason" => "killed"}
    ])

    r = read(dir, clean())
    assert r.problems == []

    assert %{
             "r3" => %{
               sentinel?: true,
               compiles: [%{"module" => "r3"}],
               events: [_],
               libs: [%{"mapped_libs" => ["/l/a.so"]}],
               problems: []
             },
             "unknown" => %{problems: ["trace collector died: killed" | _]}
           } = r.children
  end

  test "a broken child trace of a closure app is a problem", %{tmp_dir: dir} do
    for {line, problem} <- [
          {%{"kind" => "collector_down", "reason" => "killed"}, "trace collector died: killed"},
          {%{"kind" => "watcher_down", "reason" => "x"}, "trace watcher died: x"},
          {%{"kind" => "unencodable"}, "unencodable trace line"},
          {%{"kind" => "overflow", "what" => "calls"}, "trace overflowed: calls"},
          {child_sentinel("r3", %{"integrity_ok" => false}),
           "r3's sentinel failed its integrity check"},
          {child_sentinel("r3", %{"depth_ok" => false}),
           "r3's sentinel lost its backtrace depth"},
          {%{"kind" => "mystery"}, "unexpected line kind mystery"}
        ] do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      write(dir, "trace-child-r3-11.jsonl", [
        child_start("r3"),
        child_sentinel("r3"),
        line
      ])

      r = read(dir, clean())
      assert problem in r.children["r3"].problems
      assert "child trace of r3: #{problem}" in r.problems, inspect(r.problems)
    end
  end

  test "every child file of an app needs its own sentinel", %{tmp_dir: dir} do
    write(dir, "trace-child-r3-1.jsonl", [
      child_start("r3"),
      child_sentinel("r3")
    ])

    write(dir, "trace-child-r3-2.jsonl", [child_start("r3")])
    assert %{"r3" => %{sentinel?: false}} = read(dir, clean()).children
  end

  test "a truncated child line is a problem of that child", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "trace-child-r3-1.jsonl"),
      JSON.encode!(child_start("r3")) <> ~s(\n{"kind":"ev)
    )

    r = read(dir, clean())
    assert ["unparsable line 2"] = r.children["r3"].problems
    assert "child trace of r3: unparsable line 2" in r.problems
  end

  describe "the read budget, shared by the main file and every child file" do
    test "a trace within it is read whole and is not over budget", %{tmp_dir: dir} do
      r = read(dir, clean())
      refute r.over_budget
      assert r.problems == []
    end

    test "too many bytes across the files is a problem, never a crash", %{tmp_dir: dir} do
      write(dir, "trace-main.jsonl", clean())
      main = File.stat!(Path.join(dir, "trace-main.jsonl")).size
      write(dir, "trace-child-r3-1.jsonl", [child_start("r3"), child_sentinel("r3")])

      r = Report.read(dir, max_bytes: main + 10)
      assert r.over_budget
      assert Enum.any?(r.problems, &(&1 =~ "read budget")), inspect(r.problems)
      # The child file was not decoded.
      assert r.children == %{}
    end

    test "a main file larger than the budget is not read at all", %{tmp_dir: dir} do
      write(dir, "trace-main.jsonl", clean())
      r = Report.read(dir, max_bytes: 100)
      assert r.over_budget
      assert r.events == [] and r.start == nil
      assert Enum.any?(r.problems, &(&1 =~ "read budget"))
    end

    test "too many lines across the files is a problem", %{tmp_dir: dir} do
      event = %{"kind" => "event", "ts" => 50, "channel" => "env", "mfa" => "os:getenv/1"}

      for i <- 1..5,
          do:
            write(dir, "trace-child-r3-#{i}.jsonl", [
              child_start("r3"),
              child_sentinel("r3"),
              event
            ])

      write(dir, "trace-main.jsonl", clean())
      r = Report.read(dir, max_lines: length(clean()) + 8)
      assert r.over_budget
      assert Enum.any?(r.problems, &(&1 =~ "read budget")), inspect(r.problems)
    end

    test "every child file counts, even an empty one", %{tmp_dir: dir} do
      for i <- 1..20, do: File.write!(Path.join(dir, "trace-child-unknown-#{i}.jsonl"), "")
      write(dir, "trace-main.jsonl", clean())
      assert Report.read(dir, max_lines: length(clean()) + 10).over_budget
      refute Report.read(dir, max_lines: length(clean()) + 21).over_budget
    end
  end

  describe "the config snapshot" do
    test "is read into config_env, oversized values marked", %{tmp_dir: dir} do
      r = read(dir, clean())

      assert r.config_env == %{
               entries: %{
                 {"logger", "level"} => "g2gCZAACb2tkAARpbmZv",
                 {"fx", "big"} => :oversize
               },
               truncated: false
             }

      assert r.problems == []
    end

    test "a truncated snapshot is kept as such for the judge", %{tmp_dir: dir} do
      r = read(dir, replace(clean(), "config_env", nil, %{"truncated" => true}))
      assert %{truncated: true} = r.config_env
      assert r.problems == []
    end

    test "an error line or a malformed entry reads as :error", %{tmp_dir: dir} do
      [start | rest] = without_snapshot()
      r = read(dir, [start, %{"kind" => "config_env", "error" => true} | rest])
      assert r.config_env == :error

      for bad <- [
            %{@snapshot | "entries" => [%{"app" => "fx"}]},
            %{@snapshot | "entries" => [%{"app" => "fx", "key" => "k", "value" => 1}]},
            %{@snapshot | "entries" => [%{"app" => "fx", "key" => "k", "oversize" => false}]},
            %{@snapshot | "entries" => "x"},
            %{@snapshot | "truncated" => nil},
            Map.delete(@snapshot, "entries")
          ] do
        assert read(dir, [start, bad | rest]).config_env == :error, inspect(bad)
      end
    end

    test "a second snapshot is a problem", %{tmp_dir: dir} do
      [start, snapshot | rest] = clean()
      r = read(dir, [start, snapshot, snapshot | rest])
      assert "more than one config snapshot" in r.problems

      # Appended after the end, as code writing to the file itself would.
      r = read(dir, clean() ++ [@snapshot])
      assert "more than one config snapshot" in r.problems
    end

    test "a snapshot after the closure line or a window is a problem", %{tmp_dir: dir} do
      [start, closure | rest] = without_snapshot()
      r = read(dir, [start, closure, @snapshot | rest])
      assert "the config snapshot came after the closure was loaded" in r.problems
      assert r.config_env == nil
    end

    test "a trace without one has none, and that is a problem", %{tmp_dir: dir} do
      r = read(dir, without_snapshot())
      assert r.config_env == nil
      assert r.problems == ["no config snapshot"]
    end
  end

  describe "built lines" do
    @r3_built %{"kind" => "built", "app" => "r3", "digest" => "aa", "files" => 3, "ts" => 21}
    @pkg_built %{
      "kind" => "built",
      "app" => "pkg",
      "digest" => nil,
      "error" => "too_large",
      "ts" => 41
    }

    # After r3's window close (index 5) and after pkg's (before stats, end).
    defp with_built(extra \\ []) do
      clean()
      |> List.insert_at(-3, @pkg_built)
      |> List.insert_at(6, @r3_built)
      |> Kernel.++(extra)
    end

    test "are kept per app", %{tmp_dir: dir} do
      r = read(dir, with_built())
      assert r.problems == []

      assert r.built == %{
               "r3" => %{digest: "aa", files: 3, error: nil},
               "pkg" => %{digest: nil, files: nil, error: "too_large"}
             }
    end

    test "a second line for the same app makes its digest an error", %{tmp_dir: dir} do
      lines = with_built() |> List.insert_at(7, @r3_built)
      r = read(dir, lines)
      assert r.built["r3"] == %{digest: nil, files: nil, error: "duplicate"}
    end

    test "a line that is not right after its own window close is an error", %{tmp_dir: dir} do
      # Inside r3's window, before its close.
      inside = clean() |> List.insert_at(5, @r3_built)
      assert read(dir, inside).built["r3"] == %{digest: nil, files: nil, error: "out_of_order"}

      # After pkg's window opened.
      late = clean() |> List.insert_at(7, @r3_built)
      assert read(dir, late).built["r3"] == %{digest: nil, files: nil, error: "out_of_order"}
    end
  end

  test "a returned line attaches its value to the event with that call id", %{tmp_dir: dir} do
    extra = [
      %{
        "kind" => "event",
        "ts" => 35,
        "channel" => "env",
        "mfa" => "os:getenv/1",
        "arg" => %{"name" => "X"},
        "extent" => "frame",
        "call_id" => 7
      },
      %{
        "kind" => "event",
        "ts" => 36,
        "channel" => "env",
        "mfa" => "os:getenv/1",
        "arg" => %{"name" => "Y"},
        "extent" => "frame",
        "call_id" => 8
      },
      %{"kind" => "returned", "call_id" => 7, "value" => "g3cFZXJyb3I"}
    ]

    {body, tail} = Enum.split(clean(), -2)
    report = read(dir, body ++ extra ++ tail)

    assert [%{"returned" => "g3cFZXJyb3I"}, %{"returned" => nil}] =
             Enum.filter(report.events, &(&1["mfa"] == "os:getenv/1"))

    refute Enum.any?(report.problems, &(&1 =~ "returned"))
  end
end
