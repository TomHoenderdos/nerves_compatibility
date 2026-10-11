defmodule Portal.Catalog.ToolingSkip do
  @moduledoc """
  Nerves' own tooling is not checked for Nerves compatibility (issue #43).

  The check builds a package into a generated Nerves project for every tracked
  target. That question makes no sense for the pieces that project is made of:
  `nerves` itself fails in a silly way, `nerves_bootstrap` passes for the wrong
  reasons, and systems, toolchains and kiosk systems are device- or
  architecture-specific by design, so every target but their own fails. Those
  are expected failures, and publishing them reads as Nerves being broken.

  Such a package gets a run recorded straight through
  `Portal.Catalog.Ingestion` with a single `nerves_tooling` entry, status
  `skipped`, the same way `Portal.Catalog.RegistryAssessment` records its
  verdicts. Package pages, badges and the API read it like any other run, and
  nothing reaches Docker. `native_components.compatibility_basis` marks where
  it came from.

  `Portal.Workers.Build` calls `record/3` in place of a build, so every path
  that enqueues one (requests, update checks, backfills, admin requeues) is
  covered. `record_existing/0` re-records packages whose latest run predates
  this module.
  """

  require Ash.Query
  require Logger

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package}

  @system "nerves_tooling"
  @image_digest "tooling"

  # Exact names first: a bare `nerves_` prefix would sweep up nerves_runtime,
  # nerves_pack and the rest of the libraries people put on devices, which are
  # exactly what this site exists to check.
  @names ~w(nerves nerves_bootstrap nerves_systems)
  @prefixes ~w(nerves_system_ nerves_toolchain kiosk_system_)

  @reason "Not checked: this package is part of the Nerves tooling (the core build " <>
            "tools, a Nerves system, a toolchain or a kiosk system). Building it into a " <>
            "Nerves project for every target says nothing about whether it works."

  @doc "The system key a tooling skip records."
  @spec system() :: String.t()
  def system, do: @system

  @doc "Whether `name` is Nerves tooling that is never built."
  @spec tooling?(String.t()) :: boolean()
  def tooling?(name) when is_binary(name) do
    name in @names or Enum.any?(@prefixes, &String.starts_with?(name, &1))
  end

  def tooling?(_name), do: false

  @doc """
  Records a skipped run for `name` at `version`. Idempotent on the run id, so a
  retried job or a repeated `record_existing/0` returns the run already on file.
  """
  @spec record(String.t(), String.t(), String.t() | nil) ::
          {:ok, Portal.Catalog.Run.t()} | {:error, term()}
  def record(name, version, scan_request_id) do
    run_id = "tooling-#{name}-#{version}"

    case Catalog.committed_run(run_id) do
      {:ok, %{} = run} -> {:ok, run}
      {:ok, nil} -> ingest(name, version, run_id, scan_request_id)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Records a skip for every tooling package in the catalogue whose latest run is
  a real build. Run once after deploying, against the running node:

      bin/portal rpc 'Portal.Catalog.ToolingSkip.record_existing() |> IO.inspect()'

  Returns the names it recorded.
  """
  @spec record_existing() :: [String.t()]
  def record_existing do
    Package
    |> Ash.Query.select([:id, :name, :latest_version])
    |> Ash.read!(domain: Catalog)
    |> Enum.filter(&(tooling?(&1.name) and is_binary(&1.latest_version)))
    |> Enum.flat_map(fn package ->
      case record(package.name, package.latest_version, nil) do
        {:ok, _run} ->
          [package.name]

        {:error, reason} ->
          Logger.warning("Tooling skip failed for #{package.name}: #{inspect(reason)}")
          []
      end
    end)
  end

  defp ingest(name, version, run_id, scan_request_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    result = %{
      "package" => %{
        "name" => name,
        "version" => version,
        # The package upsert overwrites the description, and this path has
        # none of its own to offer. Carry the stored one over rather than
        # blank it.
        "description" => stored_description(name),
        "native_components" => %{"compatibility_basis" => @system}
      },
      "forced_status" => "skipped",
      "started_at" => now,
      "finished_at" => now,
      "systems" => %{
        @system => %{
          "status" => "skipped",
          "duration_sec" => 0.0,
          "log_tail" => @reason,
          "error" => @reason
        }
      }
    }

    Ingestion.ingest(result, %{
      run_id: run_id,
      image_digest: @image_digest,
      files_dir: System.tmp_dir!(),
      scan_request_id: scan_request_id
    })
  end

  defp stored_description(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.select([:description])
    |> Ash.read_one(domain: Catalog)
    |> case do
      {:ok, %{description: description}} -> description
      _ -> nil
    end
  end
end
