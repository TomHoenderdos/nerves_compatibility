defmodule Portal.Catalog.BuildTimeout do
  @moduledoc """
  Records a build that ran past the wall clock (`Portal.Builder`'s
  `{:build_timeout, seconds, container}`) as an ordinary catalog run.

  A package that cannot finish inside the limit never will, so retrying it
  only spent three times the limit per release and recorded nothing, and the
  site kept showing the previous version's result. `Portal.Workers.Build`
  calls `record/1` instead, once, and the run is final.

  The container wrote no `result.json`, so the result is synthesized from
  what it left in `out/logs`, the way `Portal.Catalog.ToolingSkip` builds
  one, and goes through `Portal.Catalog.Ingestion`:

    * The run's `log` says the build exceeded the limit.
    * A full run's `overall_status` is `error` (`forced_status`), and every
      system it would have built gets a `SystemResult`. One with a
      `<system>.log` was reached: `error`, category `"Build timeout"`
      (`Portal.Catalog.FailureClassifier` matches `message/1`). One without
      was not: `skipped`.
    * A targets run records only the targets it reached. The rest, with the
      previous run's footprint and argus result, carry from the previous run
      of the version as for any partial run, and `overall_status` is derived
      from both. A target it never reached keeps its real result.
    * An argus-only run builds no target, so it is not recorded here at all
      (`Portal.Workers.Build`).
    * The package keeps its stored description and native components.
    * The newest log, `host.log` included, is the phase that was running when
      the limit hit. When it is a target's, that log is stored as its
      `SystemLog`, with the usual size limits. The other targets it reached
      finished their builds, but their results never left the container.
  """

  require Ash.Query

  alias Portal.Catalog.{Ingestion, Package, ToolingSkip}

  @category "Build timeout"

  @type attrs :: %{
          required(:package) => String.t(),
          required(:version) => String.t(),
          required(:run_id) => String.t(),
          required(:image_digest) => String.t(),
          required(:seconds) => non_neg_integer(),
          required(:started_at) => DateTime.t(),
          required(:finished_at) => DateTime.t(),
          required(:output_dir) => Path.t(),
          # The systems the run would have built, in build order.
          required(:systems) => [String.t()],
          # "targets" for a targets run (see `Portal.Catalog.Ingestion`'s
          # carry), nil for a full one. Argus only is never recorded.
          required(:scope) => String.t() | nil,
          optional(:scan_request_id) => String.t() | nil,
          optional(:arch) => String.t() | nil,
          # Appended to the run's log: the runner log's excerpt.
          optional(:runner_excerpt) => String.t() | nil
        }

  @doc "The failure category a reached system records."
  @spec category() :: String.t()
  def category, do: @category

  @doc "What the run's log and every reached system say."
  @spec message(non_neg_integer()) :: String.t()
  def message(seconds),
    do: "Build exceeded the #{seconds}s wall-clock limit and was stopped."

  @doc "Records the timed-out run. Reads `output_dir`, never removes it."
  @spec record(attrs()) :: {:ok, Portal.Catalog.Run.t()} | {:error, term()}
  def record(attrs) do
    message = message(attrs.seconds)
    logs_dir = Path.join(attrs.output_dir, "logs")
    systems = Enum.reject(attrs.systems, &unsafe_name?/1)
    mtimes = log_mtimes(logs_dir, ["host" | systems])
    reached = Enum.filter(systems, &Map.has_key?(mtimes, &1))

    result =
      %{
        "package" => %{
          "name" => attrs.package,
          "version" => attrs.version,
          # The package upsert overwrites both; a timeout learned neither.
          "description" => ToolingSkip.stored_description(attrs.package),
          "native_components" => stored_native_components(attrs.package)
        },
        "started_at" => DateTime.to_iso8601(attrs.started_at),
        "finished_at" => DateTime.to_iso8601(attrs.finished_at)
      }
      |> put_systems(attrs.scope, systems, reached, message)

    with {:ok, run} <-
           Ingestion.ingest(result, %{
             run_id: attrs.run_id,
             image_digest: attrs.image_digest,
             # No scans, so no blobs: the files dir is never read.
             files_dir: System.tmp_dir!(),
             output_dir: attrs.output_dir,
             log_systems: List.wrap(cut_off(mtimes, ["host" | systems], reached)),
             log: run_log(message, Map.get(attrs, :runner_excerpt)),
             scan_request_id: Map.get(attrs, :scan_request_id),
             arch: Map.get(attrs, :arch),
             package: attrs.package,
             version: attrs.version
           }) do
      ToolingSkip.enqueue_package_meta(attrs.package)
      {:ok, run}
    end
  end

  defp system(true, message),
    do: %{"status" => "error", "error" => message, "log_tail" => message}

  defp system(false, _message),
    do: %{
      "status" => "skipped",
      "log_tail" => "Not reached before the build hit the wall-clock limit."
    }

  # A targets run names only what it reached, so `Portal.Catalog.Ingestion`
  # carries the rest from the previous run of the version and derives the
  # status from both. A full run has nothing to carry from: every target it
  # would have built is on the record, and the run is an error.
  defp put_systems(result, "targets", _systems, reached, message) do
    result
    |> Map.put("scope", "targets")
    # The carried run's footprint and argus result stand: this run measured
    # and analysed nothing.
    |> Map.put("carry_run_data", true)
    |> Map.put("systems", Map.new(reached, &{&1, system(true, message)}))
  end

  defp put_systems(result, _scope, systems, reached, message) do
    result
    |> Map.put("forced_status", "error")
    |> Map.put("systems", Map.new(systems, &{&1, system(&1 in reached, message)}))
  end

  defp stored_native_components(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.select([:native_components])
    |> Ash.read_one(domain: Portal.Catalog)
    |> case do
      {:ok, %{native_components: native_components}} -> native_components
      _ -> nil
    end
  end

  defp run_log(message, excerpt) when is_binary(excerpt) and excerpt != "",
    do: message <> "\n\n" <> excerpt

  defp run_log(message, _excerpt), do: message

  # The newest log is the phase the limit cut off. Seconds can tie, and the
  # worker runs the host phase first and the targets in list order, so a tie
  # goes to the later one. Nil when that phase is not a target.
  defp cut_off(mtimes, order, reached) do
    newest =
      order
      |> Enum.with_index()
      |> Enum.filter(fn {name, _index} -> Map.has_key?(mtimes, name) end)
      |> Enum.max_by(fn {name, index} -> {mtimes[name], index} end, fn -> nil end)

    case newest do
      {name, _index} -> if name in reached, do: name
      nil -> nil
    end
  end

  # /out is written by a container running package code, so only a regular
  # file counts; `Portal.Catalog.LogSanitizer` checks the file it reads again.
  # Names come from the job, never the container.
  # sobelow_skip ["Traversal.FileModule"]
  defp log_mtimes(logs_dir, names) do
    Enum.reduce(names, %{}, fn name, acc ->
      case File.lstat(Path.join(logs_dir, "#{name}.log"), time: :posix) do
        {:ok, %File.Stat{type: :regular, mtime: mtime}} -> Map.put(acc, name, mtime)
        _ -> acc
      end
    end)
  end

  defp unsafe_name?(name),
    do: not is_binary(name) or String.contains?(name, ["/", "\\", ".."])
end
