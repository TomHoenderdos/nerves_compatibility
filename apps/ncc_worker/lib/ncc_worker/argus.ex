defmodule NccWorker.Argus do
  @moduledoc """
  Runs argus_beam's escript over the package's host-compiled beams and returns
  its findings for `result.json`.

  Advisory: nothing here changes a system's status or the worker's exit code.
  Every failure, including a missing escript or engine, becomes an `:error`
  result with a short reason.
  """

  @bin "/home/nerves/.mix/escripts/argus"
  # Filled at image build (apps/ncc_worker/Dockerfile); see `seed_flowlog/2`.
  @flowlog_seed "/opt/argus-flowlog"
  @max_findings 200
  @max_reason 500
  @default_timeout_seconds 300
  @default_analyses ["default", "exposure"]

  # The generated wrapper application, from `Project.new_project/2`. It is
  # rewritten for every package and is not the package under analysis.
  @wrapper_app "nerves_compatibility_test"

  # stderr goes to a file so stdout stays the JSON document argus prints.
  # `timeout` exits 124 on expiry and 137 when it had to SIGKILL.
  @script ~s(exec timeout -k 10 "$@" 2>"$ARGUS_STDERR_FILE")

  # Machine-readable, for the three ways `run/6` skips without trying to
  # analyze anything, plus "no_beams" from `analyze/6` below: "disabled" (no
  # argus config -- the admin turned it off), "host_compile_failed" (the host
  # build this would have read beams from never passed), "not_requested"
  # (the configured scope is "firmware" and this package is pure Elixir) and
  # "no_beams" (the package's ebin has no `.beam` to analyze, e.g. a
  # pure-metadata package). `nil` for every non-skipped result.
  @type skip_reason :: String.t() | nil

  @type result :: %{
          status: :ok | :error | :skipped,
          version: String.t() | nil,
          analyses: [String.t()],
          duration_ms: non_neg_integer() | nil,
          findings: [map()],
          truncated: boolean(),
          error: String.t() | nil,
          reason: skip_reason()
        }

  @spec skipped() :: result()
  def skipped do
    %{
      status: :skipped,
      version: nil,
      analyses: [],
      duration_ms: nil,
      findings: [],
      truncated: false,
      error: nil,
      reason: nil
    }
  end

  @spec run(Path.t(), String.t(), map() | nil, :firmware | :pure_elixir, map(), keyword()) ::
          result()
  def run(project, package, config, selection, host_result, opts \\ [])

  def run(_project, _package, nil, _selection, _host, _opts),
    do: %{skipped() | reason: "disabled"}

  def run(_project, _package, _config, _selection, %{status: status}, _opts)
      when status != :pass,
      do: %{skipped() | reason: "host_compile_failed", error: "host status: #{status}"}

  def run(_project, _package, %{scope: "firmware"}, :pure_elixir, _host, _opts),
    do: %{skipped() | reason: "not_requested"}

  # The executable is fixed (`sh` running the pinned escript at `@bin`) and every
  # argument goes through argv, never a shell string; package code runs only
  # inside the disposable container, which is the boundary.
  # sobelow_skip ["CI.System"]
  def run(project, package, config, _selection, _host, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    bin = Keyword.get(opts, :bin, @bin)
    analyses = Map.get(config, :analyses) || @default_analyses
    timeout = Map.get(config, :timeout_seconds) || @default_timeout_seconds
    seed = Keyword.get(opts, :flowlog_seed, @flowlog_seed)
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        seed_flowlog(seed, project)
        analyze(cmd, bin, project, package, analyses, timeout)
      rescue
        e -> %{status: :error, error: Exception.message(e)}
      end

    skipped()
    |> Map.merge(%{analyses: analyses, version: version(cmd, bin, project)})
    |> Map.merge(outcome)
    |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - started)
  end

  @doc false
  @spec args(Path.t(), String.t(), [String.t()]) :: [String.t()]
  def args(project, package, analyses) do
    lib = Path.join([project, "_build", "host", "lib"])

    dep_ebins =
      case File.ls(lib) do
        {:ok, names} -> names
        {:error, _} -> []
      end
      |> Enum.reject(&(&1 in [package, @wrapper_app]))
      |> Enum.sort()
      |> Enum.map(&Path.join([lib, &1, "ebin"]))
      |> Enum.filter(&File.dir?/1)

    ["--project", "beams", "--ebin", Path.join([lib, package, "ebin"])] ++
      Enum.flat_map(dep_ebins, &["--dep-ebin", &1]) ++
      [
        "--analyses",
        Enum.join(analyses, ","),
        "--format",
        "json",
        "--color",
        "never",
        "--state-dir",
        Path.join(project, ".argus-state")
      ]
  end

  defp analyze(cmd, bin, project, package, analyses, timeout) do
    ebin = Path.join([project, "_build", "host", "lib", package, "ebin"])

    cond do
      not File.dir?(ebin) ->
        %{status: :error, error: "no host beams for #{package}"}

      # A pure-metadata package (e.g. nerves_pack 0.7.1/0.7.2) publishes an
      # ebin with only its `.app` file: argus itself would exit 2 "no beams"
      # for that, which is correct but not an error -- there is nothing to
      # find, so this is a skip and argus is never run for it.
      not has_beam?(ebin) ->
        %{skipped() | reason: "no_beams"}

      true ->
        stderr_file = Path.join(project, ".argus-stderr")

        env = [
          {"ARGUS_CACHE_DIR", Path.join(project, ".argus-cache")},
          {"ARGUS_FLOWLOG_DIR", flowlog_dir(project)},
          {"ARGUS_OFFLINE", "1"},
          {"ARGUS_STDERR_FILE", stderr_file},
          {"TYPESAFE_API_KEY", nil}
        ]

        argv = [
          "-c",
          @script,
          "argus-run",
          to_string(timeout),
          bin | args(project, package, analyses)
        ]

        {stdout, status} = cmd.("sh", argv, cd: project, env: env)
        outcome(status, stdout, timeout, stderr_file, package)
    end
  end

  defp has_beam?(ebin) do
    case File.ls(ebin) do
      {:ok, names} -> Enum.any?(names, &String.ends_with?(&1, ".beam"))
      {:error, _} -> false
    end
  end

  defp flowlog_dir(project), do: Path.join(project, ".argus-flowlog")

  # argus solves its rules in FlowLog engines (0.22 on), shipped as a prebuilt
  # bundle of about 120 MB that it would otherwise download from GitHub on
  # every run, in a fresh container. The image downloads it once, into
  # `@flowlog_seed`. argus runs an engine only from a cache root the running
  # user owns and no one else can write, and builds run under whatever uid
  # the host passes (`--user`), so the image's copy cannot be used in place:
  # each run copies it into its own project, owned by that uid. Without a
  # seed argus, offline, reports that it has no engines, as an `:error`.
  defp seed_flowlog(nil, _project), do: :ok

  # Copies the image's own directory into the disposable run project.
  # sobelow_skip ["Traversal.FileModule"]
  defp seed_flowlog(seed, project) do
    if File.dir?(seed) do
      dir = flowlog_dir(project)
      {:ok, _} = File.cp_r(seed, dir)
      File.chmod!(dir, 0o700)
    end

    :ok
  end

  defp outcome(status, stdout, _timeout, _stderr_file, package) when status in [0, 1] do
    case findings(stdout, package) do
      {:ok, found} -> Map.put(found, :error, nil)
      :error -> %{status: :error, error: "invalid json"}
    end
  end

  # argus prints the full report and then exits 3 when any one analysis
  # degraded (an engine timeout, a points-to budget). The other analyses'
  # findings are still valid, so they are kept and the degradation noted.
  defp outcome(3, stdout, _timeout, stderr_file, package) do
    case findings(stdout, package) do
      {:ok, found} -> Map.put(found, :error, "degraded" <> last_line(stderr_file))
      :error -> %{status: :error, error: "argus exited with status 3" <> last_line(stderr_file)}
    end
  end

  defp outcome(status, _stdout, timeout, _stderr_file, _package) when status in [124, 137],
    do: %{status: :error, error: "timeout after #{timeout}s"}

  defp outcome(status, _stdout, _timeout, stderr_file, _package),
    do: %{status: :error, error: "argus exited with status #{status}" <> last_line(stderr_file)}

  defp findings(stdout, package) do
    case JSON.decode(String.trim(stdout)) do
      {:ok, findings} when is_list(findings) ->
        {:ok,
         %{
           status: :ok,
           findings: findings |> Enum.take(@max_findings) |> Enum.map(&relativize(&1, package)),
           truncated: length(findings) > @max_findings
         }}

      _ ->
        :error
    end
  end

  # The reason lands in result.json, whose encoder raises on invalid UTF-8 --
  # which would turn an advisory failure into a worker crash -- and in a
  # database column, so it is made valid and kept short.
  # `file` is the fixed `.argus-stderr` name inside the generated worker project.
  # sobelow_skip ["Traversal.FileModule"]
  defp last_line(file) do
    with {:ok, body} <- File.read(file),
         [_ | _] = lines <- String.split(body, "\n", trim: true) do
      ": " <> (lines |> List.last() |> String.replace_invalid() |> String.slice(0, @max_reason))
    else
      _ -> ""
    end
  end

  defp relativize(%{} = finding, package) do
    prefix = "deps/#{package}/"

    finding
    |> Map.update("file", nil, &strip(&1, prefix))
    |> Map.update("related", [], fn related ->
      Enum.map(related, fn r -> Map.update(r, "file", nil, &strip(&1, prefix)) end)
    end)
  end

  defp relativize(finding, _package), do: finding

  defp strip(path, prefix) when is_binary(path), do: String.replace_prefix(path, prefix, "")
  defp strip(path, _prefix), do: path

  defp version(cmd, bin, project) do
    case cmd.(bin, ["version"], cd: project, stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/\d+\.\d+\.\d+\S*/, out) do
          [version] -> version
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
