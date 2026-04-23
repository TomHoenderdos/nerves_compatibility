defmodule Orchestrator.HexPoller do
  @moduledoc """
  Polls Hex.pm for new package versions and adds them to the queue.

  Uses req_hex to fetch packages and their latest versions from Hex.pm.
  Runs on a configurable interval (default: 1 hour in production).
  """

  use GenServer
  require Logger

  ## Client API

  @doc """
  Starts the HexPoller GenServer.
  """
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Triggers an immediate poll (useful for testing or manual triggering).
  """
  def poll_now() do
    GenServer.cast(__MODULE__, :poll_now)
  end

  @doc """
  Returns the current state/stats of the poller.
  """
  def status() do
    GenServer.call(__MODULE__, :status)
  end

  ## Server Callbacks

  @impl true
  def init(_opts) do
    poll_interval = Orchestrator.poll_interval()

    state = %{
      poll_interval: poll_interval,
      last_poll: nil,
      next_poll: schedule_poll(poll_interval),
      poll_count: 0,
      packages_discovered: 0,
      packages_enqueued: 0
    }

    Logger.info("HexPoller started, will poll every #{format_interval(poll_interval)}")

    # Do an initial poll shortly after startup
    Process.send_after(self(), :poll, :timer.seconds(5))

    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Logger.info("Starting Hex.pm poll cycle")
    start_time = System.monotonic_time(:millisecond)

    {discovered, enqueued} = poll_hex()

    elapsed = System.monotonic_time(:millisecond) - start_time

    Logger.info(
      "Poll completed in #{elapsed}ms: #{discovered} packages discovered, #{enqueued} newly enqueued"
    )

    new_state = %{
      state
      | last_poll: DateTime.utc_now(),
        next_poll: schedule_poll(state.poll_interval),
        poll_count: state.poll_count + 1,
        packages_discovered: state.packages_discovered + discovered,
        packages_enqueued: state.packages_enqueued + enqueued
    }

    {:noreply, new_state}
  end

  @impl true
  def handle_cast(:poll_now, state) do
    send(self(), :poll)
    {:noreply, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = %{
      poll_interval: state.poll_interval,
      last_poll: state.last_poll,
      next_poll: state.next_poll,
      poll_count: state.poll_count,
      packages_discovered: state.packages_discovered,
      packages_enqueued: state.packages_enqueued
    }

    {:reply, status, state}
  end

  ## Private Helpers

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll, interval)
    DateTime.add(DateTime.utc_now(), interval, :millisecond)
  end

  defp poll_hex() do
    try do
      # Fetch all packages from Hex
      Logger.debug("Fetching packages from Hex.pm...")

      # Use Req with ReqHex plugin to fetch package versions and metadata
      req = Req.new(base_url: "https://repo.hex.pm") |> ReqHex.attach()

      # First get all package names with timestamps
      case Req.get(req, url: "/names") do
        {:ok, %{status: 200, body: names_body}} ->
          packages =
            cond do
              is_list(names_body) ->
                names_body

              is_map(names_body) and Map.has_key?(names_body, :packages) ->
                Map.get(names_body, :packages)

              is_map(names_body) and Map.has_key?(names_body, "packages") ->
                Map.get(names_body, "packages")

              true ->
                []
            end

          Logger.debug("Retrieved #{length(packages)} packages from Hex.pm")

          # Sort packages by updated_at timestamp in descending order (most recent first)
          sorted_packages = sort_packages_by_date(packages)

          # Now fetch version info for the sorted packages
          case Req.get(req, url: "/versions") do
            {:ok, %{status: 200, body: versions_body}} ->
              versions_map =
                cond do
                  is_list(versions_body) ->
                    Map.new(versions_body, fn pkg -> {pkg.name, pkg} end)

                  is_map(versions_body) and Map.has_key?(versions_body, :packages) ->
                    Map.new(Map.get(versions_body, :packages), fn pkg -> {pkg.name, pkg} end)

                  is_map(versions_body) and Map.has_key?(versions_body, "packages") ->
                    Map.new(Map.get(versions_body, "packages"), fn pkg -> {pkg.name, pkg} end)

                  true ->
                    %{}
                end

              # Merge version info with sorted package names
              packages_with_versions =
                Enum.map(sorted_packages, fn pkg ->
                  name = Map.get(pkg, :name) || Map.get(pkg, "name")
                  Map.merge(pkg, Map.get(versions_map, name, %{}))
                end)

              # Prepend packages owned by configured priority users. Enqueue
              # dedup will no-op anything already queued or checked, so
              # this is safe to run every poll.
              priority_packages = fetch_priority_packages(versions_map)

              process_packages(priority_packages ++ packages_with_versions)

            {:ok, %{status: status}} ->
              Logger.error("Failed to fetch versions from Hex.pm: HTTP #{status}")
              {0, 0}

            {:error, reason} ->
              Logger.error("Failed to fetch versions from Hex.pm: #{inspect(reason)}")
              {0, 0}
          end

        {:ok, %{status: status}} ->
          Logger.error("Failed to fetch packages from Hex.pm: HTTP #{status}")
          {0, 0}

        {:error, reason} ->
          Logger.error("Failed to fetch packages from Hex.pm: #{inspect(reason)}")
          {0, 0}
      end
    rescue
      error ->
        Logger.error("Error polling Hex.pm: #{inspect(error)}")
        {0, 0}
    end
  end

  defp sort_packages_by_date(packages) do
    Enum.sort_by(packages, fn pkg ->
      updated_at = Map.get(pkg, :updated_at) || Map.get(pkg, "updated_at")

      case updated_at do
        %{seconds: seconds} -> -seconds
        %{"seconds" => seconds} -> -seconds
        _ -> 0
      end
    end)
  end

  # For each configured priority user, hit hex.pm/api/users/{name} to get
  # their `owned_packages` map, then produce package entries in the same
  # shape that process_packages expects (name + merged versions_map data).
  # Failures per user are logged and swallowed — a misspelled username or
  # a network hiccup shouldn't block the regular poll.
  defp fetch_priority_packages(versions_map) do
    users = Orchestrator.priority_users()

    users
    |> Enum.flat_map(fn user ->
      case Req.get("https://hex.pm/api/users/#{user}") do
        {:ok, %{status: 200, body: body}} ->
          owned = Map.get(body, "owned_packages") || Map.get(body, :owned_packages) || %{}
          names = Map.keys(owned)

          Logger.info("Priority user #{user}: #{length(names)} owned packages")

          Enum.map(names, fn name ->
            name_str = to_string(name)
            base = %{"name" => name_str, :name => name_str}
            Map.merge(base, Map.get(versions_map, name_str, %{}))
          end)

        {:ok, %{status: status}} ->
          Logger.warning("Priority user #{user}: Hex API returned HTTP #{status}")
          []

        {:error, reason} ->
          Logger.warning("Priority user #{user}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp process_packages(packages) do
    discovered = length(packages)
    enqueued = 0

    enqueued_count =
      Enum.reduce(packages, enqueued, fn package, acc ->
        case enqueue_package(package) do
          :ok -> acc + 1
          {:already_checked, _timestamp} -> acc
        end
      end)

    {discovered, enqueued_count}
  end

  defp enqueue_package(package) do
    # Get the latest version from the package
    # The /versions endpoint returns: %{name: "pkg", versions: ["1.0.0", ...], retired: []}
    package_name = Map.get(package, :name) || Map.get(package, "name")
    latest_version = get_latest_version(package)

    case latest_version do
      nil ->
        Logger.debug("No version found for package: #{package_name}")
        {:already_checked, nil}

      version ->
        item = {package_name, version}

        case Orchestrator.Queue.enqueue(item) do
          :ok ->
            Logger.debug("Enqueued new package: #{package_name}:#{version}")
            :ok

          {:already_checked, timestamp} ->
            Logger.debug("Package #{package_name}:#{version} already checked at #{timestamp}")

            {:already_checked, timestamp}
        end
    end
  end

  defp get_latest_version(%{versions: versions, retired: retired}) when is_list(versions) do
    versions
    |> Enum.reject(fn v -> v in retired end)
    |> Enum.sort_by(&Version.parse!/1, {:desc, Version})
    |> List.first()
  end

  defp get_latest_version(%{"versions" => versions, "retired" => retired})
       when is_list(versions) do
    versions
    |> Enum.reject(fn v -> v in retired end)
    |> Enum.sort_by(&Version.parse!/1, {:desc, Version})
    |> List.first()
  end

  defp get_latest_version(_package) do
    nil
  end

  defp format_interval(ms) do
    cond do
      ms >= :timer.hours(1) -> "#{div(ms, :timer.hours(1))} hour(s)"
      ms >= :timer.minutes(1) -> "#{div(ms, :timer.minutes(1))} minute(s)"
      ms >= :timer.seconds(1) -> "#{div(ms, :timer.seconds(1))} second(s)"
      true -> "#{ms} millisecond(s)"
    end
  end
end
