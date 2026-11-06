defmodule NccWorker.Tracer.Report do
  @moduledoc """
  Reads what one traced judge compile wrote (`NccWorker.Tracer`):
  `trace-main.jsonl` from the Mix VM and one `trace-child-<app>-<pid>.jsonl`
  per other BEAM the compile started (rebar3). Reading never raises.

  Anything that says the trace cannot be trusted is collected in `problems`,
  which makes the judge refuse to judge (`NccWorker.Portability`):

    * a missing, oversized or unparsable file or line, or a line kind the
      reader does not know;
    * a window close, sentinel or end whose `integrity_ok` is false, a
      window close, end or native-pattern quiet close whose `delivered` is
      false;
    * `stats.unjudged > 0`, any `unencodable` line, a `collector_down` or
      `watcher_down` line;
    * any of the above in the child trace of an app in the closure line.

  A missing `end` line leaves `ending` nil, a refused start fills
  `refused_start`, and `overflow` lines and the `end` line's `depth_ok`,
  `status` and `final_sentinel` are left to the judge, which checks them.
  A child file whose app is not in the closure (a stray `erl -eval` sub-VM
  of elixir_make, whose app is `unknown`) is kept in `children` under its
  app and adds no problem: the judge reads children only for closure apps.
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
    main =
      dir
      |> Path.join("trace-main.jsonl")
      |> read_lines()
      |> Enum.reduce(%__MODULE__{}, &main_line/2)

    children =
      dir
      |> Path.join("trace-child-*.jsonl")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.reduce(%{}, &child_file/2)

    finalize(%{main | children: children})
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
  defp main_line({:line, %{"kind" => "start"} = l}, r), do: %{r | start: l}
  defp main_line({:line, %{"kind" => "closure"} = l}, r), do: %{r | closure: l}

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
    %{r | quiet: close_quiet(r.quiet, l)}
    |> check(l, "delivered", "#{l["app"]}'s native patterns were not fully delivered")
  end

  defp main_line({:line, %{"kind" => "sentinel"} = l}, r) do
    sentinel = %{app: l["app"], ts: l["ts"], integrity_ok: l["integrity_ok"]}

    %{r | sentinels: [sentinel | r.sentinels]}
    |> check(l, "integrity_ok", "#{l["app"]}'s sentinel failed its integrity check")
  end

  defp main_line({:line, %{"kind" => "event"} = l}, r), do: %{r | events: [l | r.events]}
  defp main_line({:line, %{"kind" => "stats"} = l}, r), do: %{r | stats: l}

  defp main_line({:line, %{"kind" => "end"} = l}, r) do
    %{r | ending: l}
    |> check(l, "integrity_ok", "the end failed its integrity check")
    |> check(l, "delivered", "the end was not fully delivered")
  end

  defp main_line({:line, %{"kind" => "overflow"} = l}, r), do: %{r | overflow: [l | r.overflow]}
  defp main_line({:line, %{"kind" => "refused_start"} = l}, r), do: %{r | refused_start: l}

  defp main_line({:line, l}, r) do
    case common_problem(l) do
      nil -> problem(r, "unexpected line kind #{l["kind"]}")
      why -> problem(r, why)
    end
  end

  # The kinds either file can carry that only ever mean a broken trace.
  defp common_problem(%{"kind" => "unencodable"}), do: "unencodable trace line"

  defp common_problem(%{"kind" => "collector_down"} = l),
    do: "trace collector died: #{reason(l)}"

  defp common_problem(%{"kind" => "watcher_down"} = l), do: "trace watcher died: #{reason(l)}"
  defp common_problem(_line), do: nil

  defp reason(%{"reason" => reason}) when is_binary(reason), do: reason
  defp reason(l), do: inspect(l["reason"])

  # A check the tracer wrote is passed only by an explicit `true`.
  defp check(r, line, key, why) do
    if line[key] == true, do: r, else: problem(r, why)
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
      depth_ok: false,
      integrity_ok: l["integrity_ok"],
      delivered: l["delivered"]
    }

    [stray | windows]
  end

  defp close_quiet([%{close: nil} = q | rest], l),
    do: [%{q | close: l["ts"], delivered: l["delivered"]} | rest]

  defp close_quiet(quiet, _l), do: quiet

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
  defp child_line({:line, %{"kind" => "start"} = l}, c), do: %{c | start: l}

  defp child_line({:line, %{"kind" => "sentinel"} = l}, c) do
    if l["integrity_ok"] == true,
      do: %{c | sentinel?: true},
      else: child_problem(c, "#{l["app"]}'s sentinel failed its integrity check")
  end

  defp child_line({:line, %{"kind" => "compile"} = l}, c), do: %{c | compiles: [l | c.compiles]}
  defp child_line({:line, %{"kind" => "event"} = l}, c), do: %{c | events: [l | c.events]}

  defp child_line({:line, %{"kind" => "overflow"} = l}, c),
    do: child_problem(c, "trace overflowed: #{l["what"]}")

  defp child_line({:line, l}, c) do
    case common_problem(l) do
      nil -> c
      why -> child_problem(c, why)
    end
  end

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

  defp finalize(r) do
    r = %{
      r
      | windows: Enum.reverse(r.windows),
        quiet: Enum.reverse(r.quiet),
        sentinels: Enum.reverse(r.sentinels),
        events: r.events |> Enum.reverse() |> Enum.sort_by(&(&1["ts"] || 0)),
        overflow: Enum.reverse(r.overflow),
        children: Map.new(r.children, fn {app, c} -> {app, finish_child(c)} end),
        problems: Enum.reverse(r.problems)
    }

    %{r | problems: r.problems ++ unjudged(r.stats) ++ child_problems(r)}
  end

  defp finish_child(c),
    do: %{c | compiles: Enum.reverse(c.compiles), events: Enum.reverse(c.events)}

  defp unjudged(%{"unjudged" => n}) when is_integer(n) and n > 0,
    do: ["#{n} unjudged trace events"]

  defp unjudged(_stats), do: []

  defp child_problems(%__MODULE__{closure: closure, children: children}) do
    apps = closure_apps(closure)

    for {app, child} <- Enum.sort(children),
        MapSet.member?(apps, app),
        why <- child.problems,
        do: "child trace of #{app}: #{why}"
  end

  defp closure_apps(%{"deps" => deps}) when is_list(deps),
    do: MapSet.new(for %{"app" => app} <- deps, do: app)

  defp closure_apps(_closure), do: MapSet.new()
end
