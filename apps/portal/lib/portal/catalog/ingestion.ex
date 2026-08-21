defmodule Portal.Catalog.Ingestion do
  @moduledoc """
  Ingests a parsed worker `result.json` into the `Portal.Catalog` domain.

  The builder Oban job is the only writer of catalog data. One successful build
  becomes, in a single transaction:

    * an upserted `Package` (by name; refreshes `latest_version`/`last_run_at`)
    * one `Run` (the envelope of `result.json`)
    * N × `SystemResult` (one per system in `result.systems`)
    * M × `Artifact` (content-addressed blobs moved out of the build's
      `files_dir` into the `Portal.ArtifactStore`)

  `overall_status` is derived from the per-system statuses (or a top-level
  `forced_status` when the worker emitted one).
  """

  require Logger

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, Package, Run, SystemResult}
  alias Portal.Repo

  @domain Portal.Catalog

  @type ingest_opts :: %{
          required(:run_id) => String.t(),
          required(:image_digest) => String.t(),
          required(:files_dir) => Path.t(),
          optional(:scan_request_id) => String.t() | nil,
          optional(:log) => String.t() | nil
        }

  @doc """
  Ingest a parsed `result.json` map. Returns `{:ok, run}` or `{:error, reason}`.
  Runs entirely inside one DB transaction.
  """
  @spec ingest(map(), ingest_opts()) :: {:ok, Run.t()} | {:error, term()}
  def ingest(result, opts) when is_map(result) do
    Repo.transaction(fn ->
      case do_ingest(result, opts) do
        {:ok, run} -> run
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp do_ingest(result, opts) do
    package_info = Map.get(result, "package", %{})
    package_name = package_info["name"] || raise "result.json missing package.name"
    version = package_info["version"] || "unknown"
    systems = Map.get(result, "systems", %{})
    finished_at = parse_datetime(result["finished_at"])
    overall = overall_status(result, systems)

    with {:ok, package} <- upsert_package(package_name, package_info, finished_at),
         {:ok, run} <-
           create_run(result, opts, package.id, version, overall, finished_at),
         :ok <- create_system_results(systems, run.id, version, opts.files_dir) do
      {:ok, run}
    end
  end

  defp upsert_package(name, info, last_run_at) do
    Package
    |> Ash.Changeset.for_create(:upsert, %{
      name: name,
      description: info["description"],
      latest_version: info["version"],
      last_run_at: last_run_at,
      native_components: info["native_components"]
    })
    |> Ash.create(domain: @domain)
  end

  defp create_run(result, opts, package_id, version, overall, finished_at) do
    Run
    |> Ash.Changeset.for_create(:create, %{
      run_id: opts.run_id,
      package_id: package_id,
      version_tested: version,
      image_digest: opts.image_digest,
      overall_status: overall,
      footprint: get_in(result, ["package", "footprint"]),
      log: Map.get(opts, :log),
      finished_at: finished_at,
      scan_request_id: Map.get(opts, :scan_request_id)
    })
    |> Ash.create(domain: @domain)
  end

  defp create_system_results(systems, run_id, version, files_dir) do
    Enum.reduce_while(systems, :ok, fn {system_pkg, sys}, _acc ->
      case create_system_result(system_pkg, sys, run_id, version, files_dir) do
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp create_system_result(system_pkg, sys, run_id, version, files_dir) do
    status = Compatibility.Types.parse_status(sys["status"])

    result =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run_id,
        system_pkg: system_pkg,
        system_version: sys["system_version"],
        status: status,
        firmware_size_bytes: sys["firmware_size_bytes"],
        hex_version_tested: version,
        beam_scan: sys["beam_scan"],
        dependency_scans: sys["dependency_scans"],
        log_path: nil,
        log_tail: sys["log_tail"],
        failure_category: Portal.Catalog.FailureClassifier.classify(sys)
      })
      |> Ash.create(domain: @domain)

    case result do
      {:ok, system_result} ->
        :ok = register_artifacts(sys, system_result.id, files_dir)
        {:ok, system_result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Move every content-addressed blob referenced by this system's manifests out
  # of files_dir into the artifact store and record an Artifact row.
  defp register_artifacts(sys, system_result_id, files_dir) do
    sys
    |> collect_shas()
    |> Enum.flat_map(fn sha ->
      source = Path.join(files_dir, sha)

      case ArtifactStore.put(sha, source) do
        {:ok, %{disk_path: disk_path, byte_size: bytes}} ->
          [
            %{
              sha256: sha,
              byte_size: bytes,
              disk_path: disk_path,
              system_result_id: system_result_id
            }
          ]

        {:error, :source_missing} ->
          Logger.debug("Artifact blob #{sha} not present in files_dir; skipping")
          []

        {:error, reason} ->
          Logger.warning("Failed to store artifact #{sha}: #{inspect(reason)}")
          []
      end
    end)
    |> upsert_artifacts()
  end

  # One statement per batch of blobs, not one per blob.
  #
  # A single system's manifest carries on the order of a thousand
  # content-addressed BEAM files, and this used to be a row-at-a-time
  # `Ash.create/2`: ~950 sequential round trips, all inside the ingest
  # transaction. That runs past DBConnection's 15s checkout limit, which kills
  # the connection mid-ingest, fails the build job, and makes Oban retry the
  # whole 16-minute build. The blobs themselves are ~15MB total, so the cost was
  # never volume, only the number of round trips.
  defp upsert_artifacts([]), do: :ok

  defp upsert_artifacts(entries) do
    entries
    |> Ash.bulk_create(Artifact, :upsert,
      domain: @domain,
      upsert?: true,
      upsert_identity: :unique_sha256,
      upsert_fields: [:byte_size, :disk_path],
      return_errors?: true,
      stop_on_error?: false,
      transaction: false
    )
    |> case do
      %Ash.BulkResult{status: :success} ->
        :ok

      %Ash.BulkResult{errors: errors} ->
        Logger.warning(
          "Failed to register #{length(errors)} of #{length(entries)} artifacts; " <>
            "first error: #{inspect(List.first(errors))}"
        )

        :ok
    end
  end

  # Collect unique sha256s from a system result's beam_scan + dependency_scans
  # file manifests.
  defp collect_shas(sys) do
    package_scan = sys["beam_scan"]
    dep_scans = sys["dependency_scans"] || %{}

    dep_scan_list =
      case dep_scans do
        m when is_map(m) -> Map.values(m)
        _ -> []
      end

    [package_scan | dep_scan_list]
    |> Enum.reject(&is_nil/1)
    |> Enum.flat_map(&shas_from_scan/1)
    |> Enum.uniq()
  end

  defp shas_from_scan(scan) when is_map(scan) do
    manifest = get_in(scan, ["footprint", "file_manifest"]) || %{}
    ebin = Map.get(manifest, "ebin", [])
    priv = Map.get(manifest, "priv", [])

    (ebin ++ priv)
    |> Enum.map(fn entry -> is_map(entry) && entry["sha256"] end)
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp shas_from_scan(_), do: []

  # Derive the overall status. A top-level forced_status (gleam/retired) wins;
  # otherwise pass if any system passed, then fail/error/skipped, else unknown.
  defp overall_status(result, systems) do
    case result["forced_status"] do
      s when is_binary(s) ->
        Compatibility.Types.parse_status(s)

      _ ->
        statuses =
          systems
          |> Map.delete("host")
          |> Map.values()
          |> Enum.map(fn sys -> Compatibility.Types.parse_status(sys["status"]) end)

        cond do
          :pass in statuses -> :pass
          :fail in statuses -> :fail
          :error in statuses -> :error
          :skipped in statuses -> :skipped
          true -> :unknown
        end
    end
  end

  defp parse_datetime(nil), do: nil

  defp parse_datetime(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
