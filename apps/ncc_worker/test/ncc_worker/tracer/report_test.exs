defmodule NccWorker.Tracer.ReportTest do
  use ExUnit.Case, async: true

  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @start %{"kind" => "start", "role" => "main", "app" => "main", "ts" => 1}
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
    "overflow" => false
  }

  defp clean,
    do: [@start, @closure] ++ window("r3", 10, 20) ++ window("pkg", 30, 40) ++ [@stats, @ending]

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

  test "a missing end line leaves ending nil", %{tmp_dir: dir} do
    r = read(dir, Enum.reject(clean(), &(&1["kind"] == "end")))
    assert r.ending == nil
  end

  test "quiet intervals keep their app and delivery", %{tmp_dir: dir} do
    r =
      read(
        dir,
        clean() ++
          [
            %{"kind" => "quiet_open", "app" => "r3", "ts" => 21},
            %{"kind" => "quiet_close", "app" => "r3", "ts" => 22, "delivered" => true}
          ]
      )

    assert [%{app: "r3", open: 21, close: 22, delivered: true}] = r.quiet
    assert r.problems == []
  end

  test "child traces are read per app; a stray child with no app is kept apart and ignored",
       %{tmp_dir: dir} do
    write(dir, "trace-child-r3-11.jsonl", [
      %{"kind" => "start", "role" => "child", "app" => "r3"},
      %{"kind" => "sentinel", "app" => "r3", "ts" => 1, "integrity_ok" => true},
      %{"kind" => "compile", "source" => "src/r3.erl", "result" => "ok", "module" => "r3"},
      %{"kind" => "event", "ts" => 2, "mfa" => "os:type/0"}
    ])

    write(dir, "trace-child-unknown-12.jsonl", [
      %{"kind" => "start", "role" => "child", "app" => "unknown"},
      %{"kind" => "collector_down", "reason" => "killed"}
    ])

    r = read(dir, clean())
    assert r.problems == []

    assert %{
             "r3" => %{
               sentinel?: true,
               compiles: [%{"module" => "r3"}],
               events: [_],
               problems: []
             },
             "unknown" => %{problems: ["trace collector died: killed"]}
           } = r.children
  end

  test "a broken child trace of a closure app is a problem", %{tmp_dir: dir} do
    for {line, problem} <- [
          {%{"kind" => "collector_down", "reason" => "killed"}, "trace collector died: killed"},
          {%{"kind" => "watcher_down", "reason" => "x"}, "trace watcher died: x"},
          {%{"kind" => "unencodable"}, "unencodable trace line"},
          {%{"kind" => "overflow", "what" => "calls"}, "trace overflowed: calls"},
          {%{"kind" => "sentinel", "app" => "r3", "integrity_ok" => false},
           "r3's sentinel failed its integrity check"}
        ] do
      File.rm_rf!(dir)
      File.mkdir_p!(dir)

      write(dir, "trace-child-r3-11.jsonl", [
        %{"kind" => "start", "role" => "child", "app" => "r3"},
        %{"kind" => "sentinel", "app" => "r3", "ts" => 1, "integrity_ok" => true},
        line
      ])

      r = read(dir, clean())
      assert problem in r.children["r3"].problems
      assert "child trace of r3: #{problem}" in r.problems, inspect(r.problems)
    end
  end

  test "every child file of an app needs its own sentinel", %{tmp_dir: dir} do
    write(dir, "trace-child-r3-1.jsonl", [
      %{"kind" => "start", "app" => "r3"},
      %{"kind" => "sentinel", "app" => "r3", "integrity_ok" => true}
    ])

    write(dir, "trace-child-r3-2.jsonl", [%{"kind" => "start", "app" => "r3"}])
    assert %{"r3" => %{sentinel?: false}} = read(dir, clean()).children
  end

  test "a truncated child line is a problem of that child", %{tmp_dir: dir} do
    File.write!(
      Path.join(dir, "trace-child-r3-1.jsonl"),
      ~s({"kind":"start","app":"r3"}\n{"kind":"ev)
    )

    r = read(dir, clean())
    assert ["unparsable line 2"] = r.children["r3"].problems
    assert "child trace of r3: unparsable line 2" in r.problems
  end
end
