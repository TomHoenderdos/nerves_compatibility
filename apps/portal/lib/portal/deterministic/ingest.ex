defmodule Portal.Deterministic.Ingest do
  @moduledoc """
  The host's own check of a toolchain run's deterministic sibling
  (`result.json`'s `deterministic_build`, `NccWorker.Deterministic`) before
  `Portal.Catalog.Ingestion` stores it beside the build. The worker checked
  all of it already; the portal trusts none of it and checks it again, on the
  blobs it is about to store:

    * the sibling passed, carries `erl_compiler_options: ["deterministic"]`
      and a judge revision of 29 or later, and its build passed here too
      (after every gate of the ingest);
    * its `deps_lock`, `package_checksum`, `declared`, `manager`,
      `compile_env`, `compile_env_rule`, `compile_inputs` and `built_priv`
      are the build's, as the result records them;
    * its manifest lists the build's paths under the same keys, each with
      the same mode, and every `priv` file with the build's bytes but those
      `built_priv` names;
    * its `ebin` blobs, read from the run's files and hashed here, pass
      `Compatibility.DeterministicBeams.compare_ebin/2` against the build's;
    * its `priv` passes `Portal.Catalog.ToolchainPriv.verify/3` as the
      build's did.

  `candidate/3` is `{:ok, sibling}` (with `"shas"`, every blob it lists),
  `{:skip, reason}` (logged by the caller; the build is stored without a
  sibling) or `:none` for a result that carries none. Never raises.
  """

  alias Compatibility.DeterministicBeams
  alias Portal.Catalog.ToolchainPriv

  @first_revision 29
  @same ~w(deps_lock package_checksum declared manager compile_env compile_env_rule
           compile_inputs built_priv)
  @sha ~r/\A[0-9a-f]{64}\z/
  # The most ebin bytes read back to compare: far above any package's.
  @max_ebin_bytes 256 * 1024 * 1024

  @doc "The first judge revision a worker builds siblings under."
  @spec first_revision() :: pos_integer()
  def first_revision, do: @first_revision

  @spec candidate(map(), map(), map()) :: {:ok, map()} | {:skip, String.t()} | :none
  def candidate(result, build, opts) do
    case result["deterministic_build"] do
      %{} = sibling -> check(sibling, result, build, opts)
      _ -> :none
    end
  rescue
    e -> {:skip, "could not be checked: " <> Exception.message(e)}
  end

  defp check(sibling, result, build, opts) do
    raw = result["toolchain_build"] || %{}

    with :ok <- passed(sibling, build),
         :ok <- tagged(sibling),
         :ok <- same_fields(sibling, raw),
         {:ok, manifest} <- same_paths(sibling["file_manifest"], build["file_manifest"]),
         :ok <- same_priv(manifest, build["file_manifest"], raw["built_priv"]),
         :ok <- beams(manifest, build["file_manifest"], opts.files_dir),
         :ok <- priv(result, manifest, raw, opts) do
      {:ok,
       %{
         "judge_revision" => sibling["judge_revision"],
         "file_manifest" => manifest,
         "compile_observations" => observations(sibling["compile_observations"]),
         "shas" => shas(manifest)
       }}
    end
  end

  defp passed(%{"status" => "pass"}, %{"status" => "pass", "file_manifest" => %{}}), do: :ok
  defp passed(%{"status" => "pass"}, _build), do: {:skip, "its build did not pass here"}
  defp passed(_sibling, _build), do: {:skip, "did not pass"}

  defp tagged(%{"erl_compiler_options" => options, "judge_revision" => revision})
       when is_integer(revision) and revision >= @first_revision and revision <= 1_000_000 do
    if options == DeterministicBeams.options(),
      do: :ok,
      else: {:skip, "names other compiler options"}
  end

  defp tagged(_sibling), do: {:skip, "names no compiler options or judge revision"}

  defp same_fields(sibling, raw) do
    case Enum.find(@same, &(Map.get(sibling, &1) != Map.get(raw, &1))) do
      nil -> :ok
      field -> {:skip, "its #{field} differs from its build's"}
    end
  end

  # The sibling's entries, by key, when each key lists exactly the build's
  # paths with the build's modes: its paths are then the ones the build's own
  # checks already took.
  defp same_paths(%{} = sibling, %{} = build) do
    keys = ["ebin", "priv"]

    if Enum.all?(keys, &(shape(sibling[&1]) == shape(build[&1]) and entries?(sibling[&1]))) and
         Enum.sort(Map.keys(sibling)) == Enum.sort(Map.keys(build)),
       do: {:ok, Map.new(keys, &{&1, sibling[&1] || []})},
       else: {:skip, "its files are not its build's"}
  end

  defp same_paths(_sibling, _build), do: {:skip, "lists no files"}

  defp shape(entries) when is_list(entries),
    do: entries |> Enum.map(&{&1["path"], &1["mode"]}) |> Enum.sort()

  defp shape(_entries), do: nil

  defp entries?(entries) when is_list(entries),
    do:
      Enum.all?(
        entries,
        &(is_binary(&1["path"]) and is_binary(&1["sha256"]) and &1["sha256"] =~ @sha)
      )

  defp entries?(_entries), do: false

  defp same_priv(manifest, build, built) do
    built = MapSet.new(if is_list(built), do: built, else: [])
    key = fn e -> {e["path"], MapSet.member?(built, e["path"]) || e["sha256"]} end

    if Enum.sort(Enum.map(manifest["priv"], key)) == Enum.sort(Enum.map(build["priv"] || [], key)),
      do: :ok,
      else: {:skip, "its priv differs from its build's"}
  end

  defp beams(manifest, build, files_dir) do
    with {:ok, normal} <- read_ebin(build["ebin"], files_dir),
         {:ok, sibling} <- read_ebin(manifest["ebin"], files_dir) do
      case DeterministicBeams.compare_ebin(normal, sibling) do
        :ok -> :ok
        {:error, why} -> {:skip, "its ebin is not its build's but for the option: " <> why}
      end
    end
  end

  # The run's own files dir, named by the job; a blob is read by its sha and
  # must hash to it.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_ebin(entries, files_dir) do
    Enum.reduce_while(entries, {:ok, %{}, 0}, fn %{"path" => "ebin/" <> name, "sha256" => sha},
                                                 {:ok, acc, total} ->
      with true <- sha =~ @sha,
           {:ok, bytes} <- File.read(Path.join(files_dir, sha)),
           true <- total + byte_size(bytes) <= @max_ebin_bytes,
           ^sha <- Base.encode16(:crypto.hash(:sha256, bytes), case: :lower) do
        {:cont, {:ok, Map.put(acc, name, bytes), total + byte_size(bytes)}}
      else
        _ -> {:halt, {:skip, "its ebin blobs cannot be read back"}}
      end
    end)
    |> case do
      {:ok, files, _total} -> {:ok, files}
      other -> other
    end
  end

  defp priv(result, manifest, raw, opts) do
    build = %{
      "status" => "pass",
      "file_manifest" => manifest,
      "package_checksum" => raw["package_checksum"],
      "built_priv" => raw["built_priv"]
    }

    case ToolchainPriv.verify(result, build, opts) do
      :ok -> :ok
      {:refused, reason} -> {:skip, "priv refused on the host: " <> reason}
      {:error, reason} -> {:skip, "priv not checked: #{inspect(reason, limit: 5)}"}
    end
  end

  defp observations(%{} = observations), do: observations
  defp observations(_observations), do: nil

  defp shas(manifest),
    do: for(key <- ["ebin", "priv"], %{"sha256" => sha} <- manifest[key], do: sha)
end
