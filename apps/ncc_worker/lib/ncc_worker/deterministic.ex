defmodule NccWorker.Deterministic do
  @moduledoc """
  The deterministic sibling of a toolchain build (`NCC_INPUT.deterministic:
  true`, judge revision 29; design addendum to option (a)): the package's
  closure compiled again with `ERL_COMPILER_OPTIONS=deterministic`, judged
  under the same rules as the build, and published apart from it so that only
  a client whose own project sets exactly that option takes it.

  The sibling is its own traced compile, never a second window of the
  build's: Elixir reads `ERL_COMPILER_OPTIONS` once per VM, into a
  persistent_term, on the first module it compiles, so a later window of the
  same VM compiles Elixir modules without the option whatever the env says.
  It is `NccWorker.Portability.run/3` in judge mode over the package's whole
  closure, as a user's deterministic project compiles every dependency with
  the option, at a build path of its own (`_build/deterministic`, beside the
  build's `_build/host`, whose files are not touched), with the build's own
  env, `HEX_HOME`, lock snapshot and tree snapshot (`judged_with`: the ones
  the build's passing trace was judged on) and its own trace dir and log.
  So every input the build's verdict rests on is checked again for the
  sibling's own compile: the trace and its windows, the tree and built
  checks, R2, the rebar3 rules, its own second build for priv it writes
  (`PrivRepro`), and the static rules on its own `ebin` and `priv`
  (`NccWorker.Worker.toolchain_build/6` with `build_path:`).

  Only after a build that passed, and never when the build's own compile
  read or set `ERL_COMPILER_OPTIONS` (or read the whole environment, or set
  more variables than its observations hold): there the option is an input
  the package itself acts on. The sibling then passes only when it is the
  build but for what the option changes: the same lock, checksum, declared
  dependencies, manager, `compile_env`, `compile_inputs` and `built_priv`;
  the same `priv` files (the same bytes, but for the files `built_priv` lists,
  which its own second build reproduced); and an `ebin` that
  `Compatibility.DeterministicBeams.compare_ebin/2` takes. Anything else, a
  sibling that could not be judged included, is `skipped` with its reason and
  changes nothing about the build.

  Two outcomes are a worker failure instead (`{:error, _}`, exit 10): a
  sibling trace that left processes running that could not be killed, and a
  build whose files no longer hash to its manifest once the sibling is over.
  Either may have changed what the run is about to archive.
  """

  alias Compatibility.DeterministicBeams
  alias NccWorker.{HexHome, HostTrace, Portability, Tracer, Worker}

  @build_dir "deterministic"
  # `NccWorker.Portability`'s cap on `env_writes`: a list this long may have
  # dropped the one that matters.
  @env_writes_cap 50

  @not_passed "the build without the option did not pass"
  @reads_option "the build's compile reads or sets ERL_COMPILER_OPTIONS"

  @doc "Whether the run's input asks for a sibling: exactly `true`."
  @spec requested?(map()) :: boolean()
  def requested?(%{deterministic: true}), do: true
  def requested?(_input), do: false

  @doc "The sibling's build path under `project_dir`."
  @spec build_path(String.t()) :: String.t()
  def build_path(project_dir), do: Path.join([project_dir, "_build", @build_dir])

  @doc """
  The sibling of `normal`, the toolchain build `NccWorker.Worker.toolchain_build/6`
  returned, as `{:ok, sibling}` or `{:error, reason}` (see the moduledoc).
  `judged_with` holds the `releases:` and `trees:` the build's passing
  trace was judged on. `opts`: `run_started_at:`, `makefile_rule2:`,
  `hex_home:` (the run's verified Hex cache, default `HEX_HOME`), and
  `trace:` (tests; `NccWorker.Portability.run/3`'s shape).
  """
  @spec build(String.t(), String.t(), map(), map(), map(), keyword(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def build(project_dir, package_name, paths, toolchain, normal, judged_with, opts) do
    case eligible(normal) do
      :ok -> sibling(project_dir, package_name, paths, toolchain, normal, judged_with, opts)
      {:skip, reason} -> {:ok, skipped(toolchain, reason, opts)}
    end
  end

  @doc false
  # Public for tests.
  @spec eligible(map()) :: :ok | {:skip, String.t()}
  def eligible(%{status: "pass", compile_inputs: inputs} = normal) when is_list(inputs) do
    writes = get_in(normal, [:compile_observations, "env_writes"]) || []

    cond do
      Enum.any?(inputs, &option_input?/1) ->
        {:skip, @reads_option}

      not is_list(writes) or length(writes) >= @env_writes_cap ->
        {:skip, @reads_option}

      Enum.any?(writes, &(is_map(&1) and &1["name"] == DeterministicBeams.env_name())) ->
        {:skip, @reads_option}

      true ->
        :ok
    end
  end

  def eligible(_normal), do: {:skip, @not_passed}

  defp option_input?(%{"kind" => "env_all"}), do: true

  defp option_input?(%{"kind" => "env", "name" => name}),
    do: name == DeterministicBeams.env_name()

  defp option_input?(_input), do: false

  defp skipped(toolchain, reason, opts) do
    %{
      status: "skipped",
      reason: reason,
      erl_compiler_options: DeterministicBeams.options(),
      elixir: toolchain.elixir,
      otp: toolchain.erlang,
      judge_revision: Portability.judge_revision(opts),
      file_manifest: nil,
      foreign_priv: nil,
      foreign_priv_rule: nil
    }
  end

  # The sibling's own build dir under the run's project, emptied first.
  # sobelow_skip ["Traversal.FileModule"]
  defp sibling(project_dir, package_name, paths, toolchain, normal, judged_with, opts) do
    build_path = build_path(project_dir)

    log(
      paths,
      "Deterministic sibling: compiling the closure with ERL_COMPILER_OPTIONS=deterministic"
    )

    case File.rm_rf(build_path) do
      {:ok, _} ->
        started = System.monotonic_time(:second)
        verdict = trace(project_dir, package_name, paths, build_path, judged_with, opts)
        host = %{status: :pass, duration_sec: (System.monotonic_time(:second) - started) * 1.0}
        ctx = %{project_dir: project_dir, package_name: package_name, build_path: build_path}
        judge(ctx, verdict, host, paths, toolchain, normal, opts)

      {:error, reason, _path} ->
        {:error, {:deterministic_build_dir, reason}}
    end
  end

  defp judge(ctx, verdict, host, paths, toolchain, normal, opts) do
    with :ok <- writers_stopped(verdict),
         :ok <- unchanged(ctx.project_dir, ctx.package_name, normal) do
      build_opts = [
        makefile_rule2: Keyword.get(opts, :makefile_rule2) == true,
        foreign_priv: Keyword.get(opts, :foreign_priv) == true,
        native_side: Keyword.get(opts, :native_side) == true,
        build_path: ctx.build_path,
        hex_home: hex_home(opts)
      ]

      ctx.project_dir
      |> Worker.toolchain_build(ctx.package_name, host, toolchain, verdict, build_opts)
      |> settle(normal, ctx.project_dir, ctx.package_name, ctx.build_path)
      |> Map.put(:erl_compiler_options, DeterministicBeams.options())
      |> tap(&log(paths, "Deterministic sibling: #{&1.status} #{&1.reason}"))
      |> then(&{:ok, &1})
    end
  end

  defp trace(project_dir, package_name, paths, build_path, judged_with, opts) do
    run = Keyword.get(opts, :trace, &Portability.run/3)
    hex_home = HexHome.prepare(project_dir, "host")
    {name, value} = DeterministicBeams.env()

    env =
      project_dir
      |> HostTrace.env()
      |> List.keystore("MIX_BUILD_PATH", 0, {"MIX_BUILD_PATH", build_path})
      |> Kernel.++(if hex_home, do: [{"HEX_HOME", hex_home}], else: [])
      |> Kernel.++([{name, value}])

    verdict =
      run.(project_dir, package_name,
        env: env,
        mode: :judge,
        releases: Keyword.get(judged_with, :releases),
        trees: Keyword.get(judged_with, :trees),
        makefile_rule2: Keyword.get(opts, :makefile_rule2) == true,
        foreign_priv: Keyword.get(opts, :foreign_priv) == true,
        native_side: Keyword.get(opts, :native_side) == true,
        hex_home: hex_home(opts),
        run_started_at: Keyword.get(opts, :run_started_at),
        trace_dir: Path.join(paths.work_dir, "trace-" <> @build_dir),
        log_file: Path.join(paths.logs_dir, "deterministic-trace.log")
      )

    HexHome.publish(hex_home)
    verdict
  end

  defp hex_home(opts), do: Keyword.get_lazy(opts, :hex_home, fn -> System.get_env("HEX_HOME") end)

  # As `NccWorker.HostTrace` treats its own trace: a process that could not
  # be killed may still write a build dir, the build's among them.
  defp writers_stopped(verdict) do
    if get_in(verdict, [:observations, "trace_stats", "tracer_error"]) in Tracer.left_running(),
      do: {:error, :deterministic_left_running},
      else: :ok
  end

  # The build's files, which the run archives by path after this, still
  # hash to the manifest that names them.
  defp unchanged(project_dir, package_name, normal) do
    app_dir = Path.join([project_dir, "_build", "host", "lib", package_name])

    case Enum.find(entries(normal.file_manifest), &(sha256(app_dir, &1) != &1["sha256"])) do
      nil -> :ok
      entry -> {:error, {:deterministic_changed_build, entry["path"]}}
    end
  end

  defp settle(%{status: "pass"} = sibling, normal, project_dir, package_name, build_path) do
    normal_dir = Path.join([project_dir, "_build", "host", "lib", package_name])
    sibling_dir = Path.join([build_path, "lib", package_name])

    case same_build(normal, sibling, normal_dir, sibling_dir) do
      :ok ->
        sibling

      # Foreign priv spec 3.6: no foreign files on any status but pass.
      {:error, why} ->
        Map.merge(sibling, %{
          status: "skipped",
          reason: "differs from the build: " <> why,
          foreign_priv: nil,
          foreign_priv_rule: nil
        })
    end
  end

  defp settle(sibling, _normal, _project_dir, _package_name, _build_path), do: sibling

  @same ~w(deps_lock package_checksum declared manager compile_env compile_env_rule
           compile_inputs built_priv foreign_priv_rule)a

  @doc false
  # Public for tests.
  @spec same_build(map(), map(), String.t(), String.t()) :: :ok | {:error, String.t()}
  def same_build(normal, sibling, normal_dir, sibling_dir) do
    with :ok <- same_fields(normal, sibling),
         :ok <- same_priv(normal, sibling),
         :ok <- same_foreign(normal, sibling, normal_dir, sibling_dir) do
      DeterministicBeams.compare_ebin(
        ebin(normal.file_manifest, normal_dir),
        ebin(sibling.file_manifest, sibling_dir)
      )
    end
  end

  # Foreign priv archives (spec 3.8): the same paths, and each pair the same
  # members, read from kino's dir beside each build's own (`<lib>/kino`);
  # the two compiles stamp different tar times, so the bytes may differ.
  defp same_foreign(normal, sibling, normal_dir, sibling_dir) do
    paths = fn build ->
      build |> Map.get(:foreign_priv) |> List.wrap() |> Enum.map(& &1["path"]) |> Enum.sort()
    end

    cond do
      paths.(normal) != paths.(sibling) ->
        {:error, "its foreign_priv differs"}

      Enum.all?(paths.(normal), &same_members?(&1, normal_dir, sibling_dir)) ->
        :ok

      true ->
        {:error, "its foreign_priv archives differ"}
    end
  end

  defp same_members?(rel, normal_dir, sibling_dir) do
    a = archive_members(rel, normal_dir)
    a != :unreadable and a == archive_members(rel, sibling_dir)
  end

  # `rel` checked to be an archive path before it is joined: a path below
  # kino's build dir beside `app_dir`, one of the run's own build dirs.
  # sobelow_skip ["Traversal.FileModule"]
  defp archive_members(rel, app_dir) do
    with {:ok, _dir, _hash} <- Compatibility.ForeignPriv.parse_path(rel),
         {:ok, bytes} <- File.read(Path.join([Path.dirname(app_dir), "kino", rel])),
         {:ok, members} <- Compatibility.KinoAssets.members(bytes) do
      members
    else
      _ -> :unreadable
    end
  end

  defp same_fields(normal, sibling) do
    case Enum.find(@same, &(Map.get(normal, &1) != Map.get(sibling, &1))) do
      nil -> :ok
      field -> {:error, "its #{field} differs"}
    end
  end

  # The same paths and modes; the same bytes but for a file the package's
  # own compile wrote, which each build's own second build reproduced.
  defp same_priv(normal, sibling) do
    built = MapSet.new(normal.built_priv || [])
    key = fn e -> {e["path"], e["mode"], MapSet.member?(built, e["path"]) || e["sha256"]} end

    if priv(normal.file_manifest) |> Enum.map(key) |> Enum.sort() ==
         priv(sibling.file_manifest) |> Enum.map(key) |> Enum.sort(),
       do: :ok,
       else: {:error, "its priv differs"}
  end

  defp priv(%{"priv" => entries}) when is_list(entries), do: entries
  defp priv(_manifest), do: []

  defp entries(%{} = manifest), do: (manifest["ebin"] || []) ++ (manifest["priv"] || [])
  defp entries(_manifest), do: []

  # The manifest's ebin files, by their names, as the bytes on disk; one
  # that no longer hashes to its entry reads as missing. `app_dir` is one of
  # the run's own build dirs.
  # sobelow_skip ["Traversal.FileModule"]
  defp ebin(%{"ebin" => entries}, app_dir) when is_list(entries) do
    for %{"path" => "ebin/" <> name = path, "sha256" => sum} <- entries,
        {:ok, bytes} <- [File.read(Path.join(app_dir, path))],
        hex(bytes) == sum,
        into: %{},
        do: {name, bytes}
  end

  defp ebin(_manifest, _app_dir), do: %{}

  # sobelow_skip ["Traversal.FileModule"]
  defp sha256(app_dir, %{"path" => path}) when is_binary(path) do
    case File.read(Path.join(app_dir, path)) do
      {:ok, bytes} -> hex(bytes)
      {:error, _} -> nil
    end
  end

  defp sha256(_app_dir, _entry), do: nil

  defp hex(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # sobelow_skip ["Traversal.FileModule"]
  defp log(paths, line) do
    IO.puts(:stderr, line)
    _ = File.write(Path.join(paths.logs_dir, "host.log"), line <> "\n", [:append])
    :ok
  end
end
