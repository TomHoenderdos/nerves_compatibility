defmodule Portal.Workers.ToolchainBuild do
  @moduledoc """
  Oban worker (queue `:toolchain`) that builds one pure-BEAM package version on
  one toolchain image (`mode: "toolchain"`, `NCC_INPUT.toolchain`) and hands the
  result to `Portal.Workers.Ingest` with `kind: "toolchain"`.

  Enqueued by `Portal.Workers.ToolchainSweep`. Args: `package`, `version`,
  `toolchain` (`"1.19/28"`), `image` (the local tag carrying it) and
  `builder_version` (`Portal.Toolchains.builder_version/0` at sweep time). The
  image digest is resolved here, on the build host that has the image.

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
  about a build that already worked.

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
      keys: [:package, :version, :toolchain, :builder_version],
      period: :infinity,
      states: :incomplete
    ]

  require Ash.Query
  require Logger

  alias Portal.Builder
  alias Portal.Catalog.LogSanitizer
  alias Portal.Catalog.Package
  alias Portal.Workers.Ingest

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    case split_toolchain(args["toolchain"]) do
      {:ok, toolchain} ->
        image_digest = builder().image_digest(args["image"])
        run_id = run_id(args["package"], args["version"])

        with_crash_cleanup(job, run_id, fn ->
          job
          |> build(run_id, image_digest, toolchain)
          |> handle(job, run_id, image_digest)
        end)

      :error ->
        {:cancel, "malformed toolchain #{inspect(args["toolchain"])}"}
    end
  end

  defp build(%Oban.Job{args: args}, run_id, image_digest, toolchain) do
    builder().build(%{
      package: args["package"],
      version: args["version"],
      run_id: run_id,
      image: args["image"],
      image_digest: image_digest,
      mode: "toolchain",
      toolchain: toolchain
    })
  end

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
      "toolchain" => args["toolchain"],
      "builder_version" => args["builder_version"]
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
  # own outcome stands.
  defp write_row(%Oban.Job{args: args} = job, status, reason, run_id, image_digest) do
    with %Package{id: package_id} <- package(args["package"]),
         false <- kept?(package_id, args) do
      Portal.Catalog.ToolchainBuild
      |> Ash.Changeset.for_create(:upsert, %{
        package_id: package_id,
        version: args["version"],
        toolchain: args["toolchain"],
        builder_version: args["builder_version"],
        status: status,
        reason: reason,
        image_digest: image_digest,
        run_id: run_id,
        finished_at: DateTime.utc_now()
      })
      |> Ash.create(domain: Portal.Catalog)
      |> case do
        {:ok, _row} -> :ok
        {:error, error} -> Logger.error("Toolchain row for #{describe(job)}: #{inspect(error)}")
      end
    else
      nil -> Logger.warning("No package #{args["package"]} to record #{describe(job)} against")
      true -> :ok
    end

    :ok
  rescue
    exception ->
      Logger.error("Toolchain row for #{describe(job)}: #{Exception.message(exception)}")
  end

  defp package(name) do
    Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Portal.Catalog)
  end

  # A pass or skipped row of the same identity stays as it is.
  defp kept?(package_id, args) do
    Portal.Catalog.ToolchainBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^args["version"] and
        toolchain == ^args["toolchain"] and builder_version == ^args["builder_version"] and
        status in [:pass, :skipped]
    )
    |> Ash.exists?(domain: Portal.Catalog)
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
    do: "#{args["package"]} #{args["version"]} on #{args["toolchain"]}"

  defp run_id(package, version),
    do: "tc-#{package}-#{version}-#{System.system_time(:millisecond)}"

  # A snooze raises `attempt`, and Oban's default backoff is quartic in it; cap
  # it at an hour as `Portal.Workers.Build` does.
  @impl Oban.Worker
  def backoff(%Oban.Job{} = job), do: job |> Oban.Worker.backoff() |> min(3600)

  # Injectable for tests via `config :portal, :build_runner`, as in `Build`.
  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
