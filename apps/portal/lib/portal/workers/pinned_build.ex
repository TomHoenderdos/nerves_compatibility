defmodule Portal.Workers.PinnedBuild do
  @moduledoc """
  Oban worker for one pinned build (lock-driven builds spec): a package
  version built against exactly the closure in `pins`
  (`Compatibility.Pins`), on one of two paths by `target`.

    * `"pure_elixir"` (phase 1, queue `:toolchain`): a pure-BEAM set on one
      toolchain image, as `mode: "toolchain"`, `optional_deps: "pinned"`.
      It is `Portal.Workers.ToolchainBuild`'s code path, not a copy:
      `perform/1` checks the set and hands the job to
      `ToolchainBuild.perform/1`, which runs the same image, sandbox, memory
      routing, deterministic sibling request and exit-code handling, and
      differs only in the input it sends (`pins`), the ingest it enqueues
      (`kind: "pinned"`, `Portal.Catalog.Ingestion.ingest_pinned/2`) and the
      row it writes when no ingest will (`write_row/5`).
    * a `nerves_system_*` (phase 2, queue `:builds`): a native set as a
      firmware build of that one target at its exact release
      (`system_version`), `Portal.Pins.FirmwareBuild`, on this node's own
      worker image and never through `Portal.Workers.Build`: no Run, no
      scan request, and a package's latest version is never touched.

  Its own worker name keeps it apart from every reader of toolchain and
  firmware build jobs, and its own `unique` keys (the pinned identity) from
  their backlogs'.

  Args: `package`, `version`, `toolchain` (`"1.20/29"`), `image` (the
  toolchain path's), `builder_version`, `target` (`targets/0`),
  `system_version` (a firmware target's release, `"2.1.2"`; absent for
  `pure_elixir`), `pin_hash` and `pins`, and `sibling_backfill: true` on a
  set `Portal.Pins.from_lock/2` queued only for its missing deterministic
  sibling. Enqueued by `Portal.Pins.from_lock/2`.

  A sibling backfill's rebuild replaces the key's row only with a pass whose
  sibling held. Any other outcome, a fail, a skip, an error, a timeout,
  another toolchain or a pass without its sibling, leaves the row, its
  files, memberships and status as they were and records only the attempt
  (`Portal.Catalog.Ingestion.backfill_attempted/2`); its ingest and the
  rows written here when no ingest will both take that rule. A set that does not validate, whose hash is not
  the job's, of a target this release does not build, or of a firmware
  target without one exact release, is cancelled before anything runs.
  """

  use Oban.Worker,
    queue: :toolchain,
    max_attempts: 2,
    # `Portal.Pins.from_lock/2`'s, for a job inserted without one.
    priority: 3,
    unique: [
      fields: [:args, :worker],
      keys: [
        :package,
        :version,
        :pin_hash,
        :target,
        :system_version,
        :toolchain,
        :builder_version
      ],
      period: :infinity,
      states: :incomplete
    ]

  require Logger

  alias Portal.Catalog.{Ingestion, PinnedBuild}
  alias Portal.Pins.FirmwareBuild
  alias Portal.Workers.ToolchainBuild

  @doc """
  The targets this release builds pinned: `pure_elixir` (phase 1) and every
  firmware target (`firmware_targets/0`, phase 2).
  """
  @spec targets() :: [String.t()]
  def targets, do: ["pure_elixir" | firmware_targets()]

  @doc """
  The firmware targets a pinned build may have: the systems the worker
  builds (`Portal.BulkRebuild.targets/0`).
  """
  @spec firmware_targets() :: [String.t()]
  def firmware_targets, do: Portal.BulkRebuild.targets()

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    with {:ok, path} <- check_target(args["target"], args["system_version"]),
         {:ok, pins} <-
           Compatibility.Pins.validate(args["package"], args["version"], args["pins"]),
         true <- pins["hash"] == args["pin_hash"] || {:error, :pin_hash_differs} do
      case path do
        :toolchain -> ToolchainBuild.perform(job)
        :firmware -> FirmwareBuild.perform(job)
      end
    else
      {:error, reason} -> {:cancel, "pinned build #{describe(args)}: #{inspect(reason)}"}
    end
  end

  # A firmware target is built at one exact release, a `pure_elixir` one at
  # none.
  defp check_target("pure_elixir", version) when version in [nil, ""], do: {:ok, :toolchain}

  defp check_target(target, version) do
    if target in firmware_targets() and exact_version?(version),
      do: {:ok, :firmware},
      else: {:error, {:unknown_target, target, version}}
  end

  defp exact_version?(version),
    do: is_binary(version) and match?({:ok, _}, Version.parse(version))

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
      system_version: args["system_version"] || "",
      toolchain: args["toolchain"],
      builder_version: args["builder_version"],
      config_variant: "default"
    }
  end

  @doc false
  # The row `ToolchainBuild` or `Portal.Pins.FirmwareBuild` writes when no
  # ingest will (exit 11's or a timeout's `fail`, a last attempt's `error`),
  # under the identity's lock. An `error` never replaces a pass or skipped
  # row, and a `fail` never a served pass, as a failed compile never does at
  # ingest (`Ingestion.pinned_row/4`): a stale attempt, whose job a later
  # attempt finished, must not take that build down. The kept row records
  # the attempt instead.
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

  # A package the catalog does not hold yet is created with its name alone,
  # as an ingest creates one: without the row, the next `from_lock` would
  # queue the same build again.
  defp write_locked(args, identity, status, reason, run_id, image_digest) do
    {:ok, package_id} = Ingestion.ensure_package_id(args["package"])

    case backfill_kept(args, package_id, identity) do
      {:ok, _row} -> :ok
      nil -> write_verdict(package_id, args, identity, status, reason, run_id, image_digest)
    end
  end

  # A sibling backfill's rebuild that wrote no result keeps the key's row
  # and records only the attempt (`Ingestion.backfill_attempted/2`).
  defp backfill_kept(args, package_id, identity) do
    if backfill?(args), do: Ingestion.backfill_attempted(package_id, identity)
  end

  defp write_verdict(package_id, args, identity, status, reason, run_id, image_digest) do
    case kept(status, package_id, identity) do
      nil ->
        upsert(package_id, args, identity, status, reason, run_id, image_digest)

      kept ->
        kept |> Ash.Changeset.for_update(:retried, %{}) |> Ash.update!(domain: Portal.Catalog)
    end
  end

  @doc "Whether a job is a sibling backfill (`Portal.Pins.from_lock/2`)."
  @spec backfill?(map()) :: boolean()
  def backfill?(args), do: Map.get(args, "sibling_backfill") == true

  defp kept(:error, package_id, identity),
    do: Ingestion.pinned_row(package_id, identity, [:pass, :skipped], false)

  defp kept(:fail, package_id, identity),
    do: Ingestion.pinned_row(package_id, identity, [:pass], true)

  defp kept(_status, _package_id, _identity), do: nil

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
      sibling_attempted: backfill?(args),
      finished_at: DateTime.utc_now()
    })
    |> then(&Ash.Changeset.for_create(PinnedBuild, :upsert, &1))
    |> Ash.create!(domain: Portal.Catalog)
  end

  @doc false
  def describe(args),
    do:
      "#{args["package"]} #{args["version"]} pinned #{String.slice(to_string(args["pin_hash"]), 0, 12)} " <>
        "on #{args["toolchain"]}" <> describe_system(args)

  defp describe_system(%{"target" => "nerves_system_" <> _ = target} = args),
    do: " for #{target} #{args["system_version"]}"

  defp describe_system(_args), do: ""
end
