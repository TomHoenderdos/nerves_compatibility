defmodule Portal.Catalog.RunMemory do
  @moduledoc """
  The memory one worker container used: one row per container run on this
  host, firmware, toolchain or warm, whatever its outcome.

  The peaks come from the worker's `resources.json` side file
  (`NccWorker.Resources`, `Portal.Builder.read_resources/1`), which it
  rewrites after every sample, so a container the kernel OOM-killed, which
  never writes `result.json`, still has its last record. A run with no side
  file at all is still a row, with nil peaks: it is a run worth counting.

  `run_id` is the builder run id (`tc-jason-1.4.4-...`), not a foreign key:
  most of these runs never become a `Portal.Catalog.Run`.

  The Oban workers that call `Portal.Builder.build/2` write the row through
  `record/4` as soon as it returns, before the scratch dir is removed. A
  build that never reached `docker run` (a host-condition refusal, docker
  unavailable, scratch setup) writes no row.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  require Logger

  alias Portal.Builder

  @kinds [:firmware, :toolchain, :warm]

  # `:integer` columns are bigint.
  @max_bigint 9_223_372_036_854_775_807

  postgres do
    table("catalog_run_memory")
    repo(Portal.Repo)

    custom_indexes do
      index([:package, :kind, :finished_at])
      index([:finished_at])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([
        :run_id,
        :kind,
        :package,
        :version,
        :toolchain,
        :image_digest,
        :host,
        :attempt,
        :exit_code,
        :timed_out,
        :oom_killed,
        :memory_limit_bytes,
        :cpus,
        :build_concurrency,
        :peak_used_bytes,
        :peak_total_bytes,
        :samples,
        :started_at,
        :finished_at
      ])
    end
  end

  attributes do
    uuid_primary_key(:id)

    attribute :run_id, :string do
      allow_nil?(false)
      public?(true)
    end

    attribute :kind, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: @kinds)
    end

    # Nil for a warm run, which builds no package.
    attribute(:package, :string, public?: true)
    attribute(:version, :string, public?: true)
    # `"1.19/28"` for a toolchain run, nil otherwise.
    attribute(:toolchain, :string, public?: true)
    attribute(:image_digest, :string, public?: true)
    # The node that ran the container.
    attribute(:host, :string, public?: true)
    attribute(:attempt, :integer, public?: true)
    # Nil only for a wall-clock timeout (`timed_out`), which returns no exit code.
    attribute(:exit_code, :integer, public?: true)
    attribute(:timed_out, :boolean, allow_nil?: false, default: false, public?: true)
    # Exit 137: the container was SIGKILLed, which under `--memory` is the OOM killer.
    attribute(:oom_killed, :boolean, allow_nil?: false, default: false, public?: true)
    attribute(:memory_limit_bytes, :integer, public?: true)
    # `NCC_BUILD_CPUS` as configured, e.g. `"2"`.
    attribute(:cpus, :string, public?: true)
    attribute(:build_concurrency, :integer, public?: true)
    attribute(:peak_used_bytes, :integer, public?: true)
    attribute(:peak_total_bytes, :integer, public?: true)
    attribute(:samples, :integer, public?: true)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:finished_at, :utc_datetime_usec, public?: true)

    create_timestamp(:inserted_at)
  end

  @doc """
  Writes the row for one `Portal.Builder.build/2` call: `kind`, the
  `build_args` it was given, the `outcome` it returned, and `meta`:

    * `:attempt` - the Oban attempt
    * `:toolchain` - `"1.19/28"` for a toolchain run
    * `:started_at` - used when the side file names none
    * `:memory_limit_bytes`, `:build_concurrency` - what the container ran
      with; default the configured values (`Portal.Builder.memory_limit_bytes/0`,
      `Portal.Builder.build_concurrency/0`). The side file's `limit_bytes`, the
      limit the container saw, wins over either.

  Writes a row only when a container ran: an exit code, or a wall-clock
  timeout (`exit_code` nil, `timed_out`). Every other `{:error, _}` from
  `build/2` is a step before `docker run` (a host-condition refusal, docker
  unavailable, scratch setup) and writes nothing. Never
  raises: a failure is logged and the build goes on, `:ok` either way.
  """
  @spec record(atom(), map(), term(), map()) :: :ok
  def record(kind, build_args, outcome, meta \\ %{}) do
    case run_fields(outcome, build_args.run_id) do
      :no_container -> :ok
      fields -> insert(kind, build_args, fields, meta)
    end
  end

  defp run_fields({:ok, %{exit_code: exit_code} = build}, _run_id),
    do: %{exit_code: exit_code, timed_out: false, resources: Map.get(build, :resources)}

  defp run_fields({:error, {:build_timeout, _seconds, _container}}, run_id),
    do: %{exit_code: nil, timed_out: true, resources: read_resources(run_id)}

  # Every other error comes from a step before `docker run`: a host-condition
  # refusal or a runner failure (docker unavailable, scratch setup, ...).
  defp run_fields({:error, _before_container}, _run_id), do: :no_container

  defp read_resources(run_id) do
    Builder.read_resources(run_id)
  rescue
    _ -> nil
  end

  defp insert(kind, build_args, fields, meta) do
    resources = if is_map(fields.resources), do: fields.resources, else: %{}

    attrs = %{
      run_id: build_args.run_id,
      kind: kind,
      package: Map.get(build_args, :package),
      version: Map.get(build_args, :version),
      toolchain: Map.get(meta, :toolchain),
      image_digest: Map.get(build_args, :image_digest),
      host: Atom.to_string(node()),
      attempt: Map.get(meta, :attempt),
      exit_code: fields.exit_code,
      timed_out: fields.timed_out,
      oom_killed: fields.exit_code == 137,
      memory_limit_bytes:
        size(resources["limit_bytes"]) ||
          Map.get_lazy(meta, :memory_limit_bytes, &Builder.memory_limit_bytes/0),
      cpus: Builder.cpus(),
      build_concurrency: Map.get_lazy(meta, :build_concurrency, &Builder.build_concurrency/0),
      peak_used_bytes: size(resources["peak_used_bytes"]),
      peak_total_bytes: size(resources["peak_total_bytes"]),
      samples: size(resources["samples"]),
      started_at: timestamp(resources["started_at"]) || Map.get(meta, :started_at),
      finished_at: DateTime.utc_now()
    }

    case __MODULE__
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(domain: Portal.Catalog) do
      {:ok, _row} -> :ok
      {:error, error} -> warn(build_args, error)
    end
  rescue
    e -> warn(build_args, Exception.message(e))
  catch
    class, reason -> warn(build_args, {class, reason})
  end

  defp warn(build_args, error) do
    Logger.warning(
      "Could not record run memory for #{inspect(Map.get(build_args, :run_id))}: " <>
        inspect(error, limit: 10)
    )

    :ok
  end

  # The side file is written by a container that runs package code: take
  # only what fits a bigint column.
  defp size(value) when is_integer(value) and value >= 0 and value <= @max_bigint, do: value
  defp size(_value), do: nil

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _offset} -> datetime
      _ -> nil
    end
  end

  defp timestamp(_value), do: nil
end
