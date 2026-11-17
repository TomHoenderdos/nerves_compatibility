defmodule Portal.Workers.HostNativeBuild do
  @moduledoc """
  Oban worker (queue `host_native_<arch>`, `Portal.HostNative.queue/1`)
  that builds one NIF package version on one toolchain image for one glibc
  Linux triple (`mode: "host_native"`, `NCC_INPUT.triple`, board #85) and
  hands the result to `Portal.Workers.Ingest` with `kind: "host_native"` and
  its own `package`, `version`, `toolchain` and `triple`, which the ingest
  checks the result against (`Portal.HostNative.Ingest`).

  Args: `package`, `version`, `toolchain` (`"1.20/29"`), `triple` and
  `builder_version`. Enqueued by `Portal.HostNative.enqueue/3`, only while
  the `host_native_enabled` setting is on; a job that runs once it is off is
  cancelled before anything is built, and so is one whose triple is not
  this node's own (a node of another architecture took it from a queue it
  should not run).

  Exit codes as `Portal.Workers.ToolchainBuild`'s: 0 with a result is
  ingested on this node's queue; 11 (lock policy) writes a `fail` row and
  cancels; anything else retries, and the last attempt writes an `error`
  row. Host-side refusals (disk, scratch, egress filter, memory limit) and an
  image without a digest snooze.
  """

  use Oban.Worker,
    queue: :host_native_x86_64,
    max_attempts: 2,
    unique: [
      fields: [:args, :worker],
      keys: [:package, :version, :toolchain, :triple, :builder_version],
      period: :infinity,
      states: :incomplete
    ]

  require Logger

  alias Compatibility.HostTriple
  alias Portal.Builder
  alias Portal.Catalog.HostNativeBuild
  alias Portal.NodeQueue
  alias Portal.Workers.{Ingest, ToolchainBuild}

  @zero_digest "sha256:" <> String.duplicate("0", 64)
  @snoozed [:egress_filter_missing, :build_memory_limit_missing, :scratch_noexec]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    cond do
      not Portal.HostNative.enabled?() ->
        {:cancel, "host-native builds are off"}

      not HostTriple.valid?(args["triple"]) ->
        {:cancel, "unknown triple #{inspect(args["triple"])}"}

      Portal.HostNative.own_triple() != {:ok, args["triple"]} ->
        {:cancel,
         "this node builds #{inspect(Portal.HostNative.own_triple())}, not #{args["triple"]}"}

      true ->
        case ToolchainBuild.split_toolchain(args["toolchain"]) do
          {:ok, toolchain} -> build_on(job, toolchain, local_image(args))
          :error -> {:cancel, "malformed toolchain #{inspect(args["toolchain"])}"}
        end
    end
  end

  defp local_image(args) do
    case Enum.find(Portal.Toolchains.images(), &(&1.toolchain == args["toolchain"])) do
      %{image: image} -> image
      nil -> nil
    end
  end

  defp build_on(_job, _toolchain, nil), do: {:snooze, 900}

  defp build_on(%Oban.Job{args: args} = job, toolchain, image) do
    case builder().image_digest(image) do
      @zero_digest ->
        Logger.warning("Host-native build #{describe(job)} waiting: #{image} has no digest")
        {:snooze, 900}

      digest ->
        run_id = run_id(args["package"], args["version"])

        build_args = %{
          package: args["package"],
          version: args["version"],
          run_id: run_id,
          image: image,
          image_digest: digest,
          mode: "host_native",
          toolchain: toolchain,
          triple: args["triple"]
        }

        build_args |> builder().build() |> handle(job, run_id, digest)
    end
  end

  defp handle({:ok, %{exit_code: 0, result: result}}, job, run_id, digest) when is_map(result),
    do: enqueue_ingest(job, run_id, digest)

  defp handle({:ok, %{exit_code: 11}}, job, run_id, digest) do
    builder().cleanup(run_id)
    write_row(job, :fail, "lock policy violation", run_id, digest)
    {:cancel, "lock policy violation"}
  end

  defp handle({:ok, %{exit_code: code}}, job, run_id, digest),
    do: retry(job, run_id, digest, "worker/runner exit #{code}")

  defp handle({:error, reason}, job, run_id, _digest)
       when reason in @snoozed or
              (is_tuple(reason) and elem(reason, 0) == :insufficient_disk) do
    Logger.error("Host-native build #{describe(job)} deferred: #{inspect(reason)}")
    builder().cleanup(run_id)
    {:snooze, 900}
  end

  defp handle({:error, reason}, job, run_id, digest),
    do: retry(job, run_id, digest, "builder error: #{inspect(reason)}")

  defp retry(job, run_id, digest, message) do
    Logger.warning("Host-native build retry for #{describe(job)}: #{message}")
    builder().cleanup(run_id)
    if job.attempt >= job.max_attempts, do: write_row(job, :error, message, run_id, digest)
    {:error, message}
  end

  defp enqueue_ingest(%Oban.Job{args: args}, run_id, digest) do
    ingest_args =
      args
      |> Map.take(["package", "version", "toolchain", "triple", "builder_version"])
      |> Map.merge(%{"kind" => "host_native", "run_id" => run_id, "image_digest" => digest})

    # This node's own queue: the scratch dir the ingest reads is on this disk.
    case ingest_args |> Ingest.new(queue: NodeQueue.name()) |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Could not enqueue host-native ingest for #{run_id}: #{inspect(reason)}")
        builder().cleanup(run_id)
        {:error, reason}
    end
  end

  # Best effort: the job's own outcome stands when the row cannot be
  # written. An `error` never replaces a stored `pass` or `skipped`.
  defp write_row(%Oban.Job{args: args}, status, reason, run_id, digest) do
    with id when is_binary(id) <- Portal.HostNative.package_id(args["package"]),
         false <- kept?(id, args, status) do
      HostNativeBuild
      |> Ash.Changeset.for_create(:upsert, %{
        package_id: id,
        version: args["version"],
        toolchain: args["toolchain"],
        triple: args["triple"],
        builder_version: args["builder_version"],
        status: status,
        reason: reason,
        run_id: run_id,
        image_digest: digest,
        finished_at: DateTime.utc_now()
      })
      |> Ash.create(domain: Portal.Catalog)
    end
  rescue
    e -> Logger.error("Could not write host-native row: #{Exception.message(e)}")
  end

  defp kept?(package_id, args, :error) do
    require Ash.Query

    HostNativeBuild
    |> Ash.Query.filter(
      package_id == ^package_id and version == ^args["version"] and
        toolchain == ^args["toolchain"] and triple == ^args["triple"] and
        builder_version == ^args["builder_version"] and status in [:pass, :skipped]
    )
    |> Ash.exists?(domain: Portal.Catalog)
  end

  defp kept?(_package_id, _args, _status), do: false

  defp describe(%Oban.Job{args: args}),
    do: "#{args["package"]} #{args["version"]} on #{args["toolchain"]} for #{args["triple"]}"

  defp run_id(package, version),
    do:
      "hn-#{package}-#{version}-#{System.system_time(:millisecond)}-" <>
        "#{System.unique_integer([:positive])}"

  @impl Oban.Worker
  def backoff(%Oban.Job{} = job), do: job |> Oban.Worker.backoff() |> min(3600)

  defp builder, do: Application.get_env(:portal, :build_runner, Builder)
end
