defmodule Compat.Index.LatestByPackage do
  @moduledoc """
  Loader and validator for latest_by_pkg.json index.

  Schema:
    {
      schema: 2,
      generated_at: iso8601,
      packages: %{
        pkg => %{
          description: string,
          latest_version: string,
          last_run_at: iso8601,
          dependencies: [%{name: string, requirement: string, optional: boolean, app: string | nil}],
          footprint: %{file_count: integer, total_bytes: integer},
          beam_scan: %{...},
          dependency_scans: %{optional(String.t()) => map()},
          systems: %{
            "<system_pkg>@<system_version>" => %{
              system_pkg: string,
              system_version: string,
              status: "pass" | "fail" | "error" | "skipped" | "unknown",
              hex_version_tested: string,
              run_id: string,
              log_path: string
            }
          }
        }
      }
    }
  """

  alias Compat.Types

  defmodule SystemResult do
    @moduledoc false
    @type t :: %__MODULE__{
            system_pkg: String.t(),
            system_version: String.t(),
            status: Types.status(),
            hex_version_tested: String.t(),
            run_id: String.t(),
            log_path: String.t(),
            deterministic: boolean() | nil,
            determinism_changes: list()
          }

    @enforce_keys [:system_pkg, :system_version, :status, :hex_version_tested, :run_id, :log_path]
    defstruct [
      :system_pkg,
      :system_version,
      :status,
      :hex_version_tested,
      :run_id,
      :log_path,
      :deterministic,
      determinism_changes: []
    ]
  end

  defmodule Package do
    @moduledoc false

    defmodule Dependency do
      @moduledoc false
      @type t :: %__MODULE__{
              name: String.t(),
              requirement: String.t(),
              optional: boolean(),
              runtime: boolean(),
              app: String.t() | nil
            }

      @enforce_keys [:name, :requirement, :optional, :runtime]
      defstruct [:name, :requirement, :optional, :runtime, :app]
    end

    defmodule Footprint do
      @moduledoc false

      defmodule ManifestEntry do
        @moduledoc false
        @type t :: %__MODULE__{
                path: String.t(),
                size: integer(),
                sha256: String.t()
              }

        defstruct [:path, :size, :sha256]
      end

      defmodule Stats do
        @moduledoc false
        @type t :: %__MODULE__{
                file_count: integer(),
                total_bytes: integer()
              }

        defstruct file_count: 0, total_bytes: 0
      end

      @type t :: %__MODULE__{
              file_count: integer(),
              total_bytes: integer(),
              firmware_bytes: integer() | nil,
              ebin: Stats.t() | nil,
              priv: Stats.t() | nil,
              manifest: [ManifestEntry.t()],
              per_system: %{optional(String.t()) => t()}
            }

      @enforce_keys [:file_count, :total_bytes]
      defstruct [
        :file_count,
        :total_bytes,
        :firmware_bytes,
        :ebin,
        :priv,
        manifest: [],
        per_system: %{}
      ]
    end

    defmodule BeamScan do
      @moduledoc false

      @type t :: %__MODULE__{
              flags: %{optional(atom()) => boolean()},
              languages: [String.t()],
              beam_count: integer() | nil,
              start_modules: [String.t()],
              protocols: %{defined: [String.t()], impls: [String.t()]},
              samples: %{optional(atom()) => [String.t()]},
              counts: %{optional(atom()) => integer()},
              scanned_systems: [String.t()],
              errors: [String.t()]
            }

      defstruct flags: %{},
                languages: [],
                beam_count: nil,
                start_modules: [],
                protocols: %{defined: [], impls: []},
                samples: %{},
                counts: %{},
                scanned_systems: [],
                errors: []
    end

    @type t :: %__MODULE__{
            package_name: String.t() | nil,
            version: String.t() | nil,
            description: String.t(),
            latest_version: String.t(),
            last_run_at: String.t(),
            dependencies: [Dependency.t()],
            footprint: Footprint.t(),
            beam_scan: BeamScan.t() | nil,
            dependency_scans: %{optional(String.t()) => map()} | nil,
            systems: %{String.t() => SystemResult.t()}
          }

    @enforce_keys [
      :description,
      :latest_version,
      :last_run_at,
      :dependencies,
      :footprint,
      :systems
    ]
    defstruct [
      :package_name,
      :version,
      :description,
      :latest_version,
      :last_run_at,
      :dependencies,
      :github_url,
      :native_components,
      :source_changes,
      :footprint,
      :beam_scan,
      :dependency_scans,
      :systems,
      # True when this entry was synthesized from another package's
      # dependency_scans (by convert_results.extract_dependency_packages)
      # rather than produced by a direct worker scan. Detail page uses
      # this to show a "not yet scanned" banner.
      is_dependency: false
    ]
  end

  @type t :: %__MODULE__{
          schema: integer(),
          generated_at: String.t(),
          packages: %{String.t() => Package.t()}
        }

  @enforce_keys [:schema, :generated_at, :packages]
  defstruct [:schema, :generated_at, :packages]

  @doc """
  Loads and validates a latest_by_pkg.json file.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content),
         {:ok, index} <- parse(data) do
      {:ok, index}
    end
  end

  @doc """
  Parses a decoded JSON map into the struct.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"schema" => schema, "generated_at" => generated_at, "packages" => packages})
      when is_integer(schema) and is_binary(generated_at) and is_map(packages) do
    case parse_packages(packages) do
      {:ok, parsed_packages} ->
        {:ok,
         %__MODULE__{
           schema: schema,
           generated_at: generated_at,
           packages: parsed_packages
         }}

      error ->
        error
    end
  end

  def parse(_), do: {:error, :invalid_schema}

  defp parse_packages(packages) do
    packages
    |> Enum.reduce_while({:ok, %{}}, fn {pkg_name, pkg_data}, {:ok, acc} ->
      case parse_package(pkg_data) do
        {:ok, package} ->
          {:cont, {:ok, Map.put(acc, pkg_name, package)}}

        error ->
          IO.puts("Skipping #{inspect(pkg_data)} due to #{inspect(error)}")
          {:cont, {:ok, acc}}
      end
    end)
  end

  defp parse_package(
         %{
           "description" => desc,
           "latest_version" => version,
           "last_run_at" => last_run,
           "systems" => systems
         } = pkg_data
       )
       when is_binary(desc) and is_binary(version) and is_binary(last_run) and is_map(systems) do
    # Parse dependencies (optional, default to empty list)
    dependencies = Map.get(pkg_data, "dependencies", []) |> parse_dependencies()
    dependency_scans = Map.get(pkg_data, "dependency_scans", %{})

    # Parse footprint (optional, default to zeros)
    footprint =
      case parse_footprint(Map.get(pkg_data, "footprint")) do
        {:ok, fp} -> fp
        _ -> %Package.Footprint{file_count: 0, total_bytes: 0, per_system: %{}}
      end

    beam_scan =
      case parse_beam_scan(Map.get(pkg_data, "beam_scan")) do
        {:ok, scan} -> scan
        _ -> nil
      end

    # Extract package_name and version if available (schema 3)
    package_name = Map.get(pkg_data, "package_name")
    version_field = Map.get(pkg_data, "version")
    native_components = parse_native_components(Map.get(pkg_data, "native_components"))
    github_url = Map.get(pkg_data, "github_url")
    source_changes = parse_source_changes(Map.get(pkg_data, "source_changes"))
    is_dependency = Map.get(pkg_data, "is_dependency") == true

    case parse_systems(systems) do
      {:ok, parsed_systems} ->
        {:ok,
         %Package{
           package_name: package_name,
           version: version_field,
           description: desc,
           latest_version: version,
           last_run_at: last_run,
           dependencies: dependencies,
           github_url: github_url,
           native_components: native_components,
           source_changes: source_changes,
           footprint: footprint,
           beam_scan: beam_scan,
           dependency_scans: dependency_scans,
           systems: parsed_systems,
           is_dependency: is_dependency
         }}

      error ->
        error
    end
  end

  defp parse_package(_), do: {:error, :invalid_package}

  # Normalize native_components from JSON: keys come back as strings and
  # language values should become atoms so downstream code can match on them.
  #
  # The value distinguishes three semantic states:
  #   nil            — the worker never populated the field (package predates
  #                    the feature, or detection couldn't run). Downstream
  #                    code treats this as "unknown".
  #   %{nif: nil, ports: []}  — scanned; no NIF or port detected. Distinct
  #                    from "unknown" because we *did* look.
  #   %{...}         — scanned; at least one of nif/ports was detected.
  defp parse_native_components(nil), do: nil

  defp parse_native_components(%{} = nc) do
    nif = atomize_lang(Map.get(nc, "nif_language"))

    ports =
      nc
      |> Map.get("port_languages", [])
      |> List.wrap()
      |> Enum.map(&atomize_lang/1)
      |> Enum.reject(&is_nil/1)

    evidence = Map.get(nc, "evidence", []) |> List.wrap()

    %{nif_language: nif, port_languages: ports, evidence: evidence}
  end

  defp parse_native_components(_), do: nil

  defp atomize_lang(nil), do: nil
  defp atomize_lang(s) when is_binary(s), do: String.to_atom(s)
  defp atomize_lang(a) when is_atom(a), do: a

  # Directories whose contents are tool-owned build scratch (rebar3's
  # _build, elixir_ls cache, etc.) rather than source — filtering here on
  # the READ side covers results produced before NccWorker.SourceScanner
  # learned to skip them on the write side. Keep this list in sync with
  # the worker's @ignored_top_dirs.
  @source_changes_ignored_top_dirs ~w(_build .rebar3 .elixir_ls .git .fetch .hex)

  # source_changes comes back as %{"changed"=>bool, "added"=>[...], ...}.
  # Strip ignored-dir paths, return nil when the real change set is empty
  # so downstream code can `if @package.source_changes` cleanly.
  defp parse_source_changes(nil), do: nil

  defp parse_source_changes(%{} = sc) do
    added = sc |> Map.get("added", []) |> List.wrap() |> reject_ignored()
    modified = sc |> Map.get("modified", []) |> List.wrap() |> reject_ignored()
    deleted = sc |> Map.get("deleted", []) |> List.wrap() |> reject_ignored()

    if added != [] or modified != [] or deleted != [] do
      %{changed: true, added: added, modified: modified, deleted: deleted}
    else
      nil
    end
  end

  defp parse_source_changes(_), do: nil

  defp reject_ignored(paths) do
    Enum.reject(paths, fn p ->
      case p |> to_string() |> Path.split() do
        [top | _] -> top in @source_changes_ignored_top_dirs
        _ -> false
      end
    end)
  end

  defp parse_dependencies(deps) do
    Enum.reduce(deps, [], fn dep, acc ->
      case dep do
        %{"name" => name, "requirement" => req, "optional" => opt, "runtime" => runtime}
        when is_binary(name) and is_binary(req) and is_boolean(opt) and is_boolean(runtime) ->
          app = Map.get(dep, "app")

          [
            %Package.Dependency{
              name: name,
              requirement: req,
              optional: opt,
              runtime: runtime,
              app: app
            }
            | acc
          ]

        # Backward compatibility: if runtime is missing, assume true
        %{"name" => name, "requirement" => req, "optional" => opt}
        when is_binary(name) and is_binary(req) and is_boolean(opt) ->
          app = Map.get(dep, "app")

          [
            %Package.Dependency{
              name: name,
              requirement: req,
              optional: opt,
              runtime: true,
              app: app
            }
            | acc
          ]

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
  end

  defp parse_beam_scan(nil), do: {:ok, nil}

  defp parse_beam_scan(%{} = scan) do
    flags =
      scan
      |> Map.get("flags", %{})
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        case parse_flag_key(k) do
          nil -> acc
          key -> Map.put(acc, key, v in [true, "true", 1])
        end
      end)

    samples =
      scan
      |> Map.get("samples", %{})
      |> Enum.reduce(%{}, fn {k, vals}, acc ->
        case parse_flag_key(k) do
          nil -> acc
          key when is_list(vals) -> Map.put(acc, key, Enum.map(vals, &to_string/1))
          _ -> acc
        end
      end)

    counts =
      scan
      |> Map.get("counts", %{})
      |> Enum.reduce(%{}, fn {k, v}, acc ->
        case parse_flag_key(k) do
          nil -> acc
          key when is_integer(v) -> Map.put(acc, key, v)
          _ -> acc
        end
      end)

    protocols_map = Map.get(scan, "protocols", %{})

    protocols = %{
      defined: Map.get(protocols_map, "defined", []) |> Enum.map(&to_string/1),
      impls: Map.get(protocols_map, "impls", []) |> Enum.map(&to_string/1)
    }

    beam_scan = %Package.BeamScan{
      flags: flags,
      languages: Map.get(scan, "languages", []) |> Enum.map(&to_string/1),
      beam_count: Map.get(scan, "beam_count"),
      start_modules: Map.get(scan, "start_modules", []) |> Enum.map(&to_string/1),
      protocols: protocols,
      samples: samples,
      counts: counts,
      scanned_systems: Map.get(scan, "scanned_systems", []) |> Enum.map(&to_string/1),
      errors: Map.get(scan, "errors", []) |> Enum.map(&to_string/1)
    }

    {:ok, beam_scan}
  end

  defp parse_beam_scan(_), do: {:error, :invalid_beam_scan}

  defp parse_flag_key(:start_callback), do: :start_callback
  defp parse_flag_key(:nif), do: :nif
  defp parse_flag_key(:shell), do: :shell
  defp parse_flag_key(:app_env), do: :app_env
  defp parse_flag_key(:os_env), do: :os_env
  defp parse_flag_key(:os_exec), do: :os_exec
  defp parse_flag_key(:halt), do: :halt
  defp parse_flag_key("start_callback"), do: :start_callback
  defp parse_flag_key("nif"), do: :nif
  defp parse_flag_key("shell"), do: :shell
  defp parse_flag_key("app_env"), do: :app_env
  defp parse_flag_key("os_env"), do: :os_env
  defp parse_flag_key("os_exec"), do: :os_exec
  defp parse_flag_key("halt"), do: :halt
  defp parse_flag_key(_), do: nil

  defp parse_footprint(%{"file_count" => fc, "total_bytes" => tb} = fp)
       when is_integer(fc) and is_integer(tb) do
    ebin =
      case Map.get(fp, "ebin") do
        %{"file_count" => efc, "total_bytes" => etb} ->
          %Package.Footprint.Stats{file_count: efc, total_bytes: etb}

        _ ->
          %Package.Footprint.Stats{}
      end

    priv =
      case Map.get(fp, "priv") do
        %{"file_count" => pfc, "total_bytes" => ptb} ->
          %Package.Footprint.Stats{file_count: pfc, total_bytes: ptb}

        _ ->
          %Package.Footprint.Stats{}
      end

    manifest =
      case Map.get(fp, "manifest") do
        list when is_list(list) ->
          Enum.map(list, fn entry ->
            %Package.Footprint.ManifestEntry{
              path: Map.get(entry, "path", ""),
              size: Map.get(entry, "size", 0),
              sha256: Map.get(entry, "sha256", "")
            }
          end)

        _ ->
          []
      end

    per_system =
      case Map.get(fp, "per_system") do
        %{} = ps_map ->
          ps_map
          |> Enum.map(fn {sys, val} ->
            case parse_footprint(val) do
              {:ok, parsed} -> {sys, parsed}
              _ -> {sys, %Package.Footprint{file_count: 0, total_bytes: 0}}
            end
          end)
          |> Map.new()

        _ ->
          %{}
      end

    {:ok,
     %Package.Footprint{
       file_count: fc,
       total_bytes: tb,
       firmware_bytes: Map.get(fp, "firmware_bytes"),
       ebin: ebin,
       priv: priv,
       manifest: manifest,
       per_system: per_system
     }}
  end

  # Handle dependency packages that only have file_manifest and per_system
  defp parse_footprint(%{"per_system" => per_system_map}) when is_map(per_system_map) do
    per_system =
      per_system_map
      |> Enum.map(fn {sys, val} ->
        case parse_footprint(val) do
          {:ok, parsed} -> {sys, parsed}
          _ -> {sys, %Package.Footprint{file_count: 0, total_bytes: 0}}
        end
      end)
      |> Map.new()

    {:ok,
     %Package.Footprint{
       file_count: 0,
       total_bytes: 0,
       per_system: per_system
     }}
  end

  defp parse_footprint(_), do: {:error, :invalid_footprint}

  defp parse_systems(systems) do
    systems
    |> Enum.reduce_while({:ok, %{}}, fn {sys_key, sys_data}, {:ok, acc} ->
      case parse_system_result(sys_data) do
        {:ok, result} -> {:cont, {:ok, Map.put(acc, sys_key, result)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_system_result(
         %{
           "system_pkg" => sys_pkg,
           "system_version" => sys_ver,
           "status" => status,
           "hex_version_tested" => hex_ver,
           "run_id" => run_id,
           "log_path" => log_path,
           "deterministic" => deterministic
         } = data
       )
       when is_binary(sys_pkg) and is_binary(sys_ver) and is_binary(status) and
              is_binary(hex_ver) and is_binary(run_id) and is_binary(log_path) do
    changes = Map.get(data, "determinism_changes", [])

    {:ok,
     %SystemResult{
       system_pkg: sys_pkg,
       system_version: sys_ver,
       status: Types.parse_status(status),
       hex_version_tested: hex_ver,
       run_id: run_id,
       log_path: log_path,
       deterministic: deterministic,
       determinism_changes: changes
     }}
  end

  defp parse_system_result(%{
         "system_pkg" => sys_pkg,
         "system_version" => sys_ver,
         "status" => status,
         "hex_version_tested" => hex_ver,
         "run_id" => run_id,
         "log_path" => log_path
       })
       when is_binary(sys_pkg) and is_binary(sys_ver) and is_binary(status) and
              is_binary(hex_ver) and is_binary(run_id) and is_binary(log_path) do
    {:ok,
     %SystemResult{
       system_pkg: sys_pkg,
       system_version: sys_ver,
       status: Types.parse_status(status),
       hex_version_tested: hex_ver,
       run_id: run_id,
       log_path: log_path,
       deterministic: nil,
       determinism_changes: []
     }}
  end

  defp parse_system_result(_), do: {:error, :invalid_system_result}
end
