defmodule Portal.EgressCheck do
  @moduledoc """
  The per-host egress check (isolation spec, section 3; the operator runbook),
  run on a build host after a deploy that touches the
  filter. It passes only when all four hold:

  1. `Portal.Builder.check_egress/0` passes: the filter is loaded.
  2. A bare worker-image container cannot open a TCP connection to any target.
  3. A real build of `jason` (pure Elixir: a host compile, no firmware) cannot
     either: the worker probes every target before `deps.get`
     (`NccWorker.EgressProbe`) and reports it in `result.json.egress_probe`.
  4. That build itself succeeds: exit code 0 and every system `pass`. The
     probe runs before `deps.get`, so a filter that also breaks DNS or 443
     would block every target and still fail every honest build.

  A target is blocked when the connect timed out (the filter drops it) or had
  no route (IPv6 in a namespace without one). `connected` and `refused` both
  mean the packet got through. Run from the release, with the targets in
  `NCC_EGRESS_PROBE` as `host:port`, IPv6 in brackets, comma-separated:

      NCC_EGRESS_PROBE='100.64.0.1:5432,[fd00::1]:5432' \\
        bin/portal eval 'Portal.EgressCheck.main()'
  """

  alias Portal.Builder

  @package "jason"
  @version "1.4.4"
  @blocked ["timeout", "unreachable"]
  @probe_exit "ncc-egress-probe-exit="
  # Connects within 3 s, then prints its own exit status (124: timed out).
  @bare_script ~S|timeout 3 bash -c 'exec 3<>"/dev/tcp/$0/$1"' "$0" "$1"; s=$?; echo "| <>
                 @probe_exit <> ~S|$s"; exit "$s"|

  @type target :: %{String.t() => String.t() | pos_integer()}
  @type report :: %{
          preflight: :ok | {:error, term()},
          bare: [map()],
          build: [map()] | {:error, term()},
          build_result: :pass | {:error, String.t()},
          ok?: boolean()
        }

  @doc "Reads `NCC_EGRESS_PROBE`, runs the check, prints it, exits 0 on a pass."
  @spec main() :: no_return()
  def main do
    case parse_targets(System.get_env("NCC_EGRESS_PROBE")) do
      {:ok, targets} ->
        report = run(targets)
        IO.puts(format(report))
        System.halt(if report.ok?, do: 0, else: 1)

      {:error, message} ->
        IO.puts(:stderr, message)
        System.halt(2)
    end
  end

  @doc "Parses `host:port[,…]`, IP literals only, IPv6 in brackets."
  @spec parse_targets(String.t() | nil) :: {:ok, [target()]} | {:error, String.t()}
  def parse_targets(nil),
    do: {:error, "set NCC_EGRESS_PROBE to host:port pairs, e.g. 100.64.0.1:5432,[fd00::1]:5432"}

  def parse_targets(raw) when is_binary(raw) do
    raw
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> parse_entries([])
  end

  defp parse_entries([], []), do: {:error, "NCC_EGRESS_PROBE names no target"}
  defp parse_entries([], acc), do: {:ok, Enum.reverse(acc)}

  defp parse_entries([entry | rest], acc) do
    case parse_target(entry) do
      {:ok, target} -> parse_entries(rest, [target | acc])
      :error -> {:error, "not an IP literal and a port (IPv6 in brackets): #{entry}"}
    end
  end

  defp parse_target(entry) do
    with [_, v6, v4, port_text] <-
           Regex.run(~r/\A(?:\[([0-9A-Fa-f:.]+)\]|([0-9.]+)):(\d{1,5})\z/, entry),
         address = if(v6 != "", do: v6, else: v4),
         {:ok, _ip} <- :inet.parse_strict_address(String.to_charlist(address)),
         {port, ""} when port in 1..65_535 <- Integer.parse(port_text) do
      {:ok, %{"address" => address, "port" => port}}
    else
      _ -> :error
    end
  end

  @doc "Runs the three checks; `deps` replaces the real ones in tests."
  @spec run([target()], map()) :: report()
  def run(targets, deps \\ default_deps()) do
    preflight = deps.preflight.()
    bare = Enum.map(targets, &Map.put(&1, "outcome", deps.bare.(&1)))
    {build, build_result} = probe_build(targets, deps)

    %{
      preflight: preflight,
      bare: bare,
      build: build,
      build_result: build_result,
      ok?:
        preflight == :ok and all_blocked?(bare) and all_blocked?(build) and
          build_result == :pass
    }
  end

  @doc "Whether an outcome means the filter stopped the packet."
  @spec blocked?(term()) :: boolean()
  def blocked?(outcome), do: outcome in @blocked

  @doc "The report as lines for an operator's terminal."
  @spec format(report()) :: String.t()
  def format(report) do
    [
      "preflight: #{inspect(report.preflight)}",
      Enum.map(
        report.bare,
        &"bare container -> #{&1["address"]}:#{&1["port"]}: #{&1["outcome"]}"
      ),
      build_lines(report.build),
      build_result_line(report.build_result),
      if(report.ok?, do: "egress check PASSED", else: "egress check FAILED")
    ]
    |> List.flatten()
    |> Enum.join("\n")
  end

  @doc false
  # The worker image and the host's build user on the bridge every build uses,
  # and none of a build's other sandboxing: this checks the filter, not the
  # container hardening. `address` and `port` were validated by
  # `parse_targets/1`, and reach bash as positional arguments, never as script.
  # The script prints its own exit status, so `bare_outcome/1` can tell a
  # probe that ran (and timed out) from docker failing to run it at all.
  # sobelow_skip ["CI.System"]
  @spec bare_probe(target()) :: String.t()
  def bare_probe(%{"address" => address, "port" => port}) do
    args = [
      "run",
      "--rm",
      "--pull=never",
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      "--user",
      Builder.run_as_user(),
      "--entrypoint",
      "bash",
      Builder.docker_image(),
      "-c",
      @bare_script,
      address,
      Integer.to_string(port)
    ]

    "docker" |> System.cmd(args, stderr_to_stdout: true) |> bare_outcome()
  end

  @doc false
  # Only the probe's own exit line, matching docker's exit status, says the
  # probe ran; without it docker failed (no image, no daemon, a container
  # that never started), and nothing docker said counts as a drop.
  @spec bare_outcome({String.t(), non_neg_integer()}) :: String.t()
  def bare_outcome({out, status}) do
    probed = Integer.to_string(status)

    case Regex.run(~r/^#{@probe_exit}(\d+)$/m, out) do
      [_, ^probed] -> probe_outcome(status, out)
      _ -> "error: the probe did not run: " <> String.trim(out)
    end
  end

  defp probe_outcome(0, _out), do: "connected"
  defp probe_outcome(124, _out), do: "timeout"

  defp probe_outcome(_status, out) do
    cond do
      out =~ "Connection refused" -> "refused"
      out =~ ~r/unreachable|No route to host/i -> "unreachable"
      true -> "error: " <> String.trim(out)
    end
  end

  defp probe_build(targets, deps) do
    run_id = "egress-check-#{System.system_time(:millisecond)}"

    try do
      %{package: @package, version: @version, run_id: run_id, egress_probe: targets}
      |> deps.build.()
      |> build_outcomes()
    after
      deps.cleanup.(run_id)
    end
  end

  defp build_outcomes({:ok, %{result: %{"egress_probe" => outcomes}} = build})
       when is_list(outcomes),
       do: {outcomes, build_result(build)}

  defp build_outcomes({:ok, %{exit_code: code}}) do
    reason = "the build exited #{code} without an egress_probe in result.json"
    {{:error, reason}, {:error, reason}}
  end

  defp build_outcomes({:error, reason}), do: {{:error, reason}, {:error, inspect(reason)}}

  # Exit 0 and a host compile among the systems, every one of them `pass`.
  defp build_result(%{exit_code: 0, result: result}) do
    statuses =
      case result["systems"] do
        %{} = systems -> Map.new(systems, fn {name, system} -> {name, system["status"]} end)
        _ -> %{}
      end

    if Map.has_key?(statuses, "host") and Enum.all?(statuses, &match?({_, "pass"}, &1)),
      do: :pass,
      else: {:error, "the build exited 0 but its systems are #{inspect(statuses)}"}
  end

  defp build_result(%{exit_code: code}), do: {:error, "the build exited #{code}"}

  defp all_blocked?([_ | _] = outcomes), do: Enum.all?(outcomes, &blocked?(&1["outcome"]))
  defp all_blocked?(_outcomes), do: false

  defp build_lines(outcomes) when is_list(outcomes),
    do:
      Enum.map(
        outcomes,
        &"build #{@package} #{@version} -> #{&1["address"]}:#{&1["port"]}: #{&1["outcome"]}"
      )

  defp build_lines({:error, reason}), do: ["build #{@package} #{@version}: #{inspect(reason)}"]

  defp build_result_line(:pass), do: "build #{@package} #{@version}: exit 0, every system pass"
  defp build_result_line({:error, reason}), do: "build #{@package} #{@version}: FAILED, #{reason}"

  defp default_deps do
    %{
      preflight: &Builder.check_egress/0,
      bare: &bare_probe/1,
      build: &Builder.build/1,
      cleanup: &Builder.cleanup/1
    }
  end
end
