defmodule NccWorker.Resources do
  @moduledoc """
  Samples the container's guest memory while a run is in progress.

  Inside gVisor `/proc/meminfo` describes the sandbox, and its `MemTotal` is
  the container's `--memory`. Every `interval_ms` the sampler reads it and
  keeps the peaks of

    * used: `MemTotal - MemFree - Buffers - Cached`, what the run's processes hold
    * total: `MemTotal - MemFree`, the same plus the page cache

  in bytes, with `MemTotal` as `limit_bytes`. After every sample it writes
  `<output_dir>/resources.json` atomically, so a run the kernel OOM-kills,
  which never writes `result.json`, still leaves its last record behind.
  `stop/1` takes a final sample and returns the same map, which the worker
  puts into `result.json` as `resources`.

  A meminfo that cannot be read or parsed (a macOS host has none) is counted
  in `read_errors` and never raises. Until a sample succeeds the peaks,
  `limit_bytes` and `sampled_at` are nil.
  """

  use GenServer, restart: :temporary

  @default_meminfo_path "/proc/meminfo"
  @default_interval_ms 5_000

  @fields %{
    "MemTotal" => :mem_total,
    "MemFree" => :mem_free,
    "Buffers" => :buffers,
    "Cached" => :cached
  }

  @type report :: %{
          peak_used_bytes: non_neg_integer() | nil,
          peak_total_bytes: non_neg_integer() | nil,
          limit_bytes: non_neg_integer() | nil,
          samples: non_neg_integer(),
          read_errors: non_neg_integer(),
          interval_ms: pos_integer(),
          started_at: String.t(),
          sampled_at: String.t() | nil
        }

  @doc """
  Starts the sampler and takes its first sample. Options: `output_dir`
  (required, the run's `/out`), `meminfo_path` (default `"/proc/meminfo"`)
  and `interval_ms` (default 5000).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc "Takes a last sample, writes `resources.json`, stops, and returns the report."
  @spec stop(GenServer.server()) :: report()
  def stop(server), do: GenServer.call(server, :stop, :infinity)

  @doc """
  The four `/proc/meminfo` fields the sampler uses, in kB, or `:error` when
  any is missing or not a number.
  """
  @spec parse(String.t()) ::
          {:ok,
           %{
             mem_total: non_neg_integer(),
             mem_free: non_neg_integer(),
             buffers: non_neg_integer(),
             cached: non_neg_integer()
           }}
          | :error
  def parse(content) do
    found =
      content
      |> String.split("\n")
      |> Enum.reduce(%{}, fn line, acc ->
        with [name, rest] <- String.split(line, ":", parts: 2),
             {:ok, key} <- Map.fetch(@fields, name),
             {kb, " kB"} <- rest |> String.trim_leading() |> Integer.parse() do
          Map.put(acc, key, kb)
        else
          _ -> acc
        end
      end)

    if map_size(found) == map_size(@fields), do: {:ok, found}, else: :error
  end

  @impl true
  def init(opts) do
    state = %{
      meminfo_path: Keyword.get(opts, :meminfo_path, @default_meminfo_path),
      output_dir: Keyword.fetch!(opts, :output_dir),
      report: %{
        peak_used_bytes: nil,
        peak_total_bytes: nil,
        limit_bytes: nil,
        samples: 0,
        read_errors: 0,
        interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
        started_at: now(),
        sampled_at: nil
      }
    }

    {:ok, sample(state), {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state), do: {:noreply, schedule(state)}

  @impl true
  def handle_info(:tick, state), do: {:noreply, state |> sample() |> schedule()}

  @impl true
  def handle_call(:stop, _from, state) do
    state = sample(state)
    {:stop, :normal, state.report, state}
  end

  defp schedule(state) do
    Process.send_after(self(), :tick, state.report.interval_ms)
    state
  end

  defp sample(state) do
    report =
      case read(state.meminfo_path) do
        {:ok, kb} -> record(state.report, kb)
        :error -> Map.update!(state.report, :read_errors, &(&1 + 1))
      end

    write(state.output_dir, report)
    %{state | report: report}
  end

  # meminfo_path is /proc/meminfo, or a test fixture.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path) do
    case File.read(path) do
      {:ok, content} -> parse(content)
      {:error, _} -> :error
    end
  end

  defp record(report, kb) do
    used = (kb.mem_total - kb.mem_free - kb.buffers - kb.cached) * 1024
    total = (kb.mem_total - kb.mem_free) * 1024

    %{
      report
      | peak_used_bytes: max(report.peak_used_bytes || 0, used),
        peak_total_bytes: max(report.peak_total_bytes || 0, total),
        limit_bytes: kb.mem_total * 1024,
        samples: report.samples + 1,
        sampled_at: now()
    }
  end

  # output_dir is the run's /out mount; the file names are fixed. A failed
  # write is not retried: the next sample writes the file again.
  # sobelow_skip ["Traversal.FileModule"]
  defp write(output_dir, report) do
    file = Path.join(output_dir, "resources.json")
    temp = file <> ".tmp"

    with :ok <- File.write(temp, JSON.encode_to_iodata!(report)) do
      File.rename(temp, file)
    end
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
