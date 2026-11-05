defmodule Portal.Builder.StopTest do
  # A build container under gVisor once wedged so that `docker kill` itself
  # never returned, and with it the Oban job that ran it. Every docker call
  # on the way down has its own deadline and a hung CLI is killed; what
  # docker cannot stop is left to the host's build reaper, and reported.
  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias Portal.Builder.{Cmd, Stop}

  @id String.duplicate("a", 64)

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)

    dir = Path.join(System.tmp_dir!(), "builder-stop-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    {:ok, dir: dir, previous: previous}
  end

  # A `docker` whose answers come from files in `dir`: `ps` prints `ps.out`
  # until `gone` exists, `kill` hangs while `kill.hang` exists. Each call is
  # appended to `calls`.
  defp fake_docker(dir) do
    path = Path.join(dir, "docker")

    File.write!(path, """
    #!/bin/sh
    echo "$*" >> #{dir}/calls
    case "$1" in
      ps) [ -e #{dir}/gone ] || cat #{dir}/ps.out 2>/dev/null; exit 0 ;;
      kill) if [ -e #{dir}/kill.hang ]; then echo $$ > #{dir}/kill.pid; exec sleep 30; fi
            [ -e #{dir}/kill.stops ] && touch #{dir}/gone; exit 0 ;;
    esac
    exit 0
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp calls(dir) do
    case File.read(Path.join(dir, "calls")) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      _ -> []
    end
  end

  defp alive?(pid), do: match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))

  defp opts(dir, extra \\ []) do
    Keyword.merge(
      [
        docker: fake_docker(dir),
        kill_timeout_ms: 300,
        cmd_timeout_ms: 2_000,
        wait_ms: 300,
        poll_ms: 50
      ],
      extra
    )
  end

  describe "Cmd.run/3" do
    test "answers the output and exit status", %{dir: dir} do
      assert {:ok, "hello\n", 3} = Cmd.run("/bin/sh", ["-c", "echo hello; exit 3"], 2_000)
      assert File.dir?(dir)
    end

    test "a command past its deadline is killed and answers :timeout", %{dir: dir} do
      pid_file = Path.join(dir, "pid")
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} =
               Cmd.run("/bin/sh", ["-c", "echo $$ > #{pid_file}; exec sleep 30"], 300)

      assert System.monotonic_time(:millisecond) - started < 2_000
      pid = pid_file |> File.read!() |> String.trim()
      refute alive?(pid), "the hung command #{pid} is still running"
    end

    test "a missing executable is an error, not a crash" do
      assert {:error, {:spawn_failed, _}} = Cmd.run("/nonexistent/docker", ["ps"], 1_000)
    end
  end

  describe "Stop.escalate/2" do
    test "a container docker kill stops is not reaped", %{dir: dir} do
      File.write!(Path.join(dir, "ps.out"), "#{@id}\tncc-run-1\n")
      File.touch!(Path.join(dir, "kill.stops"))

      assert Stop.escalate("ncc-run-1", opts(dir)) == :killed
      assert "kill #{@id}" in calls(dir)
    end

    test "a container that is not running needs nothing", %{dir: dir} do
      assert Stop.escalate("ncc-run-1", opts(dir)) == :gone
      refute Enum.any?(calls(dir), &String.starts_with?(&1, "kill"))
    end

    # Exact names only: docker's name filter is a substring regex.
    test "another container whose name contains this one is left alone", %{dir: dir} do
      File.write!(Path.join(dir, "ps.out"), "#{@id}\tncc-run-10\n")
      assert Stop.escalate("ncc-run-1", opts(dir)) == :gone
      refute Enum.any?(calls(dir), &String.starts_with?(&1, "kill"))
    end

    test "a hung docker kill is cut off and the container reported still running", %{
      dir: dir
    } do
      File.write!(Path.join(dir, "ps.out"), "#{@id}\tncc-run-1\n")
      File.touch!(Path.join(dir, "kill.hang"))
      started = System.monotonic_time(:millisecond)

      {result, log} =
        ExUnit.CaptureLog.with_log(fn -> Stop.escalate("ncc-run-1", opts(dir)) end)

      assert result == :still_running
      assert System.monotonic_time(:millisecond) - started < 3_000
      assert log =~ "ncc-run-1"
      assert log =~ "still running"
      assert log =~ "build reaper"
      kill_pid = dir |> Path.join("kill.pid") |> File.read!() |> String.trim()
      refute alive?(kill_pid), "the hung docker kill #{kill_pid} is still running"
    end

    test "a docker that cannot list containers is :unknown", %{dir: dir} do
      assert Stop.escalate("ncc-run-1", opts(dir, docker: Path.join(dir, "missing"))) ==
               :unknown
    end

    test "emits telemetry with the outcome", %{dir: dir} do
      ref = :telemetry_test.attach_event_handlers(self(), [[:portal, :builder, :container_stop]])
      assert Stop.escalate("ncc-run-1", opts(dir)) == :gone

      assert_received {[:portal, :builder, :container_stop], ^ref, %{duration_ms: _},
                       %{container: "ncc-run-1", outcome: :gone}}
    end
  end

  describe "Stop.overdue/2" do
    test "names ncc containers running longer than the ceiling plus grace", %{dir: dir} do
      now = ~U[2026-11-05 12:00:00Z]

      File.write!(Path.join(dir, "ps.out"), """
      ncc-old\t2026-11-05 08:00:00 +0000 UTC
      ncc-young\t2026-11-05 11:00:00 +0000 UTC
      ncc-offset\t2026-11-05 10:30:00 +0100 CET
      other\t2026-11-01 00:00:00 +0000 UTC
      """)

      assert Stop.overdue(now, docker: fake_docker(dir), limit_ms: :timer.hours(2)) ==
               {:ok, [{"ncc-old", :timer.hours(4)}, {"ncc-offset", :timer.minutes(150)}]}
    end

    test "the limit is the build ceiling plus a grace" do
      assert Stop.overdue_limit_ms() > Portal.Builder.total_timeout_ms()
    end

    test "a docker that cannot answer is :error", %{dir: dir} do
      assert Stop.overdue(DateTime.utc_now(),
               docker: Path.join(dir, "missing"),
               limit_ms: 1
             ) == :error
    end
  end
end
