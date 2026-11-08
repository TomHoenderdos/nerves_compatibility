defmodule Portal.Workers.ToolchainBuild do
  @moduledoc """
  Oban worker (queue `:toolchain`) that builds one pure-BEAM package version on
  one toolchain image (`mode: "toolchain"`, `NCC_INPUT.toolchain`) and hands the
  result to `Portal.Workers.Ingest` with `kind: "toolchain"` and its own
  `package`, `version` and `toolchain`, which the ingest checks the result
  against.

  Enqueued by `Portal.Workers.ToolchainSweep`. Args: `package`, `version`,
  `toolchain` (`"1.19/28"`), `image` (the tag the sweeping node has configured
  for it), `builder_version` (`Portal.Toolchains.builder_version/0` at sweep
  time) and `variant` (`"with"` or `"without"` the package's optional
  dependencies, see `Portal.Catalog.ToolchainBuild`), which the worker gets as
  `optional_deps: "include" | "exclude"`. A job without a `variant`, queued
  before variants existed, is a `with` build. `config_variant` is a
  `Compatibility.ConfigVariants` name; a job without one, queued before config
  variants, is `"default"`; the sweep always sets it, since Oban's unique match
  is a containment that a missing key would widen. A name the worker does not
  know cancels the job before anything runs. The image and its digest are
  resolved here, on the build host that has the images: the toolchain's image
  in this node's own `Portal.Toolchains.images/0`, and the job's `image` only
  when this node does not configure the toolchain at all.

  Exit-code contract, as `Portal.Workers.Build`'s:

      worker   0  -> a written result (pass, skipped, or a failed host
                     compile, which the ingest stores as `fail`) → ingest
                     on this node's queue
      worker  11  -> lock policy violation → `fail` row, cancel
      worker  10  -> no result at all (e.g. `mix new` or `deps.get` failed)
                     → retry
      host 20/21  -> runner error on the build host → retry

  The ingest writes the row for a finished build. The worker writes it itself
  only when no ingest will: a `fail` for exit 11, and an `error` once the last
  attempt of a retryable failure is spent, which is what lets the sweep's
  day-old-error rule retry it later. An `error` never replaces a `pass` or
  `skipped` row of the same identity: a transient host problem is not news
  about a build that already worked. The kept row records the failed attempt
  as `attempted_at`, since the sweep re-opens such a row by its last attempt
  and would otherwise queue it again at once; its `finished_at` stays the
  build's own.

  `max_attempts` is 2, not `Build`'s 3. A compile failure is a verdict and
  never retried; what is left to retry (exit 10, or 20/21 from the host) is
  either a transient flake, which one more attempt covers, or something that
  fails the same way every time, such as a version whose deps do not resolve,
  where more attempts are wasted builds. The sweep's day-old-error rule gives
  an `error` row another try later anyway.
  """

  use Oban.Worker,
    queue: :toolchain,
    max_attempts: 2,
    # One build per identity while one is pending or running. A `Build` job for
    # the same package and version is another worker, so it never conflicts.
    unique: [
      keys: [:package, :version, :toolchain, :builder_version, :variant, :config_variant],
      period: :infinity,
      states: :incomplete
    ]

  require Ash.Query
  require Logger

  alias Compatibility.ConfigVariants
  alias Portal.Builder
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.LogSanitizer
  alias Portal.Catalog.Package
  alias Portal.Workers.Ingest

  @zero_digest "sha256:" <> String.duplicate("0", 64)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    name = config_variant(args)

    if ConfigVariants.known?(name) do
      perform_known(job)
    else
      {:cancel, "unknown config variant #{inspect(name)}"}
    end
  end

  defp perform_known(%Oban.Job{args: args} = job) do
    case split_toolchain(args["toolchain"]) do
      {:ok, toolchain} ->
        image = local_image(args)
        build_on(job, toolchain, image, builder().image_digest(image))

      :error ->
        {:cancel, "malformed toolchain #{inspect(args["toolchain"])}"}
    end
  end

  # `Builder.image_digest/1` answers with the zero digest when it cannot
  # inspect the image: it is missing on this host or docker is not answering.
  # Neither is news about the package, so wait for the image rather than spend
  # an attempt or write a row.
  defp build_on(job, _toolchain, image, @zero_digest) do
    Logger.warning(
      "Toolchain build #{describe(job)} waiting: image #{inspect(image)} has no digest"
    )

    {:snooze, 900}
  end

  defp build_on(%Oban.Job{args: args} = job, toolchain, image, image_digest) do
    run_id = run_id(args["package"], args["version"])

    with_crash_cleanup(job, run_id, fn ->
      job
      |> build(run_id, image, image_digest, toolchain)
      |> handle(job, run_id, image_digest)
    end)
  end

  # The sweep runs on the web host and names the image from that node's
  # `NCC_TOOLCHAINS`; the image that runs is the one this node, which has the
  # images, configures for the toolchain.
  defp local_image(args) do
    case Enum.find(Portal.Toolchains.images(), &(&1.toolchain == args["toolchain"])) do
      %{image: image} ->
        image

      nil ->
        Logger.warning(
          "Toolchain #{args["toolchain"]} is not configured on this node; " <>
            "building on the job's image #{inspect(args["image"])}"
        )

        args["image"]
    end
  end

  defp build(%Oban.Job{args: args}, run_id, image, image_digest, toolchain) do
    builder().build(%{
      package: args["package"],
      version: args["version"],
      run_id: run_id,
      image: image,
      image_digest: image_digest,
      mode: "toolchain",
      toolchain: toolchain,
      optional_deps: optional_deps(variant(args)),
      config_variant: input_config_variant(config_variant(args))
    })
  end

  defp variant(%{"variant" => "without"}), do: :without
  defp variant(_args), do: :with

  defp optional_deps(:with), do: "include"
  defp optional_deps(:without), do: "exclude"

  defp config_variant(args), do: Map.get(args, "config_variant", "default")

  # The worker's NCC_INPUT names a variant only when it has an overlay.
  defp input_config_variant("default"), do: nil
  defp input_config_variant(name), do: name

  defp handle({:ok, %{exit_code: 0, result: result}}, job, run_id, image_digest)
       when is_map(result) do
    # No cleanup: the ingest reads the scratch dir and removes it.
    enqueue_ingest(job, run_id, image_digest)
  end

  defp handle({:ok, %{exit_code: 0} = build}, job, run_id, image_digest) do
    retry(job, run_id, image_digest, "missing result.json", excerpt_from(build.log))
  end

  defp handle({:ok, %{exit_code: 11}}, job, run_id, image_digest) do
    builder().cleanup(run_id)
    reason = "lock policy violation"
    write_row(job, :fail, reason, run_id, image_digest)
    {:cancel, reason}
  end

  defp handle({:ok, %{exit_code: exit_code} = build}, job, run_id, image_digest) do
    retry(job, run_id, image_digest, "worker/runner exit #{exit_code}", excerpt_from(build.log))
  end

  # A full disk or a noexec scratch root is the host's problem and clears up
  # on its own or not at all; as in `Portal.Workers.Build`, wait rather than
  # spend the attempts.
  defp handle({:error, {:insufficient_disk, _free, _needed}}, %Oban.Job{} = job, run_id, _digest) do
    Logger.error("Toolchain build deferred for #{describe(job)}: not enough disk")
    builder().cleanup(run_id)
    {:snooze, 900}
  end

  defp handle({:error, :scratch_noexec}, job, run_id, _digest) do
    Logger.error("Scratch root cannot execute files; refusing toolchain build #{describe(job)}")
    builder().cleanup(run_id)
    {:snooze, 900}
  end

  defp handle({:error, :egress_filter_missing}, job, run_id, _digest) do
    Logger.error("Build egress filter missing; refusing toolchain build #{describe(job)}")
    builder().cleanup(run_id)
    {:snooze, 900}
  end

  defp handle({:error, :build_memory_limit_missing}, job, run_id, _digest) do
    Logger.error("No build memory limit on this host; refusing toolchain build #{describe(job)}")
    builder().cleanup(run_id)
    {:snooze, 900}
  end

  defp handle({:error, reason}, job, run_id, image_digest) do
    # Read before cleanup removes it.
    log = excerpt_from_file(Builder.runner_log_path(run_id))
    retry(job, run_id, image_digest, "builder error: #{inspect(reason)}", log, reason)
  end

  defp retry(job, run_id, image_digest, message, log, error \\ nil) do
    Logger.warning("Toolchain build retry for #{describe(job)}: #{message}")
    builder().cleanup(run_id)

    if job.attempt >= job.max_attempts do
      write_row(job, :error, reason(message, log), run_id, image_digest)
    end

    {:error, error || message}
  end

  defp enqueue_ingest(%Oban.Job{args: args}, run_id, image_digest) do
    ingest_args = %{
      "kind" => "toolchain",
      "run_id" => run_id,
      "image_digest" => image_digest,
      # The package, version and toolchain this job was queued for, not
      # whatever the result reports: the ingest checks the result against
      # them and keys the row on them, so the row and the sweep's backlog
      # agree on the identity (see `Portal.Workers.Ingest`).
      "package" => args["package"],
      "version" => args["version"],
      "toolchain" => args["toolchain"],
      "builder_version" => args["builder_version"],
      "variant" => Atom.to_string(variant(args)),
      "config_variant" => config_variant(args)
    }

    # This node's own queue: the scratch dir the ingest reads is on this disk.
    case ingest_args |> Ingest.new(queue: Ingest.local_queue()) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not enqueue toolchain ingest for #{run_id}: #{inspect(reason)}")
        builder().cleanup(run_id)
        {:error, reason}
    end
  end

  # Best-effort: the row is what keeps the sweep from re-enqueueing the build
  # tomorrow, not the job's result. Failing to write it is logged and the job's
  # own outcome stands. It runs under the identity's lock, as an ingest does
  # (`Ingestion.lock_toolchain_identity/1`). An `:error` is no verdict, so it
  # keeps the transient count of the `:error` row it replaces; a `:fail`
  # (exit 11) is one and resets it.
  defp write_row(%Oban.Job{args: args} = job, status, reason, run_id, image_digest) do
    identity = %{
      package: args["package"],
      version: args["version"],
      toolchain: args["toolchain"],
      builder_version: args["builder_version"],
      variant: variant(args),
      config_variant: config_variant(args)
    }

    # A failed create inside it can roll the transaction back before
    # `write_locked_row/6` logs it, so log the rollback here.
    Portal.Repo.transaction(fn ->
      :ok = Ingestion.lock_toolchain_identity(identity)
      write_locked_row(job, identity, status, reason, run_id, image_digest)
    end)
    |> case do
      {:error, error} -> Logger.error("Toolchain row for #{describe(job)}: #{inspect(error)}")
      {:ok, _} -> :ok
    end

    :ok
  rescue
    exception ->
      Logger.error("Toolchain row for #{describe(job)}: #{Exception.message(exception)}")
  end

  defp write_locked_row(job, identity, status, reason, run_id, image_digest) do
    with %Package{id: package_id} <- package(identity.package),
         nil <- kept(package_id, job.args) do
      Portal.Catalog.ToolchainBuild
      |> Ash.Changeset.for_create(:upsert, %{
        package_id: package_id,
        version: identity.version,
        toolchain: identity.toolchain,
        builder_version: identity.builder_version,
        variant: identity.variant,
        config_variant: identity.config_variant,
        status: status,
        reason: reason,
        image_digest: image_digest,
        run_id: run_id,
        transient_attempts: transient_attempts(status, package_id, identity),
        finished_at: DateTime.utc_now()
      })
      |> Ash.create(domain: Portal.Catalog)
      |> case do
        {:ok, _row} -> :ok
        {:error, error} -> Logger.error("Toolchain row for #{describe(job)}: #{inspect(error)}")
      end
    else
      nil -> Logger.warning("No package #{identity.package} to record #{describe(job)} against")
      %Portal.Catalog.ToolchainBuild{} = row -> retried(row, job)
    end
  end

  defp transient_attempts(:error, package_id, identity),
    do: Ingestion.previous_transient_attempts(package_id, identity)

  defp transient_attempts(_verdict, _package_id, _identity), do: 0

  defp package(name) do
    Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Portal.Catalog)
  end

  # A pass or skipped row of the same identity stays as it is, verdict and
  # files alike.
  defp kept(package_id, args) do
    variant = variant(args)
    config_variant = config_variant(args)

    Portal.Catalog.ToolchainBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^args["version"] and
        toolchain == ^args["toolchain"] and builder_version == ^args["builder_version"] and
        variant == ^variant and config_variant == ^config_variant and
        status in [:pass, :skipped]
    )
    |> Ash.Query.limit(1)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  # The sweep re-queues a kept row once it has aged (a `skipped` for shipping
  # priv files, a `pass` that dropped its optional dependencies for a
  # transient reason or does not record its compile-time config reads, or a
  # row revoked for its withheld closure, all after 7 days; see
  # `Portal.Catalog.toolchain_backlog/3`). Its failed rebuild records the
  # attempt, so the identity waits out the week again instead of coming back
  # in every sweep; `finished_at` is left alone.
  defp retried(row, job) do
    case row |> Ash.Changeset.for_update(:retried, %{}) |> Ash.update(domain: Portal.Catalog) do
      {:ok, _row} -> :ok
      {:error, error} -> Logger.error("Toolchain row for #{describe(job)}: #{inspect(error)}")
    end
  end

  defp reason(message, nil), do: message
  defp reason(message, log), do: message <> "\n\n" <> log

  # Every terminal path above cleans up by returning; an exception would skip
  # them and leave the scratch dir and no row behind. Do the same bookkeeping,
  # then re-raise so Oban still sees the real error.
  defp with_crash_cleanup(job, run_id, fun) do
    fun.()
  rescue
    exception ->
      crash_cleanup(job, run_id, Exception.message(exception))
      reraise exception, __STACKTRACE__
  end

  defp crash_cleanup(job, run_id, message) do
    Logger.error("Toolchain build crashed for run #{run_id}: #{message}")
    log = safely(fn -> excerpt_from_file(Builder.runner_log_path(run_id)) end)
    safely(fn -> builder().cleanup(run_id) end)

    if job.attempt >= job.max_attempts do
      safely(fn ->
        write_row(job, :error, reason("build crashed: #{message}", log), run_id, nil)
      end)
    end
  end

  defp safely(fun) do
    fun.()
  rescue
    _ -> nil
  end

  defp excerpt_from(raw) when is_binary(raw) and raw != "", do: LogSanitizer.runner_excerpt(raw)
  defp excerpt_from(_raw), do: nil

  defp excerpt_from_file(path) do
    case LogSanitizer.runner_excerpt_file(path) do
      {:ok, ""} -> nil
      {:ok, excerpt} -> excerpt
      {:error, _reason} -> nil
    end
  end

  @doc false
  # `"1.19/28"` → `%{elixir: "1.19", otp: "28"}`, the shape `NCC_INPUT.toolchain` takes.
  @spec split_toolchain(term()) :: {:ok, %{elixir: String.t(), otp: String.t()}} | :error
  def split_toolchain(toolchain) when is_binary(toolchain) do
    case String.split(toolchain, "/") do
      [elixir, otp] when elixir != "" and otp != "" -> {:ok, %{elixir: elixir, otp: otp}}
      _ -> :error
    end
  end

  def split_toolchain(_toolchain), do: :error

  defp describe(%Oban.Job{args: args}),
    do:
      "#{args["package"]} #{args["version"]} (#{variant(args)}) on #{args["toolchain"]}" <>
        describe_config_variant(config_variant(args))

  defp describe_config_variant("default"), do: ""
  defp describe_config_variant(name), do: " [#{name}]"

  defp run_id(package, version),
    do: "tc-#{package}-#{version}-#{System.system_time(:millisecond)}"

  # A snooze raises `attempt`, and Oban's default backoff is quartic in it; cap
  # it at an hour as `Portal.Workers.Build` does.
  @impl Oban.Worker
  def backoff(%Oban.Job{} = job), do: job |> Oban.Worker.backoff() |> min(3600)

  # Injectable for tests via `config :portal, :build_runner`, as in `Build`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
