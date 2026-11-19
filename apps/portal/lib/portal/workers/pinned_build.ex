defmodule Portal.Workers.PinnedBuild do
  @moduledoc """
  Oban worker (queue `:toolchain`) for one pinned build (lock-driven builds
  spec, phase 1): a pure-BEAM package version built on one toolchain image
  against exactly the closure in `pins` (`Compatibility.Pins`), as
  `mode: "toolchain"`, `optional_deps: "pinned"`.

  It is `Portal.Workers.ToolchainBuild`'s code path, not a copy: `perform/1`
  checks the set and hands the job to `ToolchainBuild.perform/1`, which runs
  the same image, sandbox, memory routing, deterministic sibling request
  and exit-code handling, and differs only in the input it sends (`pins`),
  the ingest it enqueues (`kind: "pinned"`, `Portal.Catalog.Ingestion.ingest_pinned/2`)
  and the row it writes when no ingest will (`write_row/5`). Its own worker
  name keeps it apart from every reader of toolchain build jobs, and its own
  `unique` keys (the pinned identity) from the toolchain backlog's.

  Args: `package`, `version`, `toolchain` (`"1.20/29"`), `image`,
  `builder_version`, `target` (`"pure_elixir"`; phase 2 adds firmware
  targets), `pin_hash` and `pins`. Enqueued by `Portal.Pins.queue/2`. A set
  that does not validate, or whose hash is not the job's, is cancelled
  before anything runs.
  """

  use Oban.Worker,
    queue: :toolchain,
    max_attempts: 2,
    priority: 9,
    unique: [
      fields: [:args, :worker],
      keys: [:package, :version, :pin_hash, :target, :toolchain, :builder_version],
      period: :infinity,
      states: :incomplete
    ]

  require Logger

  alias Portal.Catalog.{Ingestion, PinnedBuild}
  alias Portal.Workers.ToolchainBuild

  @targets ["pure_elixir"]

  @doc "The targets this release builds pinned: `pure_elixir` only (phase 1)."
  @spec targets() :: [String.t()]
  def targets, do: @targets

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with :ok <- check_target(args["target"]),
         {:ok, pins} <-
           Compatibility.Pins.validate(args["package"], args["version"], args["pins"]),
         true <- pins["hash"] == args["pin_hash"] || {:error, :pin_hash_differs} do
      ToolchainBuild.perform(job)
    else
      {:error, reason} -> {:cancel, "pinned build #{describe(args)}: #{inspect(reason)}"}
    end
  end

  defp check_target(target) when target in @targets, do: :ok
  defp check_target(target), do: {:error, {:unknown_target, target}}

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job), do: ToolchainBuild.backoff(job)

  @doc false
  # The pinned identity of a job's args, as `Ingestion.ingest_pinned/2` and
  # `Ingestion.lock_pinned_identity/1` take it.
  @spec identity(map()) :: map()
  def identity(args) do
    %{
      package: args["package"],
      version: args["version"],
      pin_hash: args["pin_hash"],
      target: args["target"],
      system_version: "",
      toolchain: args["toolchain"],
      builder_version: args["builder_version"],
      config_variant: "default"
    }
  end

  @doc false
  # The row `ToolchainBuild` writes when no ingest will (exit 11's `fail`, a
  # last attempt's `error`), under the identity's lock. An `error` never
  # replaces a pass or skipped row; that row records the attempt instead.
  @spec write_row(map(), atom(), String.t(), String.t(), String.t() | nil) :: :ok
  def write_row(args, status, reason, run_id, image_digest) do
    identity = identity(args)

    Portal.Repo.transaction(fn ->
      :ok = Ingestion.lock_pinned_identity(identity)
      write_locked(args, identity, status, reason, run_id, image_digest)
    end)

    :ok
  rescue
    exception -> Logger.error("Pinned row for #{describe(args)}: #{Exception.message(exception)}")
  end

  defp write_locked(args, identity, status, reason, run_id, image_digest) do
    case Portal.HostNative.package_id(args["package"]) do
      nil ->
        Logger.warning("No package #{args["package"]} to record #{describe(args)} against")

      package_id ->
        kept =
          status == :error and
            Ingestion.pinned_row(package_id, identity, [:pass, :skipped], false)

        if kept,
          do:
            kept |> Ash.Changeset.for_update(:retried, %{}) |> Ash.update!(domain: Portal.Catalog),
          else: upsert(package_id, args, identity, status, reason, run_id, image_digest)
    end
  end

  defp upsert(package_id, args, identity, status, reason, run_id, image_digest) do
    identity
    |> Map.drop([:package])
    |> Map.merge(%{
      package_id: package_id,
      pins: args["pins"],
      status: status,
      reason: reason,
      run_id: run_id,
      image_digest: image_digest,
      finished_at: DateTime.utc_now()
    })
    |> then(&Ash.Changeset.for_create(PinnedBuild, :upsert, &1))
    |> Ash.create!(domain: Portal.Catalog)
  end

  @doc false
  def describe(args),
    do:
      "#{args["package"]} #{args["version"]} pinned #{String.slice(to_string(args["pin_hash"]), 0, 12)} " <>
        "on #{args["toolchain"]}"
end
