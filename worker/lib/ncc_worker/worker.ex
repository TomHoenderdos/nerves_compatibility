defmodule NccWorker.Worker do
  @moduledoc """
  Main worker implementation that evaluates a package against Nerves systems.
  """

  alias NccWorker.{BeamScan, Footprint, HexMetadata, LockPolicy, Project, Scanner}

  @forced_skip_system "forced@admin@unknown"

  @type input :: %{
          required(:run_id) => String.t(),
          required(:image) => %{
            required(:name) => String.t(),
            required(:digest) => String.t()
          },
          required(:package) => %{
            required(:name) => String.t(),
            optional(:requirement) => String.t(),
            optional(:version) => String.t()
          },
          optional(:systems_override) => %{String.t() => String.t()},
          optional(:systems_filter) => [String.t()],
          optional(:paths) => %{
            optional(:work_dir) => String.t(),
            optional(:output_dir) => String.t()
          },
          optional(:limits) => %{
            optional(:per_system_timeout_sec) => integer(),
            optional(:log_tail_bytes) => integer()
          }
        }

  @type result :: %{
          run_id: String.t(),
          package: %{
            name: String.t(),
            version: String.t(),
            description: String.t(),
            dependencies:
              list(%{
                name: String.t(),
                requirement: String.t(),
                optional: boolean(),
                runtime: boolean(),
                app: String.t() | nil
              }),
            footprint: %{
              file_count: integer(),
              total_bytes: integer()
            }
          },
          image: %{
            name: String.t(),
            digest: String.t()
          },
          toolchain: %{
            elixir: String.t(),
            erlang: String.t(),
            mix: String.t(),
            nerves_bootstrap: String.t() | nil
          },
          systems: %{
            String.t() => %{
              status: Compat.Types.status(),
              duration_sec: float(),
              firmware_size_bytes: integer() | nil,
              log_tail: String.t(),
              system_version: String.t() | nil,
              beam_scan: map() | nil,
              dependency_scans: map() | nil,
              error: String.t() | nil
            }
          },
          finished_at: String.t()
        }

  @default_timeout_sec 600
  @default_log_tail_bytes 4096

  @doc """
  Runs the worker evaluation for a single package.

  ## Parameters
    - input: Map containing run configuration (see @type input)

  ## Returns
    - {:ok, result} - Evaluation completed successfully
    - {:error, reason} - Worker failed (internal error or policy violation)
  """
  @spec run(input()) :: {:ok, result()} | {:error, term()}
  def run(input) do
    with :ok <- validate_input(input),
         {:ok, paths} <- setup_paths(input),
         {:ok, toolchain} <- detect_toolchain() do
      timeout = get_in(input, [:limits, :per_system_timeout_sec]) || @default_timeout_sec
      log_tail_bytes = get_in(input, [:limits, :log_tail_bytes]) || @default_log_tail_bytes

      {description, github_url, release_info, retired_info, metadata_version, build_tools} =
        case HexMetadata.fetch(input.package.name, input.package[:version]) do
          {:ok,
           %{
             description: desc,
             github_url: gh,
             dependencies: release,
             retired: retired,
             release_version: release_version,
             build_tools: tools
           }} ->
            {desc, gh, release, retired, release_version, tools || []}

          {:error, reason} ->
            IO.puts(:stderr, "Warning: Failed to fetch Hex metadata: #{inspect(reason)}")
            {"Package #{input.package.name}", nil, nil, nil, nil, []}
        end

      package_version_hint = metadata_version || input.package[:version]

      if gleam_build_tool?(build_tools) do
        skip_reason = gleam_skip_reason(build_tools)

        dependencies =
          case release_info do
            release when is_map(release) -> HexMetadata.parse_dependencies(release, [])
            _ -> []
          end

        beam_scan = build_skipped_beam_scan(build_tools)

        system_results =
          build_forced_skip_system(paths.output_dir, skip_reason, log_tail_bytes, beam_scan)

        footprint = empty_footprint()

        result = %{
          run_id: input.run_id,
          package: %{
            name: input.package.name,
            version: package_version_hint || "unknown",
            description: description,
            github_url: github_url,
            dependencies: dependencies,
            footprint: footprint
          },
          image: input.image,
          toolchain: toolchain,
          systems: system_results,
          finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        {:ok, result}
      else
        with {:ok, project_dir} <-
               Project.create(paths.work_dir, input.package, input[:systems_override]),
             {:ok, _} <- Project.add_package(project_dir, input.package),
             :ok <- LockPolicy.validate(project_dir) do
          systems = discover_systems(project_dir, input[:systems_filter])

          if retired_info do
            reason = format_retired_reason(retired_info)

            system_results =
              build_forced_skip_system(paths.output_dir, reason, log_tail_bytes, nil)

            footprint = empty_footprint()

            result = %{
              run_id: input.run_id,
              package: %{
                name: input.package.name,
                version: package_version_hint || "unknown",
                description: description,
                github_url: github_url,
                dependencies: [],
                footprint: footprint
              },
              image: input.image,
              toolchain: toolchain,
              systems: system_results,
              finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            {:ok, result}
          else
            # Source-dir snapshot: taken after `mix deps.get` populated
            # `deps/<pkg>/` but before any firmware or host compile runs.
            # Compared with a second snapshot taken after all builds so we
            # can flag packages that write artifacts back into source (bad
            # news when switching MIX_TARGET between builds).
            pkg_source_dir = Path.join([project_dir, "deps", input.package.name])

            {:ok, source_before} = NccWorker.SourceScanner.snapshot(pkg_source_dir)

            host_result = compile_host(project_dir, paths.output_dir, log_tail_bytes)

            system_results =
              build_all_systems(
                project_dir,
                systems,
                paths.output_dir,
                timeout,
                log_tail_bytes,
                input.package.name
              )
              |> Map.merge(%{"host" => host_result})

            {:ok, source_after} = NccWorker.SourceScanner.snapshot(pkg_source_dir)
            source_changes = NccWorker.SourceScanner.diff(source_before, source_after)

            package_version =
              case get_package_version(project_dir, input.package) do
                "unknown" when is_binary(package_version_hint) ->
                  package_version_hint

                version ->
                  version
              end

            runtime_apps =
              case NccWorker.AppFile.find_app_file(project_dir, input.package.name) do
                {:ok, app_file_path} ->
                  case NccWorker.AppFile.read_applications(app_file_path) do
                    {:ok, apps} ->
                      apps

                    {:error, reason} ->
                      IO.puts(:stderr, "Warning: Failed to read .app file: #{inspect(reason)}")
                      []
                  end

                {:error, reason} ->
                  IO.puts(:stderr, "Warning: Failed to find .app file: #{inspect(reason)}")
                  []
              end

            {final_description, dependencies} =
              case release_info do
                release when is_map(release) ->
                  deps = HexMetadata.parse_dependencies(release, runtime_apps)
                  {description, deps}

                _ ->
                  {description, []}
              end

            footprint =
              case Footprint.calculate(project_dir, input.package.name, systems) do
                {:ok, stats} ->
                  stats

                {:error, reason} ->
                  IO.puts(:stderr, "Warning: Failed to calculate footprint: #{inspect(reason)}")
                  empty_footprint()
              end

            native_components = NccWorker.NativeLang.detect(project_dir, input.package.name)

            result = %{
              run_id: input.run_id,
              package: %{
                name: input.package.name,
                version: package_version,
                description: final_description,
                github_url: github_url,
                dependencies: dependencies,
                native_components: native_components,
                source_changes: source_changes,
                footprint: footprint
              },
              image: input.image,
              toolchain: toolchain,
              systems: system_results,
              finished_at: DateTime.utc_now() |> DateTime.to_iso8601()
            }

            {:ok, result}
          end
        end
      end
    end
  end

  @spec validate_input(input()) :: :ok | {:error, term()}
  defp validate_input(input) do
    cond do
      !is_binary(input[:run_id]) || input.run_id == "" ->
        {:error, :missing_run_id}

      !is_map(input[:image]) ->
        {:error, :missing_image}

      !is_binary(get_in(input, [:image, :name])) ->
        {:error, :missing_image_name}

      !is_binary(get_in(input, [:image, :digest])) ->
        {:error, :missing_image_digest}

      !is_map(input[:package]) ->
        {:error, :missing_package}

      !is_binary(get_in(input, [:package, :name])) ->
        {:error, :missing_package_name}

      true ->
        :ok
    end
  end

  @spec setup_paths(input()) :: {:ok, map()} | {:error, term()}
  defp setup_paths(input) do
    work_dir = get_in(input, [:paths, :work_dir]) || "/work"
    output_dir = get_in(input, [:paths, :output_dir]) || "/out"

    # Ensure output directories exist
    logs_dir = Path.join(output_dir, "logs")
    File.mkdir_p!(logs_dir)

    {:ok, %{work_dir: work_dir, output_dir: output_dir, logs_dir: logs_dir}}
  end

  @spec detect_toolchain() :: {:ok, map()} | {:error, term()}
  defp detect_toolchain() do
    elixir_version = System.version()
    erlang_version = :erlang.system_info(:otp_release) |> to_string()

    mix_version =
      case System.cmd("mix", ["--version"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.find(&String.starts_with?(&1, "Mix"))
          |> then(&if &1, do: String.replace(&1, "Mix ", ""), else: "unknown")

        _ ->
          "unknown"
      end

    nerves_bootstrap_version =
      case System.cmd("mix", ["nerves.info"], stderr_to_stdout: true) do
        {output, 0} ->
          output
          |> String.split("\n")
          |> Enum.find(&String.contains?(&1, "nerves_bootstrap"))
          |> then(fn
            nil -> nil
            line -> Regex.run(~r/(\d+\.\d+\.\d+)/, line) |> List.last()
          end)

        _ ->
          nil
      end

    {:ok,
     %{
       elixir: elixir_version,
       erlang: erlang_version,
       mix: mix_version,
       nerves_bootstrap: nerves_bootstrap_version
     }}
  end

  @spec discover_systems(String.t(), [String.t()] | nil) :: [
          %{name: String.t(), target: String.t()}
        ]
  defp discover_systems(_project_dir, systems_filter) when is_list(systems_filter) do
    # All available systems
    all_systems = [
      %{name: "nerves_system_rpi0", target: "rpi0"},
      %{name: "nerves_system_rpi4", target: "rpi4"},
      %{name: "nerves_system_rpi5", target: "rpi5"},
      %{name: "nerves_system_qemu_aarch64", target: "qemu_aarch64"},
      %{name: "nerves_system_mangopi_mq_pro", target: "mangopi_mq_pro"},
      %{name: "nerves_system_grisp2", target: "grisp2"},
      %{name: "nerves_system_x86_64", target: "x86_64"},
      %{name: "nerves_system_bbb", target: "bbb"}
    ]

    # Filter to only the systems in the filter list
    Enum.filter(all_systems, fn system -> system.name in systems_filter end)
  end

  defp discover_systems(_project_dir, nil) do
    # Default systems when no filter is provided
    [
      # %{name: "nerves_system_rpi0", target: "rpi0"},
      %{name: "nerves_system_rpi4", target: "rpi4"},
      # %{name: "nerves_system_rpi5", target: "rpi5"},
      # %{name: "nerves_system_qemu_aarch64", target: "qemu_aarch64"},
      %{name: "nerves_system_mangopi_mq_pro", target: "mangopi_mq_pro"},
      # %{name: "nerves_system_grisp2", target: "grisp2"},
      %{name: "nerves_system_x86_64", target: "x86_64"}
      # %{name: "nerves_system_bbb", target: "bbb"}
    ]
  end

  @spec build_all_systems(String.t(), list(), String.t(), integer(), integer(), String.t()) ::
          map()
  defp build_all_systems(project_dir, systems, output_dir, timeout, log_tail_bytes, package_name) do
    systems
    |> Enum.map(fn system ->
      result =
        build_system(project_dir, system, output_dir, timeout, log_tail_bytes, package_name)

      {system.name, result}
    end)
    |> Map.new()
  end

  @spec build_system(String.t(), map(), String.t(), integer(), integer(), String.t()) :: map()
  defp build_system(project_dir, system, output_dir, _timeout, log_tail_bytes, package_name) do
    log_file = Path.join([output_dir, "logs", "#{system.name}.log"])
    start_time = System.monotonic_time(:second)

    # Set up isolated build environment for this target
    build_path = Path.join([project_dir, "_build", system.target])
    deps_path = Path.join([project_dir, "deps"])

    env = [
      {"MIX_TARGET", system.target},
      {"MIX_BUILD_PATH", build_path},
      {"MIX_DEPS_PATH", deps_path},
      {"MIX_ENV", "prod"}
    ]

    # First run deps.get for this target
    case System.cmd("mix", ["deps.get"],
           cd: project_dir,
           env: env,
           stderr_to_stdout: true,
           into: File.stream!(log_file, [:append])
         ) do
      {_, 0} ->
        # deps.get succeeded, now run firmware
        firmware_result =
          run_firmware(
            project_dir,
            env,
            log_file,
            start_time,
            build_path,
            log_tail_bytes,
            package_name
          )

        # Extract system version from the full log
        system_name = if is_map(system), do: system.name, else: system
        system_version = extract_system_version(log_file, system_name)
        Map.put(firmware_result, :system_version, system_version)

      {_, exit_code} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          system_version: nil,
          beam_scan: nil,
          dependency_scans: nil,
          error: "mix deps.get exited with code #{exit_code}"
        }
    end
  end

  @spec run_firmware(String.t(), list(), String.t(), integer(), String.t(), integer(), String.t()) ::
          map()
  defp run_firmware(
         project_dir,
         env,
         log_file,
         start_time,
         build_path,
         log_tail_bytes,
         package_name
       ) do
    with :ok <- run_mix(["firmware"], project_dir, env, log_file),
         {:ok, hash1} <- hash_package_artifacts(build_path, package_name),
         :ok <- run_mix(["deps.clean", "--build", package_name], project_dir, env, log_file),
         :ok <- run_mix(["firmware"], project_dir, env, log_file),
         {:ok, hash2} <- hash_package_artifacts(build_path, package_name) do
      duration = System.monotonic_time(:second) - start_time
      firmware_info = Scanner.find_firmware(build_path)
      log_tail = read_log_tail(log_file, log_tail_bytes)
      beam_scan = analyze_beam_scan(build_path, package_name)
      dependency_scans = analyze_dependency_beam_scans(build_path, package_name)
      {deterministic, determinism_changes} = compare_hashes(hash1, hash2)

      %{
        status: :pass,
        duration_sec: duration * 1.0,
        firmware_size_bytes: firmware_info[:size],
        log_tail: log_tail,
        beam_scan: beam_scan,
        dependency_scans: dependency_scans,
        deterministic: deterministic,
        determinism_changes: determinism_changes,
        error: nil
      }
    else
      {:error, reason} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          beam_scan: nil,
          dependency_scans: nil,
          error: format_error(reason)
        }
    end
  end

  defp run_mix(args, project_dir, env, log_file) do
    case System.cmd("mix", args,
           cd: project_dir,
           env: env,
           stderr_to_stdout: true,
           into: File.stream!(log_file, [:append])
         ) do
      {_, 0} -> :ok
      {_, exit_code} -> {:error, "mix command exited with code #{exit_code}"}
    end
  end

  defp hash_package_artifacts(build_path, package_name) do
    with {:ok, lib_dir} <- find_package_lib_dir(build_path, package_name),
         {:ok, hashes} <- compute_hashes(lib_dir) do
      {:ok, hashes}
    else
      {:error, _} = error -> error
    end
  end

  defp find_package_lib_dir(build_path, package_name) do
    rel_roots =
      [Path.join([build_path, "rel"]), Path.join([build_path, "dev", "rel"])]
      |> Enum.filter(&File.dir?/1)

    case Enum.find_value(rel_roots, &find_package_lib_dir_in_rel(&1, package_name)) do
      nil -> {:error, :package_not_found}
      path -> {:ok, path}
    end
  end

  defp find_package_lib_dir_in_rel(rel_root, package_name) do
    apps = File.ls!(rel_root)

    apps
    |> Enum.find_value(fn app_dir ->
      lib_dir = Path.join([rel_root, app_dir, "lib"])

      if File.dir?(lib_dir) do
        case File.ls(lib_dir) do
          {:ok, entries} ->
            Enum.find_value(entries, fn entry ->
              if String.starts_with?(entry, package_name <> "-") do
                Path.join(lib_dir, entry)
              end
            end)

          _ ->
            nil
        end
      else
        nil
      end
    end)
  end

  defp compute_hashes(package_lib_dir) do
    dirs = [Path.join(package_lib_dir, "ebin"), Path.join(package_lib_dir, "priv")]

    files =
      dirs
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(fn dir ->
        dir
        |> Path.join("**/*")
        |> Path.wildcard(match_dot: true)
        |> Enum.filter(&File.regular?/1)
        |> Enum.map(fn path -> {path, Path.relative_to(path, package_lib_dir)} end)
      end)

    hashes =
      files
      |> Enum.map(fn {abs, rel} ->
        with {:ok, content} <- File.read(abs) do
          hash = :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
          {rel, hash}
        else
          _ -> {rel, :error}
        end
      end)
      |> Enum.reject(fn {_rel, hash} -> hash == :error end)
      |> Map.new()

    {:ok, hashes}
  end

  defp compare_hashes(hash1, hash2) do
    added = Map.keys(hash2) -- Map.keys(hash1)
    removed = Map.keys(hash1) -- Map.keys(hash2)

    changed =
      hash1
      |> Enum.flat_map(fn {path, val1} ->
        case Map.get(hash2, path) do
          nil -> []
          val2 when val1 == val2 -> []
          val2 -> [%{path: path, change: :changed, hash_before: val1, hash_after: val2}]
        end
      end)

    additions = Enum.map(added, &%{path: &1, change: :added, hash_after: hash2[&1]})
    removals = Enum.map(removed, &%{path: &1, change: :removed, hash_before: hash1[&1]})

    diffs = changed ++ additions ++ removals

    deterministic = diffs == []

    {deterministic, diffs}
  end

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)

  @spec compile_host(String.t(), String.t(), integer()) :: map()
  defp compile_host(project_dir, output_dir, log_tail_bytes) do
    log_file = Path.join([output_dir, "logs", "host.log"])
    start_time = System.monotonic_time(:second)

    build_path = Path.join([project_dir, "_build", "host"])
    deps_path = Path.join([project_dir, "deps"])

    env = [
      {"MIX_BUILD_PATH", build_path},
      {"MIX_DEPS_PATH", deps_path},
      {"MIX_ENV", "prod"}
    ]

    case run_mix(["deps.get"], project_dir, env, log_file) do
      :ok ->
        compile_result = run_compile(project_dir, env, log_file, start_time, log_tail_bytes)
        Map.put(compile_result, :system_version, nil)

      {:error, reason} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          system_version: nil,
          beam_scan: nil,
          dependency_scans: nil,
          error: reason
        }
    end
  end

  @spec run_compile(String.t(), list(), String.t(), integer(), integer()) :: map()
  defp run_compile(project_dir, env, log_file, start_time, log_tail_bytes) do
    case run_mix(["compile"], project_dir, env, log_file) do
      :ok ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :pass,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          beam_scan: nil,
          dependency_scans: nil,
          error: nil
        }

      {:error, reason} ->
        duration = System.monotonic_time(:second) - start_time
        log_tail = read_log_tail(log_file, log_tail_bytes)

        %{
          status: :fail,
          duration_sec: duration * 1.0,
          firmware_size_bytes: nil,
          log_tail: log_tail,
          beam_scan: nil,
          dependency_scans: nil,
          error: reason
        }
    end
  end

  @spec read_log_tail(String.t(), integer()) :: String.t()
  defp read_log_tail(log_file, max_bytes) do
    case File.read(log_file) do
      {:ok, content} ->
        if byte_size(content) <= max_bytes do
          content
        else
          # Take the last max_bytes
          offset = byte_size(content) - max_bytes
          binary_part(content, offset, max_bytes)
        end

      {:error, _} ->
        ""
    end
  end

  @spec get_package_version(String.t(), map()) :: String.t()
  defp get_package_version(project_dir, package) do
    # If exact version was specified, use it
    if package[:version] do
      package.version
    else
      # Read from mix.lock
      lock_file = Path.join(project_dir, "mix.lock")

      case File.read(lock_file) do
        {:ok, content} ->
          case Code.eval_string(content) do
            {lock, _} when is_map(lock) ->
              package_atom = String.to_atom(package.name)

              case lock[package_atom] do
                {:hex, _, version, _, _, _, _, _} -> version
                _ -> "unknown"
              end

            _ ->
              "unknown"
          end

        _ ->
          "unknown"
      end
    end
  end

  @spec extract_system_version(String.t(), String.t()) :: String.t() | nil
  defp extract_system_version(log_file, system_name) do
    case File.read(log_file) do
      {:ok, content} ->
        # Look for pattern like "  nerves_system_rpi4 1.32.0" in the dependency list
        regex = ~r/^  #{Regex.escape(system_name)} ([\d.]+)$/m

        case Regex.run(regex, content) do
          [_, version] -> version
          _ -> nil
        end

      {:error, _} ->
        nil
    end
  end

  defp gleam_build_tool?(build_tools) do
    build_tools
    |> Enum.map(&String.downcase(to_string(&1)))
    |> Enum.any?(&(&1 == "gleam"))
  end

  defp gleam_skip_reason(build_tools) do
    tools = build_tools |> Enum.map(&to_string/1) |> Enum.join(", ")

    if tools == "" do
      "Package uses gleam build tool"
    else
      "Package uses gleam build tool (#{tools})"
    end
  end

  defp build_skipped_beam_scan(build_tools) do
    %{
      "flags" => %{
        "start_callback" => false,
        "nif" => false,
        "shell" => false,
        "app_env" => false,
        "os_env" => false,
        "os_exec" => false,
        "halt" => false
      },
      "start_modules" => [],
      "protocols" => %{"defined" => [], "impls" => []},
      "evidence" => %{
        "nif" => [],
        "shell" => [],
        "app_env" => [],
        "os_env" => [],
        "os_exec" => [],
        "halt" => []
      },
      "languages" =>
        build_tools
        |> Enum.map(&to_string/1)
        |> Enum.map(&String.downcase/1)
        |> Enum.uniq(),
      "beam_count" => nil,
      "errors" => ["beam scan skipped: gleam build tool"]
    }
  end

  defp build_forced_skip_system(output_dir, reason, log_tail_bytes, beam_scan) do
    log_file = Path.join([output_dir, "logs", "#{@forced_skip_system}.log"])
    :ok = File.write!(log_file, reason <> "\n")
    log_tail = truncate_tail(reason, log_tail_bytes)

    %{
      @forced_skip_system => %{
        status: :skipped,
        duration_sec: 0.0,
        firmware_size_bytes: nil,
        log_tail: log_tail,
        system_version: nil,
        beam_scan: beam_scan,
        dependency_scans: nil,
        error: reason
      }
    }
  end

  defp truncate_tail(message, max_bytes) when is_binary(message) do
    if byte_size(message) <= max_bytes do
      message
    else
      offset = byte_size(message) - max_bytes
      binary_part(message, offset, max_bytes)
    end
  end

  defp truncate_tail(message, _max_bytes), do: to_string(message)

  defp format_retired_reason(retired) when is_map(retired) do
    reason_code = Map.get(retired, "reason") || Map.get(retired, :reason)
    message = Map.get(retired, "message") || Map.get(retired, :message) || ""
    msg = String.trim(message)

    base_reason = retired_reason_to_string(reason_code)
    base = "Package retired on hex.pm" <> if(base_reason, do: " (#{base_reason})", else: "")

    if msg != "" do
      base <> ": " <> msg
    else
      base
    end
  end

  defp format_retired_reason(_), do: "Package retired on hex.pm"

  defp retired_reason_to_string(reason) when is_binary(reason), do: reason
  defp retired_reason_to_string(reason) when is_atom(reason), do: Atom.to_string(reason)

  defp retired_reason_to_string(reason) when is_integer(reason) do
    case reason do
      0 -> "other"
      1 -> "invalid"
      2 -> "security"
      3 -> "deprecated"
      4 -> "renamed"
      _ -> Integer.to_string(reason)
    end
  end

  defp retired_reason_to_string(_), do: nil

  defp analyze_beam_scan(build_path, package_name) do
    case BeamScan.analyze(build_path, package_name) do
      {:ok, scan} -> scan
      {:error, reason} -> %{"errors" => ["beam scan failed: #{inspect(reason)}"]}
    end
  end

  defp analyze_dependency_beam_scans(build_path, package_name) do
    case BeamScan.analyze_dependencies(build_path, package_name) do
      {:ok, scans} -> scans
      {:error, reason} -> %{"__errors__" => ["dependency beam scan failed: #{inspect(reason)}"]}
    end
  end

  defp empty_footprint do
    %{
      file_manifest: %{ebin: [], priv: []}
    }
  end
end
