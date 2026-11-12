defmodule Portal.Catalog.SystemAbi do
  @moduledoc """
  One row per Nerves system release (`system_pkg`, `version`): the toolchain
  it builds with, the series of that toolchain, its full OTP version and its
  rootfs library table (soname => the symbol versions the library defines).
  A precompiled target build made on one release is matched on another
  through these.

  `source` says where the toolchain came from:

    * `"lock"` - a build's lock resolved it (a target build's result.json
      facts, or a `system_abi` run); `series` is that version's
      (`Compatibility.Elf.series_from_version/1`);
    * `"requirement"` - only the system's Hex requirement is known;
      `series` is the one it pins
      (`Portal.Precompiled.SystemAbi.series_from_requirement/1`).

  Rows are written only through `observe/1`, which never overwrites a value
  a release was already seen with: a release's toolchain, OTP and libraries
  do not change once it is published, so a different value is news worth
  an error, not an update. A lock observation does replace a requirement
  row's toolchain, which was only ever a requirement.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  require Ash.Query
  require Logger

  alias Compatibility.Elf
  alias Portal.Precompiled.SystemAbi, as: Series
  alias Portal.Repo

  @sources ["lock", "requirement"]
  @fields [:toolchain_pkg, :toolchain_version, :otp, :libs]
  @libcs ["libc.so.6", "libc.so"]

  postgres do
    table("catalog_system_abi")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :upsert do
      accept([
        :system_pkg,
        :version,
        :toolchain_pkg,
        :toolchain_version,
        :series,
        :source,
        :otp,
        :libs,
        :observed_at
      ])

      upsert?(true)
      upsert_identity(:unique_release)
      upsert_fields([:observed_at])
    end

    update :observe do
      accept([:toolchain_pkg, :toolchain_version, :series, :source, :otp, :libs, :observed_at])
    end
  end

  identities do
    identity(:unique_release, [:system_pkg, :version])
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:system_pkg, :string, allow_nil?: false, public?: true)
    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:toolchain_pkg, :string, public?: true)
    # A version for a `"lock"` row, a requirement for a `"requirement"` one.
    attribute(:toolchain_version, :string, public?: true)
    attribute(:series, :string, public?: true)

    attribute :source, :string do
      allow_nil?(false)
      public?(true)
      constraints(match: ~r/\A(lock|requirement)\z/)
    end

    attribute(:otp, :string, public?: true)
    # Nil unless it names a libc: a table without one was not read whole.
    attribute(:libs, :map, public?: true)
    attribute(:observed_at, :utc_datetime_usec, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  @type observation :: %{
          required(:system_pkg) => String.t(),
          required(:version) => String.t(),
          required(:source) => String.t(),
          optional(:toolchain_pkg) => String.t() | nil,
          optional(:toolchain_version) => String.t() | nil,
          optional(:otp) => String.t() | nil,
          optional(:libs) => %{String.t() => [String.t()]} | nil
        }

  @doc """
  Records what one observation says about a release:

    * no row yet: inserts one;
    * a row: fills its null `toolchain_pkg`, `toolchain_version`, `otp` and
      `libs` from the observation and keeps every value it already has. A
      different non-null value is logged, naming the release and the field
      (an error, with a `[:portal, :system_abi, :conflict]` telemetry event,
      on a `"lock"` row);
    * a `"lock"` observation of a `"requirement"` row replaces its toolchain
      and series and makes it a `"lock"` row; a `"requirement"` observation
      of a `"lock"` row changes nothing.

  A `libs` table that is empty or names no libc (`libc.so.6`, `libc.so`) is
  logged and taken as nil.
  """
  @spec observe(observation()) :: {:ok, t()} | {:error, term()}
  def observe(%{system_pkg: system_pkg, version: version, source: source} = observation)
      when is_binary(system_pkg) and is_binary(version) and source in @sources do
    incoming = %{
      toolchain_pkg: string(observation[:toolchain_pkg]),
      toolchain_version: string(observation[:toolchain_version]),
      otp: string(observation[:otp]),
      libs: libs(observation[:libs], system_pkg, version)
    }

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1::text))", [
        "system_abi@" <> system_pkg <> "@" <> version
      ])

      case write(existing(system_pkg, version), system_pkg, version, source, incoming) do
        {:ok, row} -> row
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def observe(observation), do: {:error, {:invalid_observation, observation}}

  @doc """
  Observes every release of a `system_abi` run's result.json `system_abi`
  list as `"lock"`: `%{"system", "version", "toolchain" => %{"package",
  "version"}, "otp_full", "system_libs"}`. An entry with an `"error"`, or
  one that is not shaped like that, is skipped; one that cannot be written
  is logged.
  """
  @spec observe_all(term()) :: :ok
  def observe_all(entries) when is_list(entries) do
    Enum.each(entries, fn
      %{"system" => system, "version" => version} = entry when not is_map_key(entry, "error") ->
        toolchain = if is_map(entry["toolchain"]), do: entry["toolchain"], else: %{}

        %{
          system_pkg: system,
          version: version,
          toolchain_pkg: toolchain["package"],
          toolchain_version: toolchain["version"],
          otp: entry["otp_full"],
          libs: entry["system_libs"],
          source: "lock"
        }
        |> observe()
        |> warn_failed(system, version)

      _entry ->
        :ok
    end)
  end

  def observe_all(_entries), do: :ok

  defp warn_failed({:ok, _row}, _system, _version), do: :ok

  defp warn_failed({:error, reason}, system, version) do
    Logger.warning(
      "Could not record the ABI of #{inspect(system)} #{inspect(version)}: #{inspect(reason)}"
    )
  end

  defp existing(system_pkg, version) do
    __MODULE__
    |> Ash.Query.filter(system_pkg == ^system_pkg and version == ^version)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  defp write(nil, system_pkg, version, source, incoming) do
    __MODULE__
    |> Ash.Changeset.for_create(
      :upsert,
      Map.merge(incoming, %{
        system_pkg: system_pkg,
        version: version,
        source: source,
        series: series(source, incoming.toolchain_version),
        observed_at: DateTime.utc_now()
      })
    )
    |> Ash.create(domain: Portal.Catalog)
  end

  defp write(%{source: "lock"} = row, _system_pkg, _version, "requirement", _incoming),
    do: {:ok, row}

  defp write(row, _system_pkg, _version, source, incoming) do
    {base, fields} = replaced_toolchain(row, source, incoming)

    changes =
      fields
      |> Enum.reduce(base, fn field, acc ->
        merge_field(row, field, Map.fetch!(incoming, field), acc)
      end)
      |> Map.reject(fn {field, value} -> Map.fetch!(row, field) == value end)

    if changes == %{} do
      {:ok, row}
    else
      source = Map.get(changes, :source, row.source)
      toolchain_version = Map.get(changes, :toolchain_version, row.toolchain_version)

      row
      |> Ash.Changeset.for_update(
        :observe,
        Map.merge(changes, %{
          series: series(source, toolchain_version),
          observed_at: DateTime.utc_now()
        })
      )
      |> Ash.update(domain: Portal.Catalog)
    end
  end

  # A lock observation's toolchain replaces a requirement row's, and makes it
  # a lock row; every other field is merged.
  defp replaced_toolchain(%{source: "requirement"}, "lock", %{toolchain_version: v} = incoming)
       when is_binary(v) do
    {%{source: "lock", toolchain_pkg: incoming.toolchain_pkg, toolchain_version: v},
     [:otp, :libs]}
  end

  defp replaced_toolchain(_row, _source, _incoming), do: {%{}, @fields}

  defp merge_field(_row, _field, nil, acc), do: acc

  defp merge_field(row, field, value, acc) do
    case Map.fetch!(row, field) do
      nil ->
        Map.put(acc, field, value)

      old ->
        if same?(field, old, value), do: acc, else: conflict(row, field, old, value, acc)
    end
  end

  defp same?(:libs, old, new), do: normalize_libs(old) == new
  defp same?(_field, old, new), do: old == new

  defp conflict(%{source: "lock"} = row, field, old, new, acc) do
    Logger.error(
      "System ABI conflict for #{row.system_pkg} #{row.version}: #{field} was " <>
        "#{short(old)}, now observed as #{short(new)}; keeping the first"
    )

    :telemetry.execute([:portal, :system_abi, :conflict], %{count: 1}, %{
      system_pkg: row.system_pkg,
      version: row.version,
      field: field
    })

    acc
  end

  defp conflict(row, field, old, new, acc) do
    Logger.warning(
      "System ABI conflict for #{row.system_pkg} #{row.version}: #{field} was " <>
        "#{short(old)}, now observed as #{short(new)}; keeping the first"
    )

    acc
  end

  defp short(value), do: value |> inspect(limit: 5, printable_limit: 80)

  defp series("lock", version) when is_binary(version), do: Elf.series_from_version(version)
  defp series("requirement", requirement), do: Series.series_from_requirement(requirement)
  defp series(_source, _version), do: nil

  defp string(value) when is_binary(value) and byte_size(value) in 1..200, do: value
  defp string(_value), do: nil

  defp libs(nil, _system_pkg, _version), do: nil

  defp libs(libs, system_pkg, version) do
    normalized = normalize_libs(libs)

    if is_map(normalized) and Enum.any?(@libcs, &Map.has_key?(normalized, &1)) do
      normalized
    else
      Logger.warning(
        "Not recording the library table of #{system_pkg} #{version}: it names no libc"
      )

      nil
    end
  end

  # soname => sorted, deduplicated version names; nil for anything else.
  defp normalize_libs(libs) when is_map(libs) do
    if Enum.all?(libs, &valid_lib?/1),
      do:
        Map.new(libs, fn {soname, versions} ->
          {soname, versions |> Enum.uniq() |> Enum.sort()}
        end)
  end

  defp normalize_libs(_libs), do: nil

  defp valid_lib?({soname, versions}),
    do: is_binary(soname) and is_list(versions) and Enum.all?(versions, &is_binary/1)
end
