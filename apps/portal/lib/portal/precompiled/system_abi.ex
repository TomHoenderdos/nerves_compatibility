defmodule Portal.Precompiled.SystemAbi do
  @moduledoc """
  How the releases of one Nerves system are grouped for precompiled target
  builds, and the signed systems table (`systems.json`) a batch names.

  A release the portal has built on knows its toolchain version from the
  lock (`Compatibility.Elf.series_from_version/1`); one it only knows from
  the system's Hex metadata has a requirement instead
  (`series_from_requirement/1`). Both are rows of `Portal.Catalog.SystemAbi`:
  ingest writes the first kind, `sync_requirements/0` the second, and
  `table/0` reads them and nothing else.

  `render/1` gives the table as canonical JSON (keys sorted at every level,
  no whitespace), so equal rows give equal bytes and an equal SHA-256. A
  batch stores those bytes here (`store/2`) in the transaction that signs
  it, and `stored/1` serves them by that SHA-256.
  """

  require Ash.Query
  require Logger

  alias Portal.Catalog.SystemAbi, as: Row
  alias Portal.Repo

  # What a toolchain puts in every rootfs, kept in the published table
  # whatever the builds need; `ld-linux-*` and `ld-musl-*` too.
  @toolchain_libs MapSet.new([
                    "libc.so.6",
                    "libc.so",
                    "libm.so.6",
                    "libpthread.so.0",
                    "libdl.so.2",
                    "librt.so.1",
                    "libgcc_s.so.1",
                    "libstdc++.so.6"
                  ])

  @warn_bytes 3 * 1024 * 1024
  @client_cap_bytes 4 * 1024 * 1024

  @hex_opts [
    retry: false,
    receive_timeout: 10_000,
    connect_options: [timeout: 5_000],
    negative_cache: true
  ]

  # Results that are published: not withdrawn, from a run not revoked.
  @published """
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  WHERE s.unpublished_at IS NULL AND r.revoked_at IS NULL
  """

  @native_systems "SELECT DISTINCT s.system_pkg " <> @published <> " AND s.native"

  @needed_sonames """
  SELECT s.system_pkg, array_agg(DISTINCT n.soname)
  FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  CROSS JOIN LATERAL jsonb_object_keys(
    CASE WHEN jsonb_typeof(s.elf_needs) = 'object' THEN s.elf_needs ELSE '{}'::jsonb END
  ) AS n(soname)
  WHERE s.unpublished_at IS NULL AND r.revoked_at IS NULL
  GROUP BY s.system_pkg
  """

  @insert """
  INSERT INTO precompiled_system_tables (sha256, body, inserted_at)
  VALUES ($1, $2, (now() AT TIME ZONE 'utc'))
  ON CONFLICT (sha256) DO NOTHING
  """

  @select "SELECT body FROM precompiled_system_tables WHERE sha256 = $1"

  @typedoc "system => release version => entry; see `table/0`."
  @type t :: %{String.t() => %{String.t() => map()}}

  @doc """
  The `major.minor` series a toolchain requirement pins: `"~> 15.3.0"` is
  `"15.3"`. Any other shape (`"~> 15.3"`, `">= 15.3.0"`, an exact version,
  an `or`) does not pin one series and is `nil`, as is a non-string.
  """
  @spec series_from_requirement(term()) :: String.t() | nil
  def series_from_requirement(requirement) when is_binary(requirement) do
    case Regex.run(~r/^\s*~>\s*(\d+)\.(\d+)\.\d+\s*$/, requirement) do
      [_, major, minor] -> major <> "." <> minor
      nil -> nil
    end
  end

  def series_from_requirement(_requirement), do: nil

  @doc """
  For each system with a published native build, records a `"requirement"`
  row (`Portal.Catalog.SystemAbi.observe/1`) for every Hex release newer than
  the system's oldest row that has no row yet: its `nerves_toolchain_*`
  dependency and requirement. A system without rows, a Hex failure, a
  pre-release or a version that does not parse is skipped. Hex is read
  through `Portal.HexDeps.releases/2` (`config :portal, :hex_deps`), which
  caches answers and failures for an hour.
  """
  @spec sync_requirements() :: :ok
  def sync_requirements do
    known = known_versions()
    %{rows: rows} = Repo.query!(@native_systems)

    for [system] <- rows,
        versions = Map.get(known, system, []),
        oldest =
          versions
          |> Enum.map(&release_version/1)
          |> Enum.reject(&is_nil/1)
          |> Enum.min(Version, fn -> nil end),
        oldest != nil do
      sync_system(system, oldest, MapSet.new(versions))
    end

    :ok
  end

  # The versions each system has a row for, as stored.
  defp known_versions do
    Row
    |> Ash.Query.select([:system_pkg, :version])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.system_pkg, & &1.version)
  end

  defp sync_system(system, oldest, known) do
    hex_deps = Application.get_env(:portal, :hex_deps, Portal.HexDeps)

    case hex_deps.releases(system, @hex_opts) do
      {:ok, releases} ->
        for release <- releases,
            version = release_version(release.version),
            version != nil and Version.compare(version, oldest) == :gt,
            not MapSet.member?(known, release.version),
            dep = toolchain_dep(release.deps),
            dep != nil do
          %{
            system_pkg: system,
            version: release.version,
            source: "requirement",
            toolchain_pkg: dep.package,
            toolchain_version: dep.requirement
          }
          |> Row.observe()
          |> warn_failed(system, release.version)
        end

      {:error, reason} ->
        Logger.warning("Could not read the Hex releases of #{system}: #{inspect(reason)}")
    end
  end

  defp warn_failed({:ok, _row}, _system, _version), do: :ok

  defp warn_failed({:error, reason}, system, version) do
    Logger.warning(
      "Could not record the toolchain requirement of #{system} #{version}: #{inspect(reason)}"
    )
  end

  # A release version, or nil for a pre-release or anything that is not one.
  defp release_version(version) when is_binary(version) do
    case Version.parse(version) do
      {:ok, %Version{pre: []} = parsed} -> parsed
      _ -> nil
    end
  end

  defp release_version(_version), do: nil

  # `nerves_toolchain_ctng` is the toolchain builder older systems also list.
  defp toolchain_dep(deps) when is_list(deps) do
    Enum.find(deps, fn dep ->
      is_binary(dep[:package]) and is_binary(dep[:requirement]) and
        String.starts_with?(dep.package, "nerves_toolchain_") and
        dep.package != "nerves_toolchain_ctng"
    end)
  end

  defp toolchain_dep(_deps), do: nil

  @doc """
  The systems table, from `Portal.Catalog.SystemAbi` rows only:
  `%{system => %{version => %{"toolchain" => %{"package", "version",
  "series"}, "otp", "libs"}}}`. A requirement row's toolchain `"version"` is
  nil. `"libs"` keeps only the sonames published builds of that system need
  and the toolchain's own libraries; the row keeps every one.
  """
  @spec table() :: t()
  def table do
    case Ash.read!(Row, domain: Portal.Catalog) do
      [] ->
        %{}

      rows ->
        needs = needed_sonames()

        Enum.reduce(rows, %{}, fn row, acc ->
          entry = %{
            "toolchain" => %{
              "package" => row.toolchain_pkg,
              "version" => if(row.source == "lock", do: row.toolchain_version),
              "series" => row.series
            },
            "otp" => row.otp,
            "libs" => trim(row.libs, Map.get(needs, row.system_pkg, MapSet.new()))
          }

          Map.update(
            acc,
            row.system_pkg,
            %{row.version => entry},
            &Map.put(&1, row.version, entry)
          )
        end)
    end
  end

  defp needed_sonames do
    %{rows: rows} = Repo.query!(@needed_sonames)
    Map.new(rows, fn [system, sonames] -> {system, MapSet.new(sonames)} end)
  end

  defp trim(nil, _needed), do: nil

  defp trim(libs, needed) do
    Map.filter(libs, fn {soname, _versions} ->
      MapSet.member?(needed, soname) or MapSet.member?(@toolchain_libs, soname) or
        String.starts_with?(soname, ["ld-linux-", "ld-musl-"])
    end)
  end

  @doc """
  `systems.json`: `%{"format" => 1, "systems" => table}` as canonical JSON,
  and the lowercase hex SHA-256 of those bytes.
  """
  @spec render(t()) :: {String.t(), binary()}
  def render(table \\ table()) do
    body = canonical(%{"format" => 1, "systems" => table})
    warn_size(byte_size(body))
    {sha256(body), body}
  end

  # A client refuses a table over 4 MiB; warn well before one gets there.
  defp warn_size(size) when size > @warn_bytes do
    Logger.warning(
      "The rendered systems.json is #{size} bytes, past #{@warn_bytes}; " <>
        "clients refuse one over #{@client_cap_bytes}"
    )
  end

  defp warn_size(_size), do: :ok

  defp canonical(map) when is_map(map) do
    inner =
      map
      |> Enum.sort_by(fn {key, _value} -> to_string(key) end)
      |> Enum.map_join(",", fn {key, value} ->
        JSON.encode!(to_string(key)) <> ":" <> canonical(value)
      end)

    "{" <> inner <> "}"
  end

  defp canonical(list) when is_list(list),
    do: "[" <> Enum.map_join(list, ",", &canonical/1) <> "]"

  defp canonical(value), do: JSON.encode!(value)

  defp sha256(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  @doc """
  Stores a rendered table under its SHA-256; one already there is kept.
  `Portal.Precompiled.Batches` calls it in the transaction that inserts the
  batch naming it, so an error must roll that back, never raise out of it.
  """
  @spec store(String.t(), binary()) :: :ok | {:error, term()}
  def store(sha, body) when is_binary(sha) and is_binary(body) do
    # sobelow_skip ["SQL.Query"]
    # The statement is a module constant; sha and body are bound parameters.
    case Repo.query(@insert, [sha, body]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "The table stored under `sha`, only when its bytes still hash to it."
  @spec stored(String.t()) :: {:ok, binary()} | :error
  def stored(sha) when is_binary(sha) do
    with true <- Portal.ArtifactStore.valid_sha256?(sha),
         {:ok, %{rows: [[body]]}} <- Repo.query(@select, [sha]),
         true <- sha256(body) == sha do
      {:ok, body}
    else
      _ -> :error
    end
  end
end
