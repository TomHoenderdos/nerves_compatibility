defmodule Portal.Catalog.ToolchainPriv do
  @moduledoc """
  The host's own check of a passing toolchain build's priv files, at ingest
  (`Portal.Catalog.Ingestion.ingest_toolchain/2`).

  The worker judges the built `priv` inside the build container
  (`NccWorker.StaticPriv`), where a process the build left behind could still
  change the files after it looked, and what it reports is the container's
  word. So before any file of a build with priv files is published, the host
  applies the same rules (`Compatibility.StaticPriv`) to the files the build
  handed over, against a tarball it fetched itself:

    1. The release's outer checksum comes from the signed registry
       (`Portal.HexDeps.outer_checksum/3`, verified against hex.pm's public
       key), and the build's `package_checksum`, from its lock, must be it.
    2. The tarball's bytes (`Portal.HexDeps.tarball/3`) are read once into
       memory and must hash to that checksum.
    3. Every priv file is read from the run's files dir, at most
       `Compatibility.StaticPriv.max_files/0` of them and
       `Compatibility.StaticPriv.max_bytes/0` together, and must hash to the
       SHA-256 its manifest entry names; those bytes, with the manifest's
       mode, are what the rules judge.

  A priv file is an entry whose path is under `priv/`, whichever key of the
  manifest lists it; the key is the container's word as much as the path is.
  A build without priv files fetches nothing. A failed rule, a checksum that
  is not the registry's, or a release the registry does not list is a
  refusal: `{:refused, reason}`, logged as a security event with the package,
  version and, where there is one, the file and both hashes. Hex being
  unreachable or slow is not news about the build: `{:error, reason}`, so the
  ingest job runs again.

  `opts[:hex_outer_checksum]` and `opts[:hex_tarball]` (each
  `fn name, version -> ... end`) replace the two Hex reads; by default they
  are those of `config :portal, :hex_deps` (`Portal.HexDeps`).
  """

  require Logger

  alias Compatibility.StaticPriv
  alias Portal.ArtifactStore

  @lookup_timeout_ms Compatibility.HexCache.lookup_timeout_ms()
  @fetch_receive_timeout_ms 30_000
  @sha ~r/\A[0-9a-f]{64}\z/

  @doc """
  `:ok` when `build`'s priv files may be published, `{:refused, reason}` when
  they may not, `{:error, reason}` when Hex could not be asked. `result` is
  the run's `result.json`, `build` its `toolchain_build`; `opts` the ingest's,
  with `files_dir` and the job's `package` and `version`.
  """
  @spec verify(map(), map(), map()) :: :ok | {:refused, String.t()} | {:error, term()}
  def verify(_result, build, opts) do
    case priv_entries(build) do
      [] -> :ok
      entries -> verify_release(release(opts), entries, build, opts)
    end
  end

  # Every entry listed under `priv`, and every entry whose path is a priv
  # file under whichever other key lists it: a client writes a file at its
  # path, so a `priv/` path under `ebin` lands in priv like any other.
  defp priv_entries(%{"status" => "pass", "file_manifest" => %{} = manifest}) do
    for {key, entries} <- manifest,
        is_list(entries),
        entry <- entries,
        key == "priv" or priv_path?(entry),
        do: entry
  end

  defp priv_entries(_build), do: []

  defp priv_path?(%{"path" => "priv/" <> _}), do: true
  defp priv_path?(_entry), do: false

  # The job's package and version key the row (`Ingestion`, which has already
  # checked that the result names the same ones), so they are the release the
  # files must come from. Nothing here reads the result's own identity.
  defp release(opts) do
    Compatibility.HexCache.pair(%{"name" => opts.package, "version" => opts.version})
  end

  defp verify_release({:ok, {name, version}}, entries, build, opts) do
    checked =
      with {:ok, files} <- read_files(entries, opts.files_dir),
           {:ok, checksum} <- registry_checksum(name, version, opts),
           :ok <- same_as_lock(build["package_checksum"], checksum),
           {:ok, tarball} <- tarball(name, version, opts),
           :ok <- served_is_signed(tarball, checksum) do
        StaticPriv.check(files, tarball)
      end

    outcome(checked, name, version)
  end

  defp verify_release(:error, _entries, _build, _opts) do
    Logger.warning("security: toolchain build priv refused at ingest: not a Hex release")
    {:refused, "names no Hex release to check its priv files against"}
  end

  defp outcome(:ok, _name, _version), do: :ok

  defp outcome({:error, reason, details}, name, version) do
    Logger.warning(
      "security: toolchain build #{name} #{version} priv refused at ingest: " <>
        reason <> Enum.map_join(details, &" #{elem(&1, 0)}=#{elem(&1, 1)}")
    )

    {:refused, reason}
  end

  defp outcome({:error, {:artifacts_unstaged, _shas}} = missing, _name, _version), do: missing

  defp outcome({:error, reason}, name, version) do
    Logger.info(
      "Toolchain build #{name} #{version} priv not checked at ingest: " <>
        "Hex answered #{inspect(reason, limit: 5, printable_limit: 80)}"
    )

    {:error, {:priv_unchecked, reason}}
  end

  # Step 3. The manifest is the container's, so each entry is checked for
  # shape before its path or hash names anything on the host.
  defp read_files(entries, files_dir) do
    if length(entries) > StaticPriv.max_files() do
      StaticPriv.too_many()
    else
      entries
      |> Enum.reduce_while({:ok, [], 0}, &read_entry(&1, &2, files_dir))
      |> then(fn
        {:ok, files, _bytes} -> {:ok, Enum.reverse(files)}
        refusal -> refusal
      end)
    end
  end

  defp read_entry(entry, {:ok, files, used}, files_dir) do
    with {:ok, path, sha, mode} <- entry_shape(entry),
         {:ok, bytes} <- read_blob(files_dir, sha, StaticPriv.max_bytes() - used),
         :ok <- manifest_hash(bytes, sha, path) do
      {:cont, {:ok, [%{path: path, mode: mode, bytes: bytes} | files], used + byte_size(bytes)}}
    else
      refusal -> {:halt, refusal}
    end
  end

  defp entry_shape(%{"path" => "priv/" <> path, "sha256" => sha, "mode" => mode})
       when is_binary(sha) and is_integer(mode) and mode >= 0 do
    if plain_path?(path) and Regex.match?(@sha, sha),
      do: {:ok, path, sha, mode},
      else: malformed()
  end

  defp entry_shape(_entry), do: malformed()

  defp malformed, do: {:error, "ships a priv manifest entry that names no plain file", []}

  # A relative path of printable segments, none of them `.` or `..`.
  defp plain_path?(path) do
    String.valid?(path) and byte_size(path) <= 1024 and String.printable?(path) and
      not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 not in ["", ".", ".."]))
  end

  # The run's files dir holds each blob under its SHA-256. A retry after the
  # blobs were moved into the artifact store reads them there, where `put/2`
  # verified them; either way the bytes are hashed again below.
  # A blob in neither is the same retryable error the ingest gives a file it
  # cannot stage.
  defp read_blob(files_dir, sha, budget) do
    case read_capped(Path.join(files_dir, sha), budget) do
      :enoent -> read_capped(ArtifactStore.blob_path(sha), budget) |> blob_or_refusal(sha)
      other -> blob_or_refusal(other, sha)
    end
  end

  defp blob_or_refusal({:ok, bytes}, _sha), do: {:ok, bytes}
  defp blob_or_refusal(:enoent, sha), do: {:error, {:artifacts_unstaged, [sha]}}
  defp blob_or_refusal(other, _sha), do: blob_or_refusal(other)

  defp blob_or_refusal(:over), do: StaticPriv.too_large()
  defp blob_or_refusal(_other), do: {:error, "ships priv files that could not be read", []}

  # `path` is the files dir or the store joined with a validated SHA-256.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_capped(path, budget) do
    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, bytes} <- File.open(path, [:read, :raw, :binary], &IO.binread(&1, budget + 1)) do
      cond do
        bytes == :eof -> {:ok, ""}
        is_binary(bytes) and byte_size(bytes) <= budget -> {:ok, bytes}
        is_binary(bytes) -> :over
        true -> :unreadable
      end
    else
      {:error, :enoent} -> :enoent
      _ -> :unreadable
    end
  end

  defp manifest_hash(bytes, sha, path) do
    case StaticPriv.sha256(bytes) do
      ^sha ->
        :ok

      actual ->
        {:error, "ships a priv file that is not the one its manifest names (priv/#{path})",
         path: path, expected: sha, actual: actual}
    end
  end

  # Step 1.
  defp registry_checksum(name, version, opts) do
    lookup = Map.get_lazy(opts, :hex_outer_checksum, &default_outer_checksum/0)

    case call(lookup, name, version) do
      {:ok, checksum} when is_binary(checksum) ->
        checksum = String.downcase(checksum)

        if Regex.match?(@sha, checksum),
          do: {:ok, checksum},
          else: {:error, {:malformed_checksum, checksum}}

      {:error, :unknown_release} ->
        {:error, "names a release the Hex registry does not list", []}

      {:error, reason} ->
        {:error, reason}

      other ->
        {:error, {:unexpected, other}}
    end
  end

  defp same_as_lock(locked, checksum) when is_binary(locked) do
    if String.downcase(locked) == checksum,
      do: :ok,
      else: lock_mismatch(locked, checksum)
  end

  defp same_as_lock(locked, checksum), do: lock_mismatch(locked, checksum)

  defp lock_mismatch(locked, checksum) do
    {:error, "locked a package checksum that is not the Hex registry's",
     expected: checksum, actual: show(locked)}
  end

  # Step 2.
  defp tarball(name, version, opts) do
    fetch = Map.get_lazy(opts, :hex_tarball, &default_tarball/0)

    case call(fetch, name, version) do
      {:ok, bytes} when is_binary(bytes) -> {:ok, bytes}
      {:error, :unknown_release} -> {:error, "names a release Hex does not serve", []}
      {:error, :tarball_too_large} -> too_large_tarball()
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  end

  # The size first, so nothing over the cap is hashed.
  defp served_is_signed(tarball, checksum) do
    cond do
      byte_size(tarball) > StaticPriv.max_tarball_bytes() ->
        too_large_tarball()

      StaticPriv.sha256(tarball) == checksum ->
        :ok

      true ->
        {:error, "has a Hex tarball that does not hash to the registry's checksum",
         expected: checksum, actual: StaticPriv.sha256(tarball)}
    end
  end

  defp too_large_tarball, do: {:error, "ships priv files whose Hex tarball is over 8 MiB", []}

  # A Hex read that raises or exits is an answer like any other failure.
  defp call(fun, name, version) do
    fun.(name, version)
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp default_outer_checksum do
    half = div(@lookup_timeout_ms, 2)
    opts = [retry: false, receive_timeout: half, connect_options: [timeout: half]]
    fn name, version -> hex_deps().outer_checksum(name, version, opts) end
  end

  defp default_tarball do
    opts = [
      retry: false,
      receive_timeout: @fetch_receive_timeout_ms,
      connect_options: [timeout: @lookup_timeout_ms]
    ]

    fn name, version -> hex_deps().tarball(name, version, opts) end
  end

  defp hex_deps, do: Application.get_env(:portal, :hex_deps, Portal.HexDeps)

  defp show(term), do: term |> inspect(limit: 5, printable_limit: 80) |> String.slice(0, 120)
end
