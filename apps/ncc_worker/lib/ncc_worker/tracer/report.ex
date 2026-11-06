defmodule NccWorker.Tracer.Report do
  @moduledoc """
  Reads what one traced judge compile wrote (`NccWorker.Tracer`):
  `trace-main.jsonl` from the Mix VM and one `trace-child-<app>-<pid>.jsonl`
  per other BEAM the compile started (rebar3). Reading never raises.

  Anything that says the trace cannot be trusted is collected in `problems`,
  and any problem makes the judge refuse to judge (`NccWorker.Portability`).
  A check the tracer wrote passes only with an explicit `true`. Problems:

    * a missing, oversized, empty or unparsable file or line, a line kind
      the reader does not know;
    * not exactly one `start`, one `closure` and one `end` line, any line
      after the `end`, no `stats` line or one without an integer
      `unjudged`, `unjudged > 0`;
    * an `end` whose status is not `"ok"`, or whose `final_sentinel`,
      `depth_ok`, `integrity_ok` or `delivered` is not true, or whose
      `overflow` is not false; any `overflow` line;
    * a window or native-pattern quiet interval left open or closed without
      being opened, a window close whose `depth_ok`, `integrity_ok` or
      `delivered` is not true, a sentinel whose `depth_ok` or `integrity_ok`
      is not true, a quiet close whose `delivered` is not true;
    * windows that are not exactly the closure's dependencies, in its order;
    * any `unencodable`, `collector_down` or `watcher_down` line;
    * in the child trace of a closure app (of any app but `unknown` when
      the closure line is missing): any of the line-level problems above,
      and a child VM whose tracer modules (`start.tracer`, their md5s) are
      not the ones the Mix VM loaded.

  A child file of an app outside the closure (a stray `erl -eval` sub-VM of
  elixir_make, whose app is `unknown`) is kept in `children` under its app
  and adds no problem: the judge reads children only for closure apps.
  """

  @max_bytes 512 * 1024 * 1024

  defstruct start: nil,
            closure: nil,
            windows: [],
            quiet: [],
            sentinels: [],
            events: [],
            stats: nil,
            ending: nil,
            overflow: [],
            refused_start: nil,
            children: %{},
            problems: []

  @type window :: %{
          app: String.t() | nil,
          open: integer() | nil,
          close: integer() | nil,
          depth_ok: boolean() | nil,
          integrity_ok: boolean() | nil,
          delivered: boolean() | nil
        }

  @type child :: %{
          start: map() | nil,
          sentinel?: boolean(),
          compiles: [map()],
          events: [map()],
          problems: [String.t()]
        }

  @type t :: %__MODULE__{
          start: map() | nil,
          closure: map() | nil,
          windows: [window()],
          quiet: [%{app: String.t() | nil, open: integer() | nil, close: integer() | nil}],
          sentinels: [%{app: String.t() | nil, ts: integer() | nil}],
          events: [map()],
          stats: map() | nil,
          ending: map() | nil,
          overflow: [map()],
          refused_start: map() | nil,
          children: %{String.t() => child()},
          problems: [String.t()]
        }

  @spec read(String.t()) :: t()
  def read(dir) do
    items = dir |> Path.join("trace-main.jsonl") |> read_lines()
    main = Enum.reduce(items, %__MODULE__{}, &main_line/2)

    children =
      dir
      |> Path.join("trace-child-*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{}, &child_file/2)

    finalize(%{main | children: children}, items)
  end

  # Files the traced compile wrote into the worker's own run dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_lines(path) do
    case File.stat(path) do
      {:ok, %{size: size}} when size > @max_bytes ->
        [{:problem, "#{Path.basename(path)} is larger than #{@max_bytes} bytes"}]

      {:ok, _stat} ->
        path |> File.stream!() |> Stream.with_index(1) |> Enum.map(&decode/1)

      {:error, _reason} ->
        [{:problem, "#{Path.basename(path)} missing"}]
    end
  rescue
    e -> [{:problem, "#{Path.basename(path)} unreadable: #{Exception.message(e)}"}]
  end

  defp decode({line, n}) do
    case JSON.decode(line) do
      {:ok, %{"kind" => kind} = map} when is_binary(kind) -> {:line, map}
      _ -> {:problem, "unparsable line #{n}"}
    end
  end

  # --- trace-main.jsonl ------------------------------------------------------

  defp main_line({:problem, why}, r), do: problem(r, why)
  defp main_line({:line, %{"kind" => "start"} = l}, r), do: %{r | start: r.start || l}
  defp main_line({:line, %{"kind" => "closure"} = l}, r), do: %{r | closure: r.closure || l}

  defp main_line({:line, %{"kind" => "window_open"} = l}, r) do
    window = %{
      app: l["app"],
      open: l["ts"],
      close: nil,
      depth_ok: nil,
      integrity_ok: nil,
      delivered: nil
    }

    %{r | windows: [window | r.windows]}
  end

  defp main_line({:line, %{"kind" => "window_close"} = l}, r) do
    %{r | windows: close_window(r.windows, l)}
    |> check(l, "integrity_ok", "#{l["app"]}'s window failed its integrity check")
    |> check(l, "delivered", "#{l["app"]}'s window was not fully delivered")
  end

  defp main_line({:line, %{"kind" => "quiet_open"} = l}, r),
    do: %{r | quiet: [%{app: l["app"], open: l["ts"], close: nil, delivered: nil} | r.quiet]}

  defp main_line({:line, %{"kind" => "quiet_close"} = l}, r) do
    r
    |> close_quiet(l)
    |> check(l, "delivered", "#{l["app"]}'s native patterns were not fully delivered")
  end

  defp main_line({:line, %{"kind" => "sentinel"} = l}, r) do
    sentinel = %{app: l["app"], ts: l["ts"], integrity_ok: l["integrity_ok"]}
    %{r | sentinels: [sentinel | r.sentinels]} |> sentinel_checks(l, &problem/2)
  end

  defp main_line({:line, %{"kind" => "event"} = l}, r), do: %{r | events: [l | r.events]}
  defp main_line({:line, %{"kind" => "stats"} = l}, r), do: %{r | stats: r.stats || l}

  defp main_line({:line, %{"kind" => "end"} = l}, r) do
    %{r | ending: r.ending || l}
    |> check(l, "integrity_ok", "the end failed its integrity check")
    |> check(l, "delivered", "the end was not fully delivered")
    |> check(l, "depth_ok", "the end lost its backtrace depth")
    |> check(l, "final_sentinel", "final sentinel missing")
    |> ending_status(l)
  end

  defp main_line({:line, %{"kind" => "overflow"} = l}, r),
    do: problem(%{r | overflow: [l | r.overflow]}, "trace overflowed: #{l["what"]}")

  defp main_line({:line, %{"kind" => "refused_start"} = l}, r), do: %{r | refused_start: l}

  defp main_line({:line, l}, r), do: problem(r, other_problem(l))

  defp ending_status(r, %{"status" => "ok", "overflow" => false}), do: r

  defp ending_status(r, %{"status" => "ok"}), do: problem(r, "the end reports an overflow")

  defp ending_status(r, l),
    do: problem(r, "traced compile ended #{inspect(l["status"])}")

  defp sentinel_checks(acc, l, add) do
    acc
    |> pass_or(l, "integrity_ok", "#{l["app"]}'s sentinel failed its integrity check", add)
    |> pass_or(l, "depth_ok", "#{l["app"]}'s sentinel lost its backtrace depth", add)
  end

  # The kinds either file can carry that only ever mean a broken trace, and
  # any kind the reader does not know.
  defp other_problem(%{"kind" => "unencodable"}), do: "unencodable trace line"
  defp other_problem(%{"kind" => "collector_down"} = l), do: "trace collector died: #{reason(l)}"
  defp other_problem(%{"kind" => "watcher_down"} = l), do: "trace watcher died: #{reason(l)}"
  defp other_problem(l), do: "unexpected line kind #{l["kind"]}"

  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(l), do: inspect(l["reason"])

  # A check the tracer wrote is passed only by an explicit `true`.
  defp check(r, line, key, why), do: pass_or(r, line, key, why, &problem/2)

  defp pass_or(acc, line, key, why, add) do
    if line[key] == true, do: acc, else: add.(acc, why)
  end

  defp problem(r, why), do: %{r | problems: [why | r.problems]}

  defp close_window([%{app: app, close: nil} = w | rest], %{"app" => app} = l) do
    closed = %{
      w
      | close: l["ts"],
        depth_ok: l["depth_ok"],
        integrity_ok: l["integrity_ok"],
        delivered: l["delivered"]
    }

    [closed | rest]
  end

  defp close_window(windows, l) do
    stray = %{
      app: l["app"],
      open: nil,
      close: l["ts"],
      depth_ok: l["depth_ok"],
      integrity_ok: l["integrity_ok"],
      delivered: l["delivered"]
    }

    [stray | windows]
  end

  defp close_quiet(%{quiet: [%{close: nil} = q | rest]} = r, l),
    do: %{r | quiet: [%{q | close: l["ts"], delivered: l["delivered"]} | rest]}

  defp close_quiet(r, l),
    do: problem(r, "#{l["app"]}'s native patterns closed without opening")

  # --- trace-child-<app>-<pid>.jsonl ------------------------------------------

  defp child_file(path, acc) do
    child =
      path
      |> read_lines()
      |> Enum.reduce(
        %{start: nil, sentinel?: false, compiles: [], events: [], problems: []},
        &child_line/2
      )

    app = (child.start && child.start["app"]) || file_app(path)
    child = %{child | problems: Enum.reverse(child.problems)}
    Map.update(acc, app, child, &merge_child(&1, child))
  end

  # The app the file name carries, for a file whose start line is lost.
  defp file_app(path) do
    case Regex.run(~r/^trace-child-(.+)-\d+\.jsonl$/, Path.basename(path)) do
      [_, app] -> app
      nil -> "unknown"
    end
  end

  defp child_line({:problem, why}, c), do: child_problem(c, why)
  defp child_line({:line, %{"kind" => "start"} = l}, c), do: %{c | start: c.start || l}

  defp child_line({:line, %{"kind" => "sentinel"} = l}, c) do
    checked = sentinel_checks(c, l, &child_problem/2)
    if checked == c, do: %{c | sentinel?: true}, else: checked
  end

  defp child_line({:line, %{"kind" => "compile"} = l}, c), do: %{c | compiles: [l | c.compiles]}
  defp child_line({:line, %{"kind" => "event"} = l}, c), do: %{c | events: [l | c.events]}

  defp child_line({:line, %{"kind" => "overflow"} = l}, c),
    do: child_problem(c, "trace overflowed: #{l["what"]}")

  defp child_line({:line, l}, c), do: child_problem(c, other_problem(l))

  defp child_problem(c, why), do: %{c | problems: [why | c.problems]}

  # Every file of the app must have its own sentinel.
  defp merge_child(a, b) do
    %{
      start: a.start || b.start,
      sentinel?: a.sentinel? and b.sentinel?,
      compiles: a.compiles ++ b.compiles,
      events: a.events ++ b.events,
      problems: a.problems ++ b.problems
    }
  end

  # --- both --------------------------------------------------------------------

  defp finalize(r, items) do
    r = %{
      r
      | windows: Enum.reverse(r.windows),
        quiet: Enum.reverse(r.quiet),
        sentinels: Enum.reverse(r.sentinels),
        events: r.events |> Enum.reverse() |> Enum.sort_by(&(&1["ts"] || 0)),
        overflow: Enum.reverse(r.overflow),
        problems: Enum.reverse(r.problems)
    }

    tracer = r.start && r.start["tracer"]
    r = %{r | children: Map.new(r.children, fn {app, c} -> {app, finish_child(c, tracer)} end)}

    structural =
      shape(items) ++ stats(r.stats) ++ windows(r) ++ order(r) ++ open_quiet(r.quiet)

    %{r | problems: r.problems ++ structural ++ child_problems(r)}
  end

  defp finish_child(c, tracer) do
    c = %{c | compiles: Enum.reverse(c.compiles), events: Enum.reverse(c.events)}
    child_tracer = c.start && c.start["tracer"]

    if tracer != nil and child_tracer == tracer,
      do: c,
      else: %{c | problems: c.problems ++ ["loaded a different tracer"]}
  end

  defp shape([]), do: ["trace-main.jsonl is empty"]

  defp shape(items) do
    kinds = for {:line, %{"kind" => kind}} <- items, do: kind

    after_end =
      items
      |> Enum.drop_while(&(not match?({:line, %{"kind" => "end"}}, &1)))
      |> Enum.drop(1)
      |> length()

    Enum.flat_map(["start", "closure", "end"], &once(kinds, &1)) ++
      if(after_end > 0, do: ["#{after_end} lines after the end line"], else: [])
  end

  defp once(kinds, kind) do
    case Enum.count(kinds, &(&1 == kind)) do
      1 -> []
      0 -> ["no #{kind} line"]
      n -> ["#{n} #{kind} lines"]
    end
  end

  defp stats(nil), do: ["no stats line"]
  defp stats(%{"unjudged" => 0}), do: []
  defp stats(%{"unjudged" => n}) when is_integer(n), do: ["#{n} unjudged trace events"]
  defp stats(_stats), do: ["stats has no unjudged count"]

  defp windows(r), do: Enum.flat_map(r.windows, &window_problems/1)

  defp window_problems(%{open: nil} = w),
    do: ["#{w.app}'s window was closed without being opened"]

  defp window_problems(%{close: nil} = w), do: ["#{w.app}'s window was never closed"]
  defp window_problems(%{depth_ok: true}), do: []
  defp window_problems(w), do: ["#{w.app}'s window lost its backtrace depth"]

  # One window per closure dependency, in the closure's (Mix's) order.
  defp order(%{closure: %{"deps" => deps}, windows: windows}) when is_list(deps) do
    expected = for dep <- deps, do: dep["app"]
    actual = Enum.map(windows, & &1.app)

    if actual == expected,
      do: [],
      else: ["windows #{list(actual)} do not match the closure #{list(expected)}"]
  end

  defp order(_r), do: []

  defp list(apps), do: "[" <> Enum.map_join(apps, ", ", &to_string/1) <> "]"

  defp open_quiet(quiet) do
    for %{close: nil} = q <- quiet, do: "#{q.app}'s native patterns were never closed"
  end

  defp child_problems(%__MODULE__{closure: closure, children: children}) do
    for {app, child} <- Enum.sort(children),
        judged_child?(closure, app),
        why <- child.problems,
        do: "child trace of #{app}: #{why}"
  end

  # Without a closure line every child but the stray `unknown` ones counts.
  defp judged_child?(%{"deps" => deps}, app) when is_list(deps),
    do: Enum.any?(deps, &(&1["app"] == app))

  defp judged_child?(_closure, app), do: app != "unknown"
end
