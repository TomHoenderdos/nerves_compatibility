defmodule NccWorker.Argus do
  @moduledoc """
  Runs argus_beam's escript over the package's host-compiled beams and returns
  its findings for `result.json`.

  Advisory: nothing here changes a system's status or the worker's exit code.
  Every failure, including a missing escript or souffle, becomes an `:error`
  result with a short reason.
  """

  @bin "/home/nerves/.mix/escripts/argus"
  @max_findings 200
  @default_timeout_seconds 300
  @default_analyses ["default", "exposure"]

  # The generated wrapper application, from `Project.new_project/2`. It is
  # rewritten for every package and is not the package under analysis.
  @wrapper_app "nerves_compatibility_test"

  # stderr goes to a file so stdout stays the JSON document argus prints.
  # `timeout` exits 124 on expiry and 137 when it had to SIGKILL.
  @script ~s(exec timeout -k 10 "$@" 2>"$ARGUS_STDERR_FILE")

  @type result :: %{
          status: :ok | :error | :skipped,
          version: String.t() | nil,
          analyses: [String.t()],
          duration_ms: non_neg_integer() | nil,
          findings: [map()],
          truncated: boolean(),
          error: String.t() | nil
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
      error: nil
    }
  end

  @spec run(Path.t(), String.t(), map() | nil, :firmware | :pure_elixir, map(), keyword()) ::
          result()
  def run(project, package, config, selection, host_result, opts \\ [])
  def run(_project, _package, nil, _selection, _host, _opts), do: skipped()

  def run(_project, _package, _config, _selection, %{status: status}, _opts)
      when status != :pass,
      do: skipped()

  def run(_project, _package, %{scope: "firmware"}, :pure_elixir, _host, _opts), do: skipped()

  def run(project, package, config, _selection, _host, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    bin = Keyword.get(opts, :bin, @bin)
    analyses = Map.get(config, :analyses) || @default_analyses
    timeout = Map.get(config, :timeout_seconds) || @default_timeout_seconds
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
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
    if File.dir?(Path.join([project, "_build", "host", "lib", package, "ebin"])) do
      stderr_file = Path.join(project, ".argus-stderr")

      env = [
        {"ARGUS_CACHE_DIR", Path.join(project, ".argus-cache")},
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
    else
      %{status: :error, error: "no host beams for #{package}"}
    end
  end

  defp outcome(status, stdout, _timeout, _stderr_file, package) when status in [0, 1] do
    case JSON.decode(String.trim(stdout)) do
      {:ok, findings} when is_list(findings) ->
        %{
          status: :ok,
          findings: findings |> Enum.take(@max_findings) |> Enum.map(&relativize(&1, package)),
          truncated: length(findings) > @max_findings,
          error: nil
        }

      _ ->
        %{status: :error, error: "invalid json"}
    end
  end

  defp outcome(status, _stdout, timeout, _stderr_file, _package) when status in [124, 137],
    do: %{status: :error, error: "timeout after #{timeout}s"}

  defp outcome(status, _stdout, _timeout, stderr_file, _package),
    do: %{status: :error, error: "argus exited with status #{status}" <> last_line(stderr_file)}

  defp last_line(file) do
    with {:ok, body} <- File.read(file),
         [_ | _] = lines <- String.split(body, "\n", trim: true) do
      ": " <> List.last(lines)
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
