defmodule Portal.HostNative.Ingest do
  @moduledoc """
  Stores a host-native run's `host_native_build` (`Portal.HostNative`,
  `NccWorker.HostNative`) as a `Portal.Catalog.HostNativeBuild`, its files
  as stored blobs it owns.

  The result is the container's word, so the host checks a passing build
  again before any file of it is published, on the files the run handed over
  and a tarball it fetched itself (`Portal.Catalog.ToolchainPriv.signed_tarball/2`):

    1. every manifest entry names a plain `ebin/` or `priv/` path and a
       SHA-256 the run's files hash to; the priv files together at most
       128 MiB;
    2. at least one priv file is ELF, and every ELF file is a 64-bit
       `ET_DYN` object of the triple's machine, at most 64 MiB
       (`Compatibility.Elf`); every other priv file is static data of the
       tarball (`Compatibility.StaticPriv`), and no file outside priv is
       ELF;
    3. the tarball ships checksum files, and every ELF file is, byte for
       byte, a member of an archive the run handed over whose bytes have
       the sum the package's own checksum file lists for its name, and the
       origins this finds are exactly the ones the build reports
       (`Compatibility.NifOrigin`); a package without checksum files
       compiled its ELF files in the run, which are refused
       (`Compatibility.NifOrigin.compiled_refusal/1`);
    4. the ELF facts (`Portal.Precompiled.ElfFacts`): every library the
       files need and the symbol versions they need from it, read here.

  A refusal stores the build as `fail` with no files; Hex being unreachable
  or a blob not yet in the files dir is an error the ingest job retries. The
  identity is the job's (`package`, `version`, `toolchain`, `triple`,
  `builder_version`), and a result naming another is refused whole.
  """

  require Logger

  alias Compatibility.{Elf, HostTriple, NifOrigin, StaticPriv}
  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, ArtifactMembership, HostNativeBuild}
  alias Portal.Catalog.ToolchainPriv
  alias Portal.Precompiled.ElfFacts

  @max_priv_bytes 128 * 1024 * 1024
  @max_elf 64 * 1024 * 1024
  @sha ~r/\A[0-9a-f]{64}\z/

  @doc """
  Ingests `result` (a run's `result.json`) for the job in `opts`: `run_id`,
  `image_digest`, `files_dir`, `package`, `version`, `toolchain`, `triple`,
  `builder_version`, and the Hex reads `ToolchainPriv` takes for tests.
  """
  @spec ingest(map(), map()) :: {:ok, HostNativeBuild.t()} | {:error, term()}
  def ingest(result, opts) do
    with {:ok, build} <- identity(result, opts),
         {:ok, package_id} <- package_id(opts.package),
         {:ok, attrs, shas} <- judged(build, result, opts) do
      write(Map.merge(attrs, %{package_id: package_id}), shas, opts)
    end
  end

  defp identity(%{"scope" => "host_native", "host_native_build" => %{} = build} = result, opts) do
    package = result["package"] || %{}

    reported = %{
      package: package["name"],
      version: package["version"],
      toolchain: toolchain_of(build),
      triple: build["triple"]
    }

    job = Map.take(opts, [:package, :version, :toolchain, :triple])
    if reported == job, do: {:ok, build}, else: {:error, {:identity_mismatch, job, reported}}
  end

  defp identity(_result, _opts), do: {:error, {:identity_missing, ["host_native_build"]}}

  defp toolchain_of(%{"elixir" => elixir, "otp" => otp})
       when is_binary(elixir) and is_binary(otp),
       do: (elixir |> String.split(".") |> Enum.take(2) |> Enum.join(".")) <> "/" <> otp

  defp toolchain_of(_build), do: nil

  defp package_id(name) do
    case Portal.HostNative.package_id(name) do
      nil ->
        {:ok, package} =
          Portal.Catalog.Package
          |> Ash.Changeset.for_create(:create, %{name: name})
          |> Ash.create(domain: Portal.Catalog)

        {:ok, package.id}

      id ->
        {:ok, id}
    end
  rescue
    e -> {:error, {:package, Exception.message(e)}}
  end

  # `{:ok, row attributes, shas to stage}`; a refusal is a `fail` row.
  defp judged(%{"status" => "pass"} = build, result, opts) do
    case verify(build, opts) do
      {:ok, needs} -> {:ok, attrs(build, result, opts, :pass, nil, needs), manifest_shas(build)}
      {:refused, reason} -> refused(build, result, opts, reason)
      {:error, _reason} = error -> error
    end
  end

  defp judged(%{"status" => "skipped"} = build, result, opts),
    do: {:ok, without_files(attrs(build, result, opts, :skipped, build["reason"], nil)), []}

  defp judged(build, result, opts),
    do: {:ok, without_files(attrs(build, result, opts, :fail, build["reason"], nil)), []}

  defp refused(build, result, opts, reason) do
    Logger.warning(
      "security: host-native build #{opts.package} #{opts.version} #{opts.triple} " <>
        "refused at ingest: #{reason}"
    )

    attrs = attrs(build, result, opts, :fail, "refused at ingest: " <> reason, nil)
    {:ok, without_files(attrs), []}
  end

  defp without_files(attrs),
    do: %{attrs | file_manifest: nil, native_files: nil, origins: nil, elf_needs: nil}

  defp attrs(build, result, opts, status, reason, needs) do
    %{
      version: opts.version,
      toolchain: opts.toolchain,
      triple: opts.triple,
      builder_version: opts.builder_version,
      status: status,
      reason: reason,
      elixir: build["elixir"],
      otp: build["otp"],
      otp_full: build["otp_full"],
      nif_version: build["nif_version"],
      libc: build["libc"],
      glibc: build["glibc"],
      image_digest: opts.image_digest,
      run_id: opts.run_id,
      deps_lock: build["deps_lock"] || result["deps_lock"],
      package_checksum: build["package_checksum"],
      declared: build["declared"],
      compile_env: build["compile_env"],
      compile_env_rule: build["compile_env_rule"],
      compile_inputs: build["compile_inputs"],
      file_manifest: build["file_manifest"],
      native_files: build["native_files"],
      origins: build["origins"],
      elf_needs: needs,
      optional_deps: result["optional_deps"],
      judge_revision: build["judge_revision"],
      manager: build["manager"],
      compile_observations: build["compile_observations"],
      finished_at: parse_time(result["finished_at"])
    }
  end

  defp parse_time(text) when is_binary(text) do
    case DateTime.from_iso8601(text) do
      {:ok, at, _offset} -> at
      _ -> DateTime.utc_now()
    end
  end

  defp parse_time(_text), do: DateTime.utc_now()

  defp manifest_shas(build),
    do: build["file_manifest"] |> Portal.HostNative.manifest_shas() |> Enum.uniq()

  # Steps 1 to 4: `{:ok, needs}`, `{:refused, reason}` or `{:error, reason}`.
  defp verify(build, opts) do
    with {:ok, entries} <- entries(build["file_manifest"]),
         :ok <- outside_priv(entries, opts.files_dir),
         {:ok, priv} <- read_priv(entries, opts.files_dir),
         {elf, static} = Enum.split_with(priv, &elf?(&1.bytes)),
         :ok <- if(elf == [], do: {:refused, "ships no native file"}, else: :ok),
         :ok <- loadable(elf, build["triple"]),
         {:ok, tarball} <- ToolchainPriv.signed_tarball(build, opts),
         :ok <- static_priv(static, tarball),
         :ok <- origins(elf, build["origins"], tarball, opts.files_dir) do
      needs(priv)
    end
  end

  defp entries(%{} = manifest) do
    entries =
      for key <- ["ebin", "priv"], entry <- List.wrap(manifest[key]), do: {key, entry}

    if entries != [] and Enum.all?(entries, &entry?/1),
      do: {:ok, Enum.map(entries, &elem(&1, 1))},
      else: {:refused, "ships a manifest entry that names no plain file"}
  end

  defp entries(_manifest), do: {:refused, "ships no file manifest"}

  defp entry?({key, %{"path" => path, "sha256" => sha, "size" => size}})
       when is_binary(path) and is_binary(sha) and is_integer(size) and size >= 0 do
    String.starts_with?(path, key <> "/") and plain_path?(path) and Regex.match?(@sha, sha)
  end

  defp entry?(_entry), do: false

  defp plain_path?(path) do
    String.valid?(path) and byte_size(path) <= 1024 and String.printable?(path) and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  # Every native file is judged in priv (steps 2 and 3): an ELF file under
  # `ebin`, which a beam can `load_nif` from, would escape both. Only each
  # blob's first bytes are read; staging verifies its digest.
  defp outside_priv(entries, files_dir) do
    entries
    |> Enum.reject(&String.starts_with?(&1["path"], "priv/"))
    |> Enum.sort_by(& &1["path"])
    |> Enum.reduce_while(:ok, fn entry, :ok ->
      case blob_head(files_dir, entry["sha256"]) do
        {:ok, <<0x7F, "ELF", _::binary>>} ->
          {:halt, {:refused, "ships a native file outside priv (#{entry["path"]})"}}

        {:ok, _head} ->
          {:cont, :ok}

        :missing ->
          {:halt, {:error, {:artifacts_unstaged, [entry["sha256"]]}}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp blob_head(files_dir, sha) do
    [Path.join(files_dir, sha), ArtifactStore.blob_path(sha)]
    |> Enum.find_value(:missing, fn path ->
      with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
           {:ok, head} when is_binary(head) <-
             File.open(path, [:read, :binary], &IO.binread(&1, 4)) do
        {:ok, head}
      else
        {:ok, :eof} -> {:ok, ""}
        _ -> nil
      end
    end)
  end

  defp read_priv(entries, files_dir) do
    entries
    |> Enum.filter(&String.starts_with?(&1["path"], "priv/"))
    |> Enum.reduce_while({:ok, [], 0}, fn entry, {:ok, acc, used} ->
      case read_blob(files_dir, entry["sha256"], @max_priv_bytes - used) do
        {:ok, bytes} ->
          "priv/" <> path = entry["path"]
          file = %{path: path, mode: entry["mode"] || 0o644, bytes: bytes}
          {:cont, {:ok, [file | acc], used + byte_size(bytes)}}

        other ->
          {:halt, other}
      end
    end)
    |> then(fn
      {:ok, files, _used} -> {:ok, Enum.reverse(files)}
      other -> other
    end)
  end

  # A blob in the run's files dir, else already moved into the store by an
  # earlier attempt; hashed again either way.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_blob(files_dir, sha, budget) do
    paths = [Path.join(files_dir, sha), ArtifactStore.blob_path(sha)]

    case Enum.find_value(paths, &read_capped(&1, budget)) do
      {:ok, bytes} ->
        if StaticPriv.sha256(bytes) == sha,
          do: {:ok, bytes},
          else: {:refused, "ships a file that is not the one its manifest names (#{sha})"}

      :over ->
        {:refused, "ships more than 128 MiB of priv files"}

      nil ->
        {:error, {:artifacts_unstaged, [sha]}}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_capped(path, budget) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size > budget -> :over
      {:ok, %File.Stat{type: :regular}} -> read_file(path)
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> nil
    end
  end

  defp elf?(<<0x7F, "ELF", _::binary>>), do: true
  defp elf?(_bytes), do: false

  defp loadable(elf, triple) do
    {:ok, machine} = HostTriple.elf_machine(triple)

    case Enum.find(elf, &(not loads?(&1.bytes, machine))) do
      nil -> :ok
      file -> {:refused, "ships a native file #{triple} cannot load (priv/#{file.path})"}
    end
  end

  defp loads?(bytes, machine) when byte_size(bytes) <= @max_elf,
    do: match?({:ok, %{class: 64, type: :dyn, machine: ^machine}}, Elf.read(bytes))

  defp loads?(_bytes, _machine), do: false

  defp static_priv([], _tarball), do: :ok

  defp static_priv(files, tarball) do
    case StaticPriv.check(files, tarball) do
      :ok -> :ok
      {:error, reason, _details} -> {:refused, reason}
    end
  end

  defp origins(elf, reported, tarball, files_dir) do
    files =
      Enum.map(elf, &%{"path" => "priv/" <> &1.path, "sha256" => StaticPriv.sha256(&1.bytes)})

    case NifOrigin.checksum_files(tarball) do
      {:ok, none} when map_size(none) == 0 ->
        {:refused, files |> Enum.map(& &1["path"]) |> Enum.min() |> NifOrigin.compiled_refusal()}

      {:ok, checksums} ->
        verify_origins(files, checksums, reported, files_dir)

      :error ->
        {:refused, "ships native files whose checksum file could not be read"}
    end
  end

  defp verify_origins(files, checksums, reported, files_dir) when is_list(reported) do
    archives =
      for %{"archive" => name, "archive_sha256" => sha} <- reported,
          is_binary(name) and is_binary(sha) and Regex.match?(@sha, sha),
          {:ok, bytes} <- [read_archive(files_dir, sha)],
          into: %{},
          do: {name, bytes}

    case NifOrigin.verify(files, checksums, archives) do
      {:ok, origins} ->
        if Enum.sort(origins) == Enum.sort(reported),
          do: :ok,
          else: {:refused, "names other origins than its files have"}

      {:error, reason} ->
        {:refused, reason}
    end
  end

  defp verify_origins(_files, _checksums, _reported, _files_dir),
    do: {:refused, "names no origins for its downloaded native files"}

  defp read_archive(files_dir, sha) do
    case read_blob(files_dir, sha, NifOrigin.max_archive_bytes()) do
      {:ok, bytes} -> {:ok, bytes}
      _ -> :error
    end
  end

  defp needs(priv) do
    entries =
      Enum.map(priv, &%{"path" => "priv/" <> &1.path, "sha256" => StaticPriv.sha256(&1.bytes)})

    bytes = Map.new(priv, &{StaticPriv.sha256(&1.bytes), &1.bytes})

    case ElfFacts.compute(entries, &Map.fetch(bytes, &1)) do
      %{native: true, portable: true, needs: needs} -> {:ok, needs}
      _ -> {:refused, "ships native files whose needs cannot be read"}
    end
  end

  # Every listed blob is moved into the store first (a missing one is
  # retried), then the row, the blobs' registry rows and the row's
  # memberships are written together.
  defp write(attrs, shas, opts) do
    with {:ok, staged} <- stage(shas, opts.files_dir) do
      Portal.Repo.transaction(fn -> write_rows(attrs, staged) end)
    end
  end

  defp write_rows(attrs, staged) do
    with {:ok, row} <- upsert(attrs),
         :ok <- register(staged),
         :ok <- memberships(row.id, staged) do
      row
    else
      {:error, reason} -> Portal.Repo.rollback(reason)
    end
  end

  defp stage(shas, files_dir) do
    {staged, missing} =
      Enum.reduce(shas, {[], []}, fn sha, {staged, missing} ->
        case stage_one(sha, files_dir) do
          {:ok, entry} -> {[entry | staged], missing}
          :missing -> {staged, [sha | missing]}
        end
      end)

    if missing == [], do: {:ok, staged}, else: {:error, {:artifacts_unstaged, missing}}
  end

  defp stage_one(sha, files_dir) do
    case ArtifactStore.put(sha, Path.join(files_dir, sha)) do
      {:ok, %{disk_path: path, byte_size: size}} ->
        {:ok, %{sha256: sha, byte_size: size, disk_path: path}}

      _ ->
        if ArtifactStore.present?(sha), do: {:ok, stored(sha)}, else: :missing
    end
  end

  defp stored(sha) do
    path = ArtifactStore.blob_path(sha)
    %{sha256: sha, byte_size: File.stat!(path).size, disk_path: path}
  end

  defp upsert(attrs) do
    HostNativeBuild
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(domain: Portal.Catalog)
  end

  defp register(staged) do
    Enum.reduce_while(staged, :ok, fn entry, :ok ->
      case Artifact
           |> Ash.Changeset.for_create(:upsert, entry)
           |> Ash.create(domain: Portal.Catalog) do
        {:ok, _artifact} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # The row owns exactly the blobs it lists now: a rebuild's stale ones go.
  defp memberships(row_id, staged) do
    shas = staged |> Enum.map(& &1.sha256) |> Enum.uniq()

    Portal.Repo.query!(
      "DELETE FROM catalog_artifact_memberships " <>
        "WHERE host_native_build_id = $1 AND NOT (sha256 = ANY($2::text[]))",
      [Ecto.UUID.dump!(row_id), shas]
    )

    Enum.reduce_while(shas, :ok, fn sha, :ok ->
      ArtifactMembership
      |> Ash.Changeset.for_create(:upsert_host_native, %{
        sha256: sha,
        host_native_build_id: row_id
      })
      |> Ash.create(domain: Portal.Catalog)
      |> case do
        {:ok, _membership} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end
end
