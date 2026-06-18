defmodule Orchestrator.CLI do
  @moduledoc """
  CLI for the Nerves Compatibility Orchestrator.

  Provides commands to:
  - Start/stop the orchestrator
  - Inspect queue status
  - Trigger manual polling
  - Pause/resume processing
  """

  require Logger

  def main(args) do
    {opts, command, _} =
      OptionParser.parse(args,
        strict: [
          help: :boolean,
          config: :string,
          source: :string,
          version: :string,
          subject: :string,
          verified: :boolean,
          human_check: :string
        ],
        aliases: [h: :help, c: :config]
      )

    if opts[:help] do
      print_help()
      System.halt(0)
    end

    # Load configuration if specified
    if config_file = opts[:config] do
      load_config(config_file)
    end

    case command do
      ["start"] -> start_command()
      ["status"] -> status_command()
      ["queue"] -> queue_command()
      ["poll"] -> poll_command()
      ["pause"] -> pause_command()
      ["resume"] -> resume_command()
      ["clear-checked"] -> clear_checked_command()
      ["request-scan", package] -> request_scan_command(package, opts)
      _ -> print_help()
    end
  end

  defp print_help() do
    IO.puts("""
    Nerves Compatibility Orchestrator

    Usage: ncc_orchestrator [options] <command>

    Commands:
      start           Start the orchestrator (runs until interrupted)
      status          Show orchestrator status
      queue           Show queue status and contents
      poll            Trigger an immediate Hex poll
      pause           Pause processing
      resume          Resume processing
      clear-checked   Clear all checked packages (use with caution)
      request-scan PACKAGE
                      Queue a package rescan request

    Options:
      -h, --help            Show this help
      -c, --config FILE     Load configuration from FILE
      --version VERSION     Package version to scan (defaults to latest from Hex)
      --source SOURCE       anonymous_manual, anonymous_turnstile, hex_owner, or github_repo
      --human-check CHECK   manual or turnstile for anonymous requests
      --verified            Required for hex_owner and github_repo sources
      --subject SUBJECT     Verified Hex or GitHub username

    Examples:
      ncc_orchestrator start
      ncc_orchestrator status
      ncc_orchestrator queue
      ncc_orchestrator request-scan jason --version 1.4.4 --source anonymous_manual --human-check manual
      ncc_orchestrator --config config.exs start
    """)
  end

  defp start_command() do
    Logger.info("Starting Nerves Compatibility Orchestrator...")

    {:ok, _} = Application.ensure_all_started(:orchestrator)

    Logger.info("Orchestrator is running. Press Ctrl+C to stop.")
    :timer.sleep(:infinity)
  end

  defp status_command() do
    ensure_started()

    IO.puts("\n=== Orchestrator Status ===\n")

    # HexPoller status
    case Orchestrator.HexPoller.status() do
      status ->
        IO.puts("Hex Poller:")
        IO.puts("  Poll interval: #{format_interval(status.poll_interval)}")
        IO.puts("  Last poll: #{format_datetime(status.last_poll)}")
        IO.puts("  Next poll: #{format_datetime(status.next_poll)}")
        IO.puts("  Total polls: #{status.poll_count}")
        IO.puts("  Packages discovered: #{status.packages_discovered}")
        IO.puts("  Packages enqueued: #{status.packages_enqueued}")
    end

    IO.puts("")

    # Processor status
    case Orchestrator.Processor.status() do
      status ->
        IO.puts("Processor:")
        IO.puts("  Status: #{if status.paused, do: "PAUSED", else: "RUNNING"}")
        IO.puts("  Started at: #{format_datetime(status.started_at)}")
        IO.puts("  Last processed: #{format_datetime(status.last_processed)}")
        IO.puts("  Processed: #{status.processed_count}")
        IO.puts("  Failed: #{status.failed_count}")

        if status.current_item do
          {pkg, ver} = status.current_item
          IO.puts("  Currently processing: #{pkg}:#{ver}")
        end

        if status.next_in_queue do
          {pkg, ver} = status.next_in_queue
          IO.puts("  Next in queue: #{pkg}:#{ver}")
        end
    end

    IO.puts("")

    # Queue stats
    stats = Orchestrator.Queue.stats()
    IO.puts("Queue:")
    IO.puts("  Pending: #{stats.queue_size}")
    IO.puts("  Checked: #{stats.checked_count}")

    IO.puts("")
  end

  defp queue_command() do
    ensure_started()

    IO.puts("\n=== Queue Status ===\n")

    stats = Orchestrator.Queue.stats()
    IO.puts("Pending items: #{stats.queue_size}")
    IO.puts("Checked items: #{stats.checked_count}\n")

    if stats.queue_size > 0 do
      IO.puts("Next 10 items in queue:")

      Orchestrator.Queue.list()
      |> Enum.take(10)
      |> Enum.with_index(1)
      |> Enum.each(fn {{package, version}, index} ->
        IO.puts("  #{index}. #{package}:#{version}")
      end)

      if stats.queue_size > 10 do
        IO.puts("  ... and #{stats.queue_size - 10} more")
      end
    else
      IO.puts("Queue is empty.")
    end

    IO.puts("")

    # Show recently checked
    recent = Orchestrator.Queue.recent_checked(5)

    if length(recent) > 0 do
      IO.puts("Recently checked:")

      Enum.each(recent, fn {{package, version}, timestamp} ->
        IO.puts("  #{package}:#{version} - #{format_datetime(timestamp)}")
      end)
    end

    IO.puts("")
  end

  defp poll_command() do
    ensure_started()

    IO.puts("Triggering manual poll...")
    Orchestrator.HexPoller.poll_now()
    IO.puts("Poll triggered. Check logs for results.")
  end

  defp pause_command() do
    ensure_started()

    IO.puts("Pausing processor...")
    Orchestrator.Processor.pause()
    IO.puts("Processor paused.")
  end

  defp resume_command() do
    ensure_started()

    IO.puts("Resuming processor...")
    Orchestrator.Processor.resume()
    IO.puts("Processor resumed.")
  end

  defp clear_checked_command() do
    ensure_started()

    IO.puts("WARNING: This will clear all checked packages!")
    IO.write("Are you sure? (yes/no): ")

    case IO.gets("") |> String.trim() do
      "yes" ->
        Orchestrator.Queue.clear_checked()
        IO.puts("Cleared all checked packages.")

      _ ->
        IO.puts("Cancelled.")
    end
  end

  defp request_scan_command(package, opts) do
    ensure_started()

    attrs = %{
      package: package,
      version: opts[:version],
      source: opts[:source] || "anonymous_manual",
      human_check: opts[:human_check] || "manual",
      verified?: opts[:verified] || false,
      subject: opts[:subject]
    }

    case Orchestrator.ScanRequest.submit(attrs) do
      {:ok, request} ->
        IO.puts(
          "Queued #{request.package}:#{request.version} via #{request.source}" <>
            if(request.subject, do: " for #{request.subject}", else: "")
        )

      {:error, reason} ->
        IO.puts("Could not queue request: #{reason}")
        System.halt(1)
    end
  end

  defp ensure_started() do
    case Application.ensure_all_started(:orchestrator) do
      {:ok, _} -> :ok
      {:error, reason} -> IO.puts("Failed to start orchestrator: #{inspect(reason)}")
    end
  end

  defp load_config(file) do
    case File.read(file) do
      {:ok, content} ->
        Code.eval_string(content)
        Logger.info("Loaded configuration from #{file}")

      {:error, reason} ->
        Logger.error("Failed to load config file #{file}: #{inspect(reason)}")
        System.halt(1)
    end
  end

  defp format_interval(ms) do
    cond do
      ms >= :timer.hours(1) -> "#{div(ms, :timer.hours(1))} hour(s)"
      ms >= :timer.minutes(1) -> "#{div(ms, :timer.minutes(1))} minute(s)"
      ms >= :timer.seconds(1) -> "#{div(ms, :timer.seconds(1))} second(s)"
      true -> "#{ms}ms"
    end
  end

  defp format_datetime(nil), do: "never"

  defp format_datetime(%DateTime{} = dt) do
    Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S UTC")
  end
end
