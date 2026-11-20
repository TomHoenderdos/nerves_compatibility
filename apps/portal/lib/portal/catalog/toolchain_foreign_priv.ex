defmodule Portal.Catalog.ToolchainForeignPriv do
  @moduledoc """
  The host's check of a toolchain build's foreign priv files (foreign priv
  spec 4.2): the archives its compile wrote into kino's build priv, which
  the worker judged in the container, are proved again here from what the
  host fetched itself, before any is published:

    1. the entries' shape (`Compatibility.ForeignPriv.check_entries/3`),
       before anything is read;
    2. kino in the build's `deps_lock`, its tarball signed by the registry
       and the lock's (`ToolchainPriv.signed_release/4`), its
       `lib/kino/js.ex` the reviewed one of the build's rule;
    3. the writer's own tarball (`ToolchainPriv.signed_tarball/2`);
    4. each blob (at most 10 MiB) hashing to its entry, and
       `Compatibility.KinoAssets.verify/1` on it, its module's beam blob and
       the writer's tarball, naming the entry's `assets_path`.

  A blob is read from the run's files dir, or from the store when an
  earlier ingest put it there (as `Portal.Catalog.Ingestion` stages it),
  and must hash to its entry either way; one in neither refuses.

  Before any of it, with kino in the build's lock, every beam of the build
  that exports `__assets_info__/0` must have its entry, so a missing archive
  or a writer pass with no list at all is never published on the
  container's word; the beams are read without making atoms of them
  (`Compatibility.KinoAssets.exports_assets_info/1`).

  `{:refused, why}` is stored as a fail with no files and logged as a
  security event; `{:error, _}` (Hex unavailable, a blob not staged yet)
  retries the job. The
  writer's app in its `cdn_url` must be the job's package: a writer whose
  app is not its Hex name is refused, fail closed.
  """

  require Logger

  alias Compatibility.{ForeignPriv, KinoAssets, StaticPriv}
  alias Portal.ArtifactStore
  alias Portal.Catalog.ToolchainPriv

  @sha ~r/\A[0-9a-f]{64}\z/
  # A module's beam is read whole for its debug info; far above any one's.
  @max_beam_bytes 64 * 1024 * 1024

  @doc """
  `:ok` when `build`'s foreign priv files may be published (or it has none,
  or did not pass), `{:refused, why}` when they may not, `{:error, reason}`
  when Hex could not be asked. `opts` are the ingest's, with `files_dir`
  and the job's `package` and `version`.
  """
  @spec verify(map(), map(), map()) :: :ok | {:refused, String.t()} | {:error, term()}
  def verify(_result, %{"status" => "pass"} = build, opts) do
    entries = build["foreign_priv"]

    with :ok <-
           shape(ForeignPriv.check_entries(entries, build["foreign_priv_rule"], beams(build))),
         :ok <- complete(build, entries, opts) do
      if entries in [nil, []], do: :ok, else: checked(build, entries, opts)
    else
      {:refused, why} -> refused(why, opts)
      {:error, _reason} = error -> error
    end
  end

  def verify(_result, _build, _opts), do: :ok

  defp shape(:ok), do: :ok
  defp shape({:error, why}), do: {:refused, why}

  # S4's second half on the host (foreign priv spec 3.3): with kino in its
  # lock, every beam of the build that exports `__assets_info__/0` is a
  # module with an entry, so the host never takes the container's word that
  # the list is whole. A build without kino in its lock has no asset module
  # that could load an archive (kino's own builds among them). Each beam is
  # read by its own sha, one at a time, without making an atom of it
  # (`Compatibility.KinoAssets.exports_assets_info/1`).
  defp complete(%{"deps_lock" => %{} = lock} = build, entries, opts) do
    if Map.has_key?(lock, ForeignPriv.target()) do
      listed = MapSet.new(List.wrap(entries), & &1["module"])
      Enum.reduce_while(ebin_beams(build), :ok, &listed_or_halt(&1, &2, listed, opts))
    else
      :ok
    end
  end

  defp complete(_build, _entries, _opts), do: :ok

  defp listed_or_halt(entry, :ok, listed, opts) do
    case asset_module(entry, opts) do
      {:ok, nil} ->
        {:cont, :ok}

      {:ok, module} ->
        if MapSet.member?(listed, module),
          do: {:cont, :ok},
          else:
            {:halt,
             {:refused, "#{module} exports __assets_info__/0 but has no foreign priv entry"}}

      other ->
        {:halt, other}
    end
  end

  defp ebin_beams(%{"file_manifest" => %{"ebin" => ebin}}) when is_list(ebin) do
    ebin
    |> Enum.filter(
      &(is_map(&1) and is_binary(&1["path"]) and String.ends_with?(&1["path"], ".beam"))
    )
    |> Enum.sort_by(& &1["path"])
  end

  defp ebin_beams(_build), do: []

  # `{:ok, module}` when the beam exports `__assets_info__/0`, `{:ok, nil}`
  # when it does not; a beam that is not its sha, or cannot be read as one,
  # refuses; one not staged yet is the retryable error staging gives.
  defp asset_module(%{"path" => path} = entry, opts) do
    case blob(entry["sha256"], entry["size"], @max_beam_bytes, opts) do
      {:ok, bytes} ->
        case KinoAssets.exports_assets_info(bytes) do
          {:ok, module, true} -> {:ok, module}
          {:ok, _module, false} -> {:ok, nil}
          :error -> {:refused, "#{path} cannot be read as a beam"}
        end

      {:unstaged, sha} ->
        {:error, {:artifacts_unstaged, [sha]}}

      {:error, why} ->
        {:refused, "#{path}: #{why}"}
    end
  end

  defp checked(build, entries, opts) do
    with {:ok, kino} <- kino_release(build),
         {:ok, kino_tarball} <-
           signed(ToolchainPriv.signed_release("kino", kino.version, kino.checksum, opts)),
         :ok <- reviewed(kino, kino_tarball, build["foreign_priv_rule"]),
         {:ok, tarball} <- signed(ToolchainPriv.signed_tarball(build, opts)),
         :ok <- each_proved(entries, build, tarball, opts) do
      :ok
    else
      {:refused, why} -> refused(why, opts)
      {:error, {:artifacts_unstaged, _shas}} = unstaged -> unstaged
      {:error, reason} -> {:error, {:foreign_priv_unchecked, reason}}
    end
  end

  defp signed({:ok, bytes}), do: {:ok, bytes}
  defp signed({:refused, why}), do: {:refused, why}
  defp signed({:error, {:priv_unchecked, reason}}), do: {:error, reason}
  defp signed({:error, reason}), do: {:error, reason}

  defp kino_release(%{"deps_lock" => %{"kino" => %{"version" => v, "checksum" => c}}})
       when is_binary(v) and is_binary(c),
       do: {:ok, %{version: v, checksum: c}}

  defp kino_release(_build), do: {:refused, "foreign priv without kino in its lock"}

  defp reviewed(kino, tarball, rule_id) do
    case ForeignPriv.reviewed_tarball(kino.version, tarball) do
      %{id: ^rule_id} -> :ok
      _ -> {:refused, "kino #{kino.version}'s js.ex is not reviewed for #{rule_id}"}
    end
  end

  defp each_proved(entries, build, tarball, opts) do
    Enum.reduce_while(entries, :ok, fn entry, :ok ->
      case proved(entry, build, tarball, opts) do
        :ok -> {:cont, :ok}
        refusal -> {:halt, refusal}
      end
    end)
  end

  defp proved(entry, build, tarball, opts) do
    {:ok, dir, _hash} = ForeignPriv.parse_path(entry["path"])

    with {:ok, archive} <- blob(entry["sha256"], entry["size"], ForeignPriv.max_bytes(), opts),
         {:ok, beam_entry} <- beam_entry(build, entry["module"]),
         {:ok, beam} <- blob(beam_entry["sha256"], beam_entry["size"], @max_beam_bytes, opts),
         {:ok, proof} <-
           KinoAssets.verify(%{
             name: dir <> "/" <> Path.basename(entry["path"]),
             archive: archive,
             module: entry["module"],
             beam: beam,
             tarball: tarball,
             app: opts.package,
             version: opts.version
           }),
         :ok <- same_assets_path(proof, entry) do
      :ok
    else
      {:unstaged, sha} -> {:error, {:artifacts_unstaged, [sha]}}
      {:error, why} -> {:refused, "foreign priv file #{entry["path"]}: #{why}"}
    end
  end

  @doc """
  The members of the archive `entry` names (`Compatibility.KinoAssets.members/1`),
  read as `verify/3` reads its blob: `{:ok, members}`, or `:error` for an
  entry whose blob is missing, not its sha, or not a strict archive.
  `Portal.Deterministic.Ingest` compares a sibling's with its build's.
  """
  @spec archive_members(term(), map()) :: {:ok, [KinoAssets.member()]} | :error
  def archive_members(%{"sha256" => sha, "size" => size}, opts) do
    with {:ok, bytes} <- blob(sha, size, ForeignPriv.max_bytes(), opts),
         {:ok, members} <- KinoAssets.members(bytes) do
      {:ok, members}
    else
      _ -> :error
    end
  end

  def archive_members(_entry, _opts), do: :error

  defp same_assets_path(%{assets_path: path}, %{"assets_path" => path}), do: :ok
  defp same_assets_path(_proof, _entry), do: {:error, "names another assets_path than its beam"}

  defp beams(%{"file_manifest" => %{"ebin" => ebin}}) when is_list(ebin),
    do: MapSet.new(for %{"path" => path} when is_binary(path) <- ebin, do: path)

  defp beams(_build), do: MapSet.new()

  defp beam_entry(%{"file_manifest" => %{"ebin" => ebin}}, module) when is_list(ebin) do
    case Enum.find(ebin, &(is_map(&1) and &1["path"] == "ebin/#{module}.beam")) do
      %{"sha256" => _, "size" => _} = entry -> {:ok, entry}
      _ -> {:error, "#{module} has no beam in the build"}
    end
  end

  defp beam_entry(_build, module), do: {:error, "#{module} has no beam in the build"}

  # A blob the run staged, or one the store already holds, read under the
  # cap, by its own sha and size; `{:unstaged, sha}` when neither holds it
  # yet, which the ingest retries, as staging does.
  defp blob(sha, size, max, opts)
       when is_binary(sha) and is_integer(size) and size >= 0 and size <= max do
    with true <- Regex.match?(@sha, sha),
         {:ok, bytes} <- read_blob(opts.files_dir, sha, size),
         true <- byte_size(bytes) == size and StaticPriv.sha256(bytes) == sha do
      {:ok, bytes}
    else
      :enoent -> {:unstaged, sha}
      _ -> {:error, "not the blob its entry names"}
    end
  end

  defp blob(_sha, _size, _max, _opts), do: {:error, "not the blob its entry names"}

  defp read_blob(files_dir, sha, size) do
    case read_capped(Path.join(files_dir, sha), size) do
      :enoent -> read_capped(ArtifactStore.blob_path(sha), size)
      other -> other
    end
  end

  # `path` is the files dir or the store joined with a validated SHA-256;
  # at most one byte past `size` is read.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_capped(path, size) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.open(path, [:read, :raw, :binary], &IO.binread(&1, size + 1)) do
      case bytes do
        :eof -> {:ok, ""}
        bytes when is_binary(bytes) -> {:ok, bytes}
        _ -> :unreadable
      end
    else
      {:error, :enoent} -> :enoent
      _ -> :unreadable
    end
  end

  defp refused(why, opts) do
    Logger.warning(
      "security: toolchain build #{opts.package} #{opts.version} foreign priv refused at ingest: " <>
        why
    )

    {:refused, why}
  end
end
