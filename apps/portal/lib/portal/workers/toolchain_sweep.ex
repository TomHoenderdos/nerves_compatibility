defmodule Portal.Workers.ToolchainSweep do
  @moduledoc """
  Oban worker (queue `:maintenance`, daily cron and the admin Maintenance
  button) that enqueues a `Portal.Workers.ToolchainBuild` for every package
  version and optional-deps variant still missing a build on a configured
  toolchain (`Portal.Catalog.toolchain_backlog/3`), at most
  `Portal.Toolchains.max_per_run/0` in total.

  A `with` build is queued ahead of a `without` one (a lower Oban priority):
  it is the build a fresh project resolves, and the `without` build is only
  wanted because a `with` build exists.

  The cap is shared round-robin: each toolchain's backlog is taken in its own
  priority order (most downloaded first, see `Catalog.toolchain_backlog/3`)
  and the toolchains take turns, so one toolchain with a long backlog cannot
  starve the others inside a run. A toolchain with less backlog than its
  share leaves the rest to the others.

  A refresh (`refresh` in `Catalog.toolchain_backlog/3`: a rebuild of a build
  already served, only to record its compile-time config reads) comes after
  every other build of every toolchain, and is queued at priority 3, below
  both variants: what nobody has yet waits for no refresh, in the run or in
  the queue.

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

    backlogs =
      Enum.map(Toolchains.images(), fn image ->
        image.toolchain
        |> Catalog.toolchain_backlog(builder_version, cap)
        |> Enum.map(&{build_args(&1, image, builder_version), &1.refresh})
      end)

    # Every toolchain's builds, round-robin, then every toolchain's refreshes.
    picked =
      [false, true]
      |> Enum.flat_map(&round_robin(only(backlogs, &1)))
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

  # Each toolchain's backlog, keeping only the entries whose `refresh` is
  # `refresh`, in their order.
  defp only(backlogs, refresh) do
    Enum.map(backlogs, fn backlog -> Enum.filter(backlog, &(elem(&1, 1) == refresh)) end)
  end

  defp build_args(
         %{package: package, version: version, variant: variant, config_variant: config_variant},
         image,
         builder_version
       ) do
    %{
      package: package,
      version: version,
      toolchain: image.toolchain,
      image: image.image,
      builder_version: builder_version,
      variant: variant,
      config_variant: config_variant
    }
  end

  defp enqueue({args, refresh}) do
    case args |> ToolchainBuild.new(priority: priority(args.variant, refresh)) |> Oban.insert() do
      {:ok, %Oban.Job{conflict?: true}} ->
        {args.toolchain, :pending}

      {:ok, _job} ->
        {args.toolchain, :enqueued}

      {:error, reason} ->
        Logger.error(
          "Toolchain sweep could not enqueue #{args.package} #{args.version} " <>
            "(#{args.variant}) on #{args.toolchain}: #{inspect(reason)}"
        )

        {args.toolchain, :failed}
    end
  end

  defp priority(_variant, true), do: 3
  defp priority(:with, false), do: 0
  defp priority(:without, false), do: 1

  # [[a1, a2, a3], [b1]] -> [a1, b1, a2, a3]
  defp round_robin(lists) do
    case Enum.reject(lists, &(&1 == [])) do
      [] -> []
      lists -> Enum.map(lists, &hd/1) ++ round_robin(Enum.map(lists, &tl/1))
    end
  end
end
