defmodule Portal.Workers.WarmNerves do
  @moduledoc """
  Oban worker that fills this host's Nerves cache (isolation spec, section 1).

  `Portal.Workers.Build` asks for one through `Portal.NervesCache.request_warm/3`
  with the pairs that passed the host-side limits. The job runs the worker
  container in `mode: "warm_nerves"` with those pairs
  (`Portal.Builder.build/2`), the one container that mounts the cache
  read-write; it runs only the template project and `nerves`-owned packages,
  and renames complete artifacts into place (`NccWorker.WarmNerves`).

  It runs on this node's own queue, `local_queue/0`, with concurrency 1: on
  the host whose cache missed, and never beside another warm. Jobs are unique
  on digest and pairs for a day over every state but discarded and cancelled
  (Oban's `:successful` group), which is the repeat bound: a run that reports
  the same misses again cannot churn the download, while a warm that failed
  can be retried at once. The default `fields` include the queue, so two hosts
  warm their own caches.
  """

  use Oban.Worker,
    # Never used: `enqueue/2` always puts the job on `local_queue/0`.
    queue: :warm_nerves,
    max_attempts: 3,
    unique: [period: 86_400, keys: [:image_digest, :pairs], states: :successful]

  require Logger

  alias Portal.Builder
  alias Portal.Workers.Ingest

  @doc "This node's own warm queue."
  @spec local_queue(node()) :: String.t()
  def local_queue(node \\ node()),
    do: String.replace_prefix(Ingest.local_queue(node), "ingest_", "warm_nerves_")

  @doc """
  `oban_config` with `node`'s warm queue added, limit 1, when the node runs
  builds (`Portal.Workers.Ingest.local_queue_limit/1`).
  """
  @spec with_local_queue(keyword(), node()) :: keyword()
  # The atom comes from the node name the release was started with, not from
  # any request: one per build host, created once at boot.
  # sobelow_skip ["DOS.StringToAtom"]
  def with_local_queue(oban_config, node \\ node()) do
    queues = Keyword.get(oban_config, :queues)

    case Ingest.local_queue_limit(queues) do
      nil ->
        oban_config

      _limit ->
        name = node |> local_queue() |> String.to_atom()
        queues = if Keyword.has_key?(queues, name), do: queues, else: queues ++ [{name, 1}]
        Keyword.put(oban_config, :queues, queues)
    end
  end

  @doc "Queue a warm of `pairs` for `image_digest` on this node."
  @spec enqueue(String.t(), [map()]) :: {:ok, Oban.Job.t()} | {:error, term()}
  def enqueue(image_digest, pairs) do
    %{"image_digest" => image_digest, "pairs" => pairs}
    |> new(queue: local_queue())
    |> Oban.insert()
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"image_digest" => digest, "pairs" => pairs}})
      when is_binary(digest) and is_list(pairs) do
    run_id = "warm_nerves-#{System.system_time(:millisecond)}"

    try do
      %{run_id: run_id, mode: "warm_nerves", nerves_packages: pairs, image_digest: digest}
      |> builder().build()
      |> outcome(pairs)
    after
      builder().cleanup(run_id)
    end
  end

  def perform(%Oban.Job{args: args}), do: {:cancel, "malformed warm args: #{inspect(args)}"}

  defp outcome({:ok, %{exit_code: 0, result: %{"warm" => warm}}}, pairs) when is_map(warm) do
    Logger.info(
      "Nerves cache warm of #{describe(pairs)}: installed #{inspect(warm["installed"])}, " <>
        "replaced #{inspect(warm["replaced"])}, not warmed #{inspect(warm["not_warmed"])}"
    )

    :ok
  end

  defp outcome({:ok, %{exit_code: 0}}, _pairs), do: {:error, :missing_warm_result}
  defp outcome({:ok, %{exit_code: code}}, _pairs), do: {:error, "warm container exited #{code}"}

  # Host conditions that resolve themselves, as for a build.
  defp outcome({:error, {:insufficient_disk, _free, _needed}}, _pairs), do: {:snooze, 900}
  defp outcome({:error, :scratch_noexec}, _pairs), do: {:snooze, 900}
  defp outcome({:error, :egress_filter_missing}, _pairs), do: {:snooze, 900}
  # Not one that resolves itself, but an operator's to fix, as for the filter.
  defp outcome({:error, :build_memory_limit_missing}, _pairs), do: {:snooze, 900}
  defp outcome({:error, reason}, _pairs), do: {:error, reason}

  defp describe([]), do: "the template"
  defp describe(pairs), do: Enum.map_join(pairs, ", ", &"#{&1["name"]} #{&1["version"]}")

  # Builder module is injectable for tests via `config :portal, :build_runner`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
