defmodule Portal.Workers.SystemAbiRun do
  @moduledoc """
  Oban worker that reads the ABI of Nerves system releases no build has
  reported: the worker container in `mode: "system_abi"`
  (`Portal.Builder.build/2`, `NccWorker.SystemAbiRun`) with at most eight
  `%{"system", "version"}` pairs. After exit 0 the result's `system_abi`
  list goes to `Portal.Catalog.SystemAbi.observe_all/1`, and the published
  target builds of those releases get the toolchain and OTP their rows now
  hold (`Portal.Workers.SystemAbiBackfill.fill_release_facts/1`). It is not
  a package run and never reaches `Portal.Catalog.Ingestion`.

  It needs Docker, so it runs on the build nodes: every node that runs
  `:builds` also runs `:system_abi` with limit 1 (`with_queue/1`). The job
  reads its own result and removes its own scratch dir, so, unlike a warm, it
  may run on whichever build node takes it, and the web host's
  `Portal.Workers.SystemAbiBackfill` and `Portal.Workers.SystemAbiObserve`
  queue it without picking a node.

  Every pair queued (`schedule/2`) gets a `catalog_system_abi_attempts` row:
  a pair is queued again only a day after its last attempt, and never after
  an error no retry can fix (`permanent_errors/0`).
  """

  use Oban.Worker,
    queue: :system_abi,
    max_attempts: 3,
    unique: [period: 86_400, keys: [:pairs], states: :successful]

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Builder
  alias Portal.Catalog.SystemAbi
  alias Portal.Repo
  alias Portal.Workers.{Ingest, SystemAbiBackfill}

  @max_pairs 8
  @retry_after_s 86_400

  # A release that does not accept the image's Nerves, or has no rootfs to
  # read, reads the same on every retry.
  @permanent_errors ["requires nerves 1", "no rootfs"]

  @incomplete ~w(available scheduled executing retryable suspended)

  @type pair :: %{String.t() => String.t()}

  @doc "The most pairs one run takes."
  @spec max_pairs() :: pos_integer()
  def max_pairs, do: @max_pairs

  @doc "Errors after which a release is never asked again."
  @spec permanent_errors() :: [String.t()]
  def permanent_errors, do: @permanent_errors

  @doc """
  `oban_config` with `:system_abi` added, limit 1, when the node runs builds
  (`Portal.Workers.Ingest.local_queue_limit/1`): one system ABI run at a time
  beside the node's builds.
  """
  @spec with_queue(keyword()) :: keyword()
  def with_queue(oban_config) do
    queues = Keyword.get(oban_config, :queues)

    case Ingest.local_queue_limit(queues) do
      nil ->
        oban_config

      _limit ->
        queues =
          if Keyword.has_key?(queues, :system_abi), do: queues, else: queues ++ [system_abi: 1]

        Keyword.put(oban_config, :queues, queues)
    end
  end

  @doc "Queues one run for `pairs` (at most `max_pairs/0`)."
  @spec enqueue([pair()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(pairs) when is_list(pairs) and length(pairs) <= @max_pairs do
    %{"pairs" => pairs} |> new() |> Oban.insert()
  end

  def enqueue(_pairs), do: {:error, :too_many_pairs}

  @doc """
  Queues runs for the `pairs` that may be asked now (`askable/1`), eight per
  run and at most `max_runs` runs, recording an attempt for each pair.
  Returns how many runs it queued and whether askable pairs were left over.
  """
  @spec schedule([pair()], pos_integer()) :: {non_neg_integer(), boolean()}
  def schedule(pairs, max_runs) do
    chunks = pairs |> askable() |> Enum.chunk_every(@max_pairs)
    {now, later} = Enum.split(chunks, max_runs)

    queued =
      Enum.count(now, fn chunk ->
        case enqueue(chunk) do
          {:ok, _job} ->
            record_attempts(chunk)
            true

          {:error, reason} ->
            Logger.warning("Could not queue a system ABI run: #{inspect(reason)}")
            false
        end
      end)

    {queued, later != []}
  end

  @doc """
  The `pairs` that may be asked now, in order and without duplicates: not
  in a run that has not finished, not attempted in the last day and never
  failed with a permanent error.
  """
  @spec askable([pair()]) :: [pair()]
  def askable(pairs) do
    blocked = MapSet.union(attempted(), in_flight())

    pairs
    |> Enum.uniq()
    |> Enum.reject(&MapSet.member?(blocked, {&1["system"], &1["version"]}))
  end

  defp attempted do
    cutoff = DateTime.add(DateTime.utc_now(), -@retry_after_s, :second)

    from(a in "catalog_system_abi_attempts",
      where: a.permanent or a.attempted_at > ^cutoff,
      select: {a.system_pkg, a.version}
    )
    |> Repo.all()
    |> MapSet.new()
  end

  defp in_flight do
    from(j in Oban.Job,
      where: j.worker == "Portal.Workers.SystemAbiRun" and j.state in @incomplete,
      select: j.args
    )
    |> Repo.all()
    |> Enum.flat_map(fn args -> args |> Map.get("pairs") |> List.wrap() end)
    |> Enum.flat_map(fn
      %{"system" => system, "version" => version} -> [{system, version}]
      _ -> []
    end)
    |> MapSet.new()
  end

  defp record_attempts(pairs) do
    now = DateTime.utc_now()

    rows =
      Enum.map(pairs, fn %{"system" => system, "version" => version} ->
        %{system_pkg: system, version: version, attempted_at: now, error: nil, permanent: false}
      end)

    Repo.insert_all("catalog_system_abi_attempts", rows,
      on_conflict: {:replace, [:attempted_at]},
      conflict_target: [:system_pkg, :version]
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"pairs" => pairs}}) when is_list(pairs) do
    if valid_pairs?(pairs), do: run(pairs), else: malformed(pairs)
  end

  def perform(%Oban.Job{args: args}), do: malformed(args)

  defp malformed(args), do: {:cancel, "malformed system ABI args: #{inspect(args)}"}

  defp valid_pairs?(pairs) do
    pairs != [] and length(pairs) <= @max_pairs and
      Enum.all?(pairs, fn
        %{"system" => system, "version" => version} -> is_binary(system) and is_binary(version)
        _ -> false
      end)
  end

  defp run(pairs) do
    run_id = "system_abi-#{System.system_time(:millisecond)}"

    try do
      outcome(builder().build(%{run_id: run_id, mode: "system_abi", system_abi: pairs}), pairs)
    after
      builder().cleanup(run_id)
    end
  end

  defp outcome({:ok, %{exit_code: 0, result: %{"system_abi" => entries}}}, pairs)
       when is_list(entries) do
    SystemAbi.observe_all(entries)
    record_errors(entries)
    SystemAbiBackfill.fill_release_facts(pairs)

    Logger.info(
      "System ABI run of #{describe(pairs)}: " <>
        Enum.map_join(entries, ", ", &entry_summary/1)
    )

    :ok
  end

  defp outcome({:ok, %{exit_code: 0}}, _pairs), do: {:error, :missing_system_abi_result}

  defp outcome({:ok, %{exit_code: code}}, _pairs),
    do: {:error, "system ABI container exited #{code}"}

  # Host conditions that resolve themselves, as for a warm.
  defp outcome({:error, {:insufficient_disk, _free, _needed}}, _pairs), do: {:snooze, 900}
  defp outcome({:error, :scratch_noexec}, _pairs), do: {:snooze, 900}
  defp outcome({:error, :egress_filter_missing}, _pairs), do: {:snooze, 900}
  defp outcome({:error, :build_memory_limit_missing}, _pairs), do: {:snooze, 900}
  defp outcome({:error, reason}, _pairs), do: {:error, reason}

  # Upserted rather than updated: a run queued with `enqueue/1` alone has no
  # attempt row yet, and its permanent error must still be kept.
  defp record_errors(entries) do
    now = DateTime.utc_now()

    rows =
      for %{"system" => system, "version" => version, "error" => error} <- entries,
          is_binary(system) and is_binary(version) and is_binary(error) do
        %{
          system_pkg: system,
          version: version,
          attempted_at: now,
          error: String.slice(error, 0, 200),
          permanent: error in @permanent_errors
        }
      end

    if rows != [] do
      Repo.insert_all("catalog_system_abi_attempts", rows,
        on_conflict: {:replace, [:error, :permanent]},
        conflict_target: [:system_pkg, :version]
      )
    end

    :ok
  end

  defp entry_summary(%{"system" => system, "version" => version, "error" => error}),
    do: "#{system} #{version} #{inspect(error)}"

  defp entry_summary(%{"system" => system, "version" => version}), do: "#{system} #{version} ok"
  defp entry_summary(entry), do: inspect(entry, limit: 3)

  defp describe(pairs), do: Enum.map_join(pairs, ", ", &"#{&1["system"]} #{&1["version"]}")

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
