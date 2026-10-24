defmodule Portal.Workers.ToolchainSweep do
  @moduledoc """
  Oban worker (queue `:maintenance`, daily cron and the admin Maintenance
  button) that enqueues a `Portal.Workers.ToolchainBuild` for every package
  version still missing a build on a configured toolchain
  (`Portal.Catalog.toolchain_backlog/3`), at most
  `Portal.Toolchains.max_per_run/0` in total.

  The cap is shared round-robin: each toolchain's backlog is taken in its own
  priority order (newest three versions per package first) and the toolchains
  take turns, so one toolchain with a long backlog cannot starve the others
  inside a run. A toolchain with less backlog than its share leaves the rest
  to the others.

  Jobs are inserted one at a time rather than with `Oban.insert_all/1`, which
  does not check `unique`: a build the previous sweep enqueued and the
  single-slot `:toolchain` queue has not reached yet is still backlog, and has
  to conflict rather than be queued twice. A conflict still counts against the
  cap; the queue's limit of 1, not the count, bounds the load.
  """

  use Oban.Worker,
    queue: :maintenance,
    unique: [period: 86_400, states: :incomplete]

  require Logger

  alias Portal.Catalog
  alias Portal.Toolchains
  alias Portal.Workers.ToolchainBuild

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cap = Toolchains.max_per_run()
    builder_version = Toolchains.builder_version()

    picked =
      Toolchains.images()
      |> Enum.map(fn image ->
        image.toolchain
        |> Catalog.toolchain_backlog(builder_version, cap)
        |> Enum.map(&build_args(&1, image, builder_version))
      end)
      |> round_robin()
      |> Enum.take(cap)

    counts = Enum.frequencies_by(picked, &enqueue/1)

    for %{toolchain: toolchain} <- Toolchains.images() do
      enqueued = Map.get(counts, {toolchain, :enqueued}, 0)
      pending = Map.get(counts, {toolchain, :pending}, 0)

      Logger.info(
        "Toolchain sweep #{toolchain} (builder #{builder_version}): " <>
          "enqueued #{enqueued}, already queued #{pending}"
      )
    end

    :ok
  end

  @doc "Queue a sweep now (the admin button). `{:error, :already_queued}` while one is pending."
  @spec enqueue() :: {:ok, Oban.Job.t()} | {:error, :already_queued | term()}
  def enqueue do
    case %{} |> new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} -> {:error, :already_queued}
      other -> other
    end
  end

  defp build_args(%{package: package, version: version}, image, builder_version) do
    %{
      package: package,
      version: version,
      toolchain: image.toolchain,
      image: image.image,
      builder_version: builder_version
    }
  end

  defp enqueue(args) do
    case args |> ToolchainBuild.new() |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        {args.toolchain, :pending}

      {:ok, _job} ->
        {args.toolchain, :enqueued}

      {:error, reason} ->
        Logger.error(
          "Toolchain sweep could not enqueue #{args.package} #{args.version} " <>
            "on #{args.toolchain}: #{inspect(reason)}"
        )

        {args.toolchain, :failed}
    end
  end

  # [[a1, a2, a3], [b1]] -> [a1, b1, a2, a3]
  defp round_robin(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ round_robin(Enum.map(lists, &tl/1))
    end
  end
end
