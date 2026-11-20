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
      build's did;
    * a foreign priv build's sibling (foreign priv spec 3.8 row 4) lists the
      build's `foreign_priv_rule` and exactly the build's foreign paths, its
      own archives pass `Portal.Catalog.ToolchainForeignPriv.verify/3` on its
      own beams, and each holds the members of the build's archive at that
      path (`Compatibility.KinoAssets.members/1`): the two compiles stamp
      different tar times, so the bytes differ and the sibling publishes its
      own.

  `candidate/3` is `{:ok, sibling}` (with `"shas"`, every blob it lists),
  `{:skip, reason}` (logged by the caller; the build is stored without a
  sibling) or `:none` for a result that carries none. Never raises.

  A firmware target's sibling (`systems[target].deterministic_build`,
  `NccWorker.FirmwareDeterministic`) is checked by `firmware_candidate/3`
  for the system result or the pinned firmware build the ingest stores from
  that target, the same way on what a firmware build records:

    * the sibling passed, is tagged as above, and its own R2 outcome
      (`build_root`) is a pass; the target passed with its own file
      manifest;
    * the target's build was made against the run's lock and the optional
      pass did not touch the target: no `deps_lock` of its own, no
      published build without its optional dependencies, and no optional
      dependencies added or dropped (a dropped target's closure builds were
      rebuilt with them loadable), so the closure the sibling was compiled
      over is the one its build is published under;
    * its manifest lists the build's paths under the same keys with the
      same modes, and every `priv` file is the build's, byte for byte (a
      firmware build has no own-priv list);
    * its `ebin` blobs pass `Compatibility.DeterministicBeams.compare_ebin/2`
      against the build's.

  The build's compile env and inputs are not the sibling's to state: it is
  served with its build's.
  """

  alias Compatibility.DeterministicBeams
  alias Portal.Catalog.{ToolchainForeignPriv, ToolchainPriv}

  @first_revision 29
  @same ~w(deps_lock package_checksum declared manager compile_env compile_env_rule
           compile_inputs built_priv foreign_priv_rule)
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
         :ok <- same_foreign_paths(sibling, build),
         :ok <- beams(manifest, build["file_manifest"], opts.files_dir),
         :ok <- priv(result, manifest, raw, opts),
         :ok <- foreign(result, sibling, manifest, {raw, build}, opts) do
      foreign = foreign_entries(sibling)

      {:ok,
       %{
         "judge_revision" => sibling["judge_revision"],
         "file_manifest" => manifest,
         "compile_observations" => observations(sibling["compile_observations"]),
         "foreign_priv" => foreign,
         "foreign_priv_rule" => if(foreign != [], do: sibling["foreign_priv_rule"]),
         "shas" => shas(manifest) ++ for(%{"sha256" => sha} <- foreign, do: sha)
       }}
    end
  end

  @doc """
  The check of a firmware target's sibling (see the moduledoc): `system_pkg`
  is the target, `sys` its system result as `result.json` records it.
  `:none` for a target that carries none, and for anything but a Nerves
  system. Never raises.
  """
  @spec firmware_candidate(String.t(), map(), map()) :: {:ok, map()} | {:skip, String.t()} | :none
  def firmware_candidate(
        "nerves_system_" <> _,
        %{"deterministic_build" => %{} = sibling} = sys,
        opts
      ) do
    check_firmware(sibling, sys, opts)
  rescue
    e -> {:skip, "could not be checked: " <> Exception.message(e)}
  end

  def firmware_candidate(_system_pkg, _sys, _opts), do: :none

  defp check_firmware(sibling, sys, opts) do
    build = %{
      "status" => sys["status"],
      "file_manifest" => get_in(sys, ["beam_scan", "footprint", "file_manifest"])
    }

    with :ok <- passed(sibling, build),
         :ok <- tagged(sibling),
         :ok <- own_r2(sibling),
         :ok <- run_closure(sys),
         {:ok, manifest} <- same_paths(sibling["file_manifest"], build["file_manifest"]),
         :ok <- same_priv(manifest, build["file_manifest"], []),
         :ok <- beams(manifest, build["file_manifest"], opts.files_dir) do
      {:ok,
       %{
         "judge_revision" => sibling["judge_revision"],
         "file_manifest" => manifest,
         "compile_observations" => %{"build_root" => sibling["build_root"]},
         "shas" => shas(manifest)
       }}
    end
  end

  # R2 on the sibling's own beams (`NccWorker.FirmwareBuildRoot`): an Erlang
  # module's `?FILE` literals are not its build's.
  defp own_r2(%{"build_root" => %{"status" => "pass"}}), do: :ok
  defp own_r2(_sibling), do: {:skip, "its own R2 did not pass"}

  # A target that kept its optional dependencies published a build made
  # against its own lock, and the sibling was compiled against the run's.
  # One the optional pass tried and dropped had its closure's builds rebuilt
  # with them loadable, which the sibling compile then built over. Only a
  # target the pass did not touch (no `optional_deps`, or nothing added or
  # dropped) was compiled over the closure its build is published under.
  defp run_closure(sys) do
    without? =
      Enum.any?(
        List.wrap(sys["published_variants"]),
        &(is_map(&1) and &1["variant"] == "without")
      )

    if sys["deps_lock"] == nil and not without? and untouched?(sys["optional_deps"]),
      do: :ok,
      else: {:skip, "its build was made against another closure than the run's"}
  end

  defp untouched?(nil), do: true

  defp untouched?(%{"added" => added, "dropped" => dropped}),
    do: added in [nil, []] and dropped in [nil, []]

  defp untouched?(_info), do: false

  defp passed(%{"status" => "pass"}, %{"status" => "pass", "file_manifest" => %{}}), do: :ok
  defp passed(%{"status" => "pass"}, _build), do: {:skip, "its build did not pass here"}
  # The worker's own reason travels into the log line: it is the only record
  # of why a build has no sibling (`Portal.Catalog.DeterministicBuild` stores
  # passes only).
  defp passed(%{"reason" => reason}, _build) when is_binary(reason) and reason != "",
    do: {:skip, "did not pass: " <> String.slice(reason, 0, 300)}

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

  # The same foreign paths as the build, which the host proved
  # (`Portal.Catalog.Ingestion`), none for none.
  defp same_foreign_paths(sibling, build) do
    if foreign_paths(sibling) == foreign_paths(build),
      do: :ok,
      else: {:skip, "its foreign_priv differs"}
  end

  defp foreign_paths(build),
    do: build |> foreign_entries() |> Enum.map(& &1["path"]) |> Enum.sort()

  defp foreign_entries(%{"foreign_priv" => entries}) when is_list(entries),
    do: Enum.filter(entries, &is_map/1)

  defp foreign_entries(_build), do: []

  # The sibling's archives, proved on the host as the build's were but
  # against the sibling's own beams, and each holding the build's members.
  defp foreign(_result, %{"foreign_priv" => [_ | _]} = sibling, manifest, {raw, build}, opts) do
    proved = %{
      "status" => "pass",
      "file_manifest" => manifest,
      "deps_lock" => raw["deps_lock"],
      "package_checksum" => raw["package_checksum"],
      "foreign_priv" => sibling["foreign_priv"],
      "foreign_priv_rule" => sibling["foreign_priv_rule"]
    }

    case ToolchainForeignPriv.verify(%{}, proved, opts) do
      :ok -> same_members(foreign_entries(sibling), foreign_entries(build), opts)
      {:refused, reason} -> {:skip, "foreign priv refused on the host: " <> reason}
      {:error, reason} -> {:skip, "foreign priv not checked: #{inspect(reason, limit: 5)}"}
    end
  end

  defp foreign(_result, _sibling, _manifest, _builds, _opts), do: :ok

  defp same_members(sibling, build, opts) do
    by_path = Map.new(build, &{&1["path"], &1})

    case Enum.find(sibling, &(not same_members?(&1, by_path[&1["path"]], opts))) do
      nil -> :ok
      %{"path" => path} -> {:skip, "its foreign_priv archives differ (#{path})"}
    end
  end

  defp same_members?(sibling, build, opts) do
    case ToolchainForeignPriv.archive_members(sibling, opts) do
      {:ok, members} -> ToolchainForeignPriv.archive_members(build, opts) == {:ok, members}
      :error -> false
    end
  end

  defp observations(%{} = observations), do: observations
  defp observations(_observations), do: nil

  defp shas(manifest),
    do: for(key <- ["ebin", "priv"], %{"sha256" => sha} <- manifest[key], do: sha)
end
