defmodule NccWorker.FirmwareInputs do
  @moduledoc """
  A firmware target's compile-time inputs (judge revision 19): what a
  passing target's compile read that a client must check, recorded as the
  target's `compile_inputs` and `compile_env`, so a client compares them
  instead of refusing every build whose package reads the environment at
  compile time (its rule 8: circuits_i2c's `CIRCUITS_I2C_I2CDEV`, which the
  package's own `mix.exs` sets from the Nerves target and its
  `:default_backend` config right before it compiles).

  `mix firmware` is not traced. For each passing target whose package's own
  `lib/` reads an env variable at module level (`env_reads?/1`, the shape
  the client's rule 8 scans for), once every other pass is over and one
  target at a time:

    1. Nerves's build env for the target (`mix ncc.nerves_env` in the
       target's own deps and build dirs): the variables `mix firmware` set
       up before it compiled anything, its `NERVES_TOOLCHAIN` and
       `NERVES_SYSTEM` among them;
    2. the traced judge compile of the package's closure for the target
       under that env, into a build dir of its own
       (`NccWorker.Portability.target_inputs/3`), which records every read
       a client must check and passes only when nothing else was read;
    3. the binding: the beams that compile wrote for the package carry the
       code (`:beam_lib.md5/1`) and the attributes chunk of the published
       ones, module for module,
       and its `.app` is the published one byte for byte, so what the trace
       recorded is what the published files were compiled from.

  The trace runs with the toolchain and system dirs at other paths than the
  firmware build had them, their artifact names (and so their versions)
  included (`move/4`: a link per dir, every Nerves variable rewritten to
  them), so the binding also proves the package's code does not depend on
  those paths: a client then compares a variable that names them
  (`CROSSCOMPILE`) with those paths cut out (`set_by: "nerves"`), and may
  do so on another release of its system. The paths
  must be artifact dirs of the one artifacts dir (`NERVES_ARTIFACTS_DIR`),
  which `NccWorker.FirmwareBuildRoot` keeps out of the published files.

  `NCC_FIRMWARE_INPUTS=0` turns it off (the rollback): no target gets
  inputs, as before.

  Only a target that publishes its own first build is judged: one that kept
  its optional dependencies, or publishes variants, was compiled against
  another closure than the run's, which the trace compiles. Anything that
  does not hold leaves the target as it was, without `compile_inputs`, and
  a client refuses its build as before. Statuses, firmware images and files
  never change.
  """

  alias Compatibility.CompileInputs
  alias NccWorker.{BeamScan, HexHome, Portability, TargetScan, Tracer}

  @env_task :"Elixir.Mix.Tasks.Ncc.NervesEnv"
  @env_timeout_sec 300
  @trace_timeout_ms 20 * 60 * 1000
  # Set by the trace itself or the worker: never taken from Nerves's env.
  @own_env ~r/\A(MIX_|HEX_|NCC_)/
  @env_read ~r/System\s*\.\s*(get_env|fetch_env!?)\s*\(|:os\s*\.\s*getenv\s*\(/
  # `nerves_toolchain_aarch64_nerves_linux_gnu-15.3.1`, `nerves_system_rpi4-2.2.2`.
  @artifact_name ~r/\A[a-z][a-z0-9_]*-[0-9][0-9A-Za-z.+_-]*\z/

  @typedoc """
  What `put/3` needs: `targets` maps a system's name to `{target, env}`
  (the target's build env); `releases`, `trees` and `started_at` are the
  run's lock snapshot, tree snapshot and start (monotonic seconds);
  `work_dir` and `log_dir` where it writes.
  """
  @type ctx :: %{
          project_dir: String.t(),
          package: String.t(),
          targets: %{String.t() => {String.t(), [{String.t(), String.t()}]}},
          releases: term(),
          trees: term(),
          started_at: integer() | nil,
          work_dir: String.t(),
          log_dir: String.t()
        }

  @doc """
  Puts `compile_inputs` and `compile_env` on every target of `systems` they
  could be recorded for. Returns the systems and one line per target tried,
  for the run's log. `record` (default `record/4`) is for tests.
  """
  @spec put(%{String.t() => map()}, ctx(), keyword()) :: {%{String.t() => map()}, [String.t()]}
  def put(systems, ctx, opts \\ []) do
    record = Keyword.get(opts, :record, &record/4)

    eligible =
      for {name, result} <- Enum.sort(systems),
          eligible?(result),
          {:ok, target_env} <- [Map.fetch(ctx.targets, name)],
          do: {name, target_env}

    if eligible == [] or System.get_env("NCC_FIRMWARE_INPUTS") == "0" or
         not env_reads?(Path.join([ctx.project_dir, "deps", ctx.package])) do
      {systems, []}
    else
      Enum.reduce(eligible, {systems, []}, fn {name, target_env}, {acc, lines} ->
        {acc, line} = put_one(acc, name, try_one(record, name, target_env, ctx, acc[name]))
        {acc, lines ++ [line]}
      end)
    end
  end

  defp try_one(record, name, target_env, ctx, result) do
    if budget_left?(ctx.started_at),
      do: record.(name, target_env, ctx, result),
      else: {:error, "run budget exhausted"}
  end

  # What the tracer would still run (`NccWorker.Tracer.timeout_sec/2`, its
  # ceiling below the 2 h at which `Portal.Builder` kills the container and
  # the run is lost): a target whose trace could not start does not start
  # its Nerves env either.
  defp budget_left?(nil), do: true

  defp budget_left?(started_at) do
    elapsed = max(System.monotonic_time(:second) - started_at, 0)
    Tracer.timeout_sec(@trace_timeout_ms, elapsed) != :exhausted
  end

  defp put_one(systems, name, {:ok, %{compile_inputs: inputs, compile_env: env}})
       when is_list(inputs) do
    result = Map.merge(systems[name], %{compile_inputs: inputs, compile_env: env})
    {Map.put(systems, name, result), "Compile inputs of #{name} recorded"}
  end

  defp put_one(systems, name, {:error, why}),
    do: {systems, "Compile inputs of #{name} not recorded: #{why}"}

  defp put_one(systems, name, _other),
    do: {systems, "Compile inputs of #{name} not recorded: no inputs"}

  # A passing target that publishes its own first build and nothing else.
  defp eligible?(result) do
    result[:status] in [:pass, "pass"] and published?(result[:beam_scan]) and
      result[:deps_lock] == nil and List.wrap(result[:published_variants]) == []
  end

  defp published?(%{"footprint" => %{"file_manifest" => %{}}}), do: true
  defp published?(_scan), do: false

  @doc """
  Whether the package at `dep_dir` reads an env variable at module level in
  `lib/`: a `System.get_env/fetch_env/fetch_env!` or `:os.getenv` call in
  what `NccWorker.TargetScan` keeps of a source file (function bodies
  dropped). Erring towards yes only costs a trace.
  """
  @spec env_reads?(String.t()) :: boolean()
  # The run's own deps dir.
  # sobelow_skip ["Traversal.FileModule"]
  def env_reads?(dep_dir) do
    dep_dir
    |> Path.join("lib/**/*.ex")
    |> Path.wildcard()
    |> Enum.any?(fn path ->
      case File.read(path) do
        {:ok, contents} ->
          scanned = TargetScan.scanned(path, contents)
          is_binary(scanned) and Regex.match?(@env_read, scanned)

        {:error, _} ->
          true
      end
    end)
  end

  @doc """
  Records one target's inputs: `{:ok, %{compile_inputs, compile_env}}`, or
  `{:error, why}` when any step does not hold. `result` is the target's
  system result. Never raises.
  """
  @spec record(String.t(), {String.t(), list()}, ctx(), map()) ::
          {:ok, %{compile_inputs: [map()], compile_env: [map()]}} | {:error, String.t()}
  # The run's own work dir.
  # sobelow_skip ["Traversal.FileModule"]
  def record(name, {target, env}, ctx, _result) do
    dir = Path.join(ctx.work_dir, "fw-inputs-#{target}")
    build_path = env_value(env, "MIX_BUILD_PATH")
    _ = File.rm_rf(dir)
    File.mkdir_p!(dir)

    try do
      with {:ok, nerves} <- nerves_env(ctx.project_dir, env, dir),
           {:ok, artifacts, roots} <- roots(nerves),
           {:ok, moved, roots} <- move(nerves, artifacts, roots, dir),
           {:ok, verdict} <- trace(name, target, moved, roots, ctx, dir),
           :ok <- bound(dir, build_path, ctx.package) do
        {:ok, %{compile_inputs: verdict.compile_inputs, compile_env: verdict.compile_env}}
      end
    rescue
      e -> {:error, "firmware inputs: " <> Exception.message(e)}
    after
      _ = File.rm_rf(dir)
    end
  end

  # Step 1, in the target's own deps and build dirs, which hold Nerves.
  # `elixir` and `timeout` from the PATH, a literal argument list, no shell.
  # sobelow_skip ["Traversal.FileModule", "CI.System"]
  defp nerves_env(project_dir, env, dir) do
    ebin = Path.join(dir, "ebin")
    out = Path.join(dir, "nerves_env")
    File.mkdir_p!(ebin)
    {:ok, {@env_task, code}} = object_code(@env_task)
    File.write!(Path.join(ebin, "#{@env_task}.beam"), code)

    with {:ok, timeout} <- executable("timeout"),
         {:ok, elixir} <- executable("elixir"),
         {_output, 0} <-
           System.cmd(
             timeout,
             ["--kill-after=10", "#{@env_timeout_sec}", elixir, "-pa", ebin, "-S", "mix"] ++
               ["ncc.nerves_env", out],
             cd: project_dir,
             env: env,
             stderr_to_stdout: true
           ),
         {:ok, bin} <- File.read(out) do
      pairs(bin)
    else
      {_output, status} when is_integer(status) -> {:error, "Nerves env exited #{status}"}
      {:error, why} -> {:error, "Nerves env: #{inspect(why)}"}
    end
  end

  @doc false
  # `mix ncc.nerves_env`'s file: `name NUL value NUL` per variable.
  @spec pairs(binary()) :: {:ok, [{String.t(), String.t()}]} | {:error, String.t()}
  def pairs(bin) do
    case String.split(bin, <<0>>) do
      [""] -> {:ok, []}
      fields -> pair_up(fields, [])
    end
  end

  defp pair_up([""], acc), do: {:ok, Enum.reverse(acc)}

  defp pair_up([name, value | rest], acc) when name != "" do
    if String.valid?(name) and String.valid?(value),
      do: pair_up(rest, [{name, value} | acc]),
      else: {:error, "Nerves env unreadable"}
  end

  defp pair_up(_fields, _acc), do: {:error, "Nerves env unreadable"}

  defp object_code(module) do
    case :code.get_object_code(module) do
      {^module, code, _file} -> {:ok, {module, code}}
      :error -> :error
    end
  end

  defp executable(name) do
    case System.find_executable(name) do
      nil -> {:error, "no #{name} on the PATH"}
      path -> {:ok, path}
    end
  end

  @doc false
  # The toolchain and system paths Nerves set, each an artifact dir of one
  # artifacts dir (`NERVES_ARTIFACTS_DIR` when the worker set one): the
  # dirs `NccWorker.FirmwareBuildRoot` keeps out of the published files.
  @spec roots([{String.t(), String.t()}], String.t() | nil) ::
          {:ok, String.t(), [{String.t(), String.t()}]} | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def roots(nerves, artifacts_dir \\ System.get_env("NERVES_ARTIFACTS_DIR")) do
    roots = for {name, path} <- nerves, name in CompileInputs.nerves_roots(), do: {name, path}
    parents = roots |> Enum.map(fn {_name, path} -> Path.dirname(path) end) |> Enum.uniq()

    cond do
      roots == [] ->
        {:error, "Nerves set no toolchain or system path"}

      length(parents) != 1 or (artifacts_dir not in [nil, ""] and parents != [artifacts_dir]) ->
        {:error, "the Nerves paths are not in one artifacts dir"}

      not Enum.all?(roots, fn {_name, path} -> artifact_dir?(path) end) ->
        {:error, "a Nerves path is not an artifact dir"}

      true ->
        {:ok, hd(parents), roots}
    end
  end

  defp artifact_dir?(path) do
    Path.type(path) == :absolute and Regex.match?(@artifact_name, Path.basename(path)) and
      File.dir?(path)
  end

  @doc false
  # The proof that the package's compile does not depend on the roots'
  # paths, the artifact names in them included: a client cuts the whole
  # path away, and takes a build made on another release of its system,
  # whose toolchain and system dirs carry other versions in their names.
  # So the traced compile runs with each root at a link of its own whose
  # path shares nothing with the root's (`<dir>/nerves-moved/<n>`), and
  # `bound/3` then requires its beams to be the published ones, compiled
  # with the roots where and as they were. Every Nerves variable is
  # rewritten root by root, cut as a client cuts it
  # (`Compatibility.CompileInputs.split/2`); none may still name the
  # artifacts dir.
  @spec move([{String.t(), String.t()}], String.t(), [{String.t(), String.t()}], String.t()) ::
          {:ok, [{String.t(), String.t()}], [{String.t(), String.t()}]} | {:error, String.t()}
  # sobelow_skip ["Traversal.FileModule"]
  def move(nerves, artifacts, roots, dir) do
    base = Path.join(dir, "nerves-moved")
    File.mkdir_p!(base)

    moved_roots =
      roots
      |> Enum.with_index()
      |> Enum.map(fn {{name, path}, index} ->
        link = Path.join(base, Integer.to_string(index))
        :ok = File.ln_s(path, link)
        {name, link}
      end)

    links = Map.new(moved_roots)

    rewrite = fn value ->
      value
      |> CompileInputs.split(roots)
      |> Enum.map_join(fn
        %{"root" => name} -> Map.fetch!(links, name)
        literal -> literal
      end)
    end

    nerves = Enum.map(nerves, fn {name, value} -> {name, rewrite.(value)} end)

    if Enum.any?(nerves, fn {_name, value} -> String.contains?(value, artifacts) end),
      do: {:error, "a Nerves variable names the artifacts dir outside its toolchain and system"},
      else: {:ok, nerves, moved_roots}
  end

  # Step 2: the closure from the run's own `deps/`, which the run's lock
  # and tree snapshots describe, compiled for the target into a build dir of
  # its own.
  defp trace(name, target, nerves, roots, ctx, dir) do
    hex_home = HexHome.prepare(ctx.project_dir, "host")

    env =
      [
        {"MIX_TARGET", target},
        {"MIX_ENV", "prod"},
        {"MIX_BUILD_PATH", Path.join(dir, "_build")}
      ] ++ if(hex_home, do: [{"HEX_HOME", hex_home}], else: [])

    verdict =
      Portability.target_inputs(ctx.project_dir, ctx.package,
        env: env,
        extra_env: Enum.reject(nerves, fn {var, _} -> Regex.match?(@own_env, var) end),
        releases: ctx.releases,
        trees: ctx.trees,
        hex_home: System.get_env("HEX_HOME"),
        run_started_at: ctx.started_at,
        timeout_ms: @trace_timeout_ms,
        trace_dir: Path.join(dir, "trace"),
        log_file: Path.join(ctx.log_dir, "#{name}-inputs-trace.log"),
        target: target,
        roots: roots
      )

    HexHome.publish(hex_home)

    case verdict do
      %{status: :pass, compile_inputs: inputs, compile_env: env} when is_list(inputs) ->
        {:ok, %{compile_inputs: inputs, compile_env: env || []}}

      %{reason: reason} ->
        {:error, reason || "not judged"}
    end
  end

  # Step 3: the traced compile's beams for the package against the
  # published build's, by the code and the attributes each holds.
  defp bound(dir, build_path, package) when is_binary(build_path) do
    traced = Path.join([dir, "_build", "lib", package, "ebin"])

    published =
      case BeamScan.package_dir(build_path, package) do
        {:ok, app_dir} -> Path.join(app_dir, "ebin")
        _ -> nil
      end

    if (published && fingerprints(traced) != %{}) and
         fingerprints(traced) == fingerprints(published) and
         app_file(traced, package) == app_file(published, package),
       do: :ok,
       else: {:error, "the traced compile's beams differ from the published ones"}
  end

  defp bound(_dir, _build_path, _package), do: {:error, "no build path"}

  @doc false
  # Every beam in `ebin` by module, with the md5 of its code and its
  # attributes chunk as it is (`module_info(:attributes)`: persisted
  # attributes, which the md5 leaves out); `%{}` when any cannot be read.
  # The other chunks the md5 leaves out hold the source path (`CInf`,
  # `Dbgi`, `Docs`), which is `deps/` here and `deps_<target>/` there.
  @spec fingerprints(String.t()) :: %{atom() => {binary(), binary() | :missing_chunk}}
  def fingerprints(ebin) do
    ebin
    |> Path.join("*.beam")
    |> Path.wildcard()
    |> Enum.reduce_while(%{}, fn path, acc ->
      file = String.to_charlist(path)

      with {:ok, {module, md5}} <- :beam_lib.md5(file),
           {:ok, {^module, [{~c"Attr", attrs}]}} <-
             :beam_lib.chunks(file, [~c"Attr"], [:allow_missing_chunks]) do
        {:cont, Map.put(acc, module, {md5, attrs})}
      else
        _ -> {:halt, %{}}
      end
    end)
  end

  # The `.app` Mix wrote (its env defaults are compile-time values too).
  # sobelow_skip ["Traversal.FileModule"]
  defp app_file(ebin, package) do
    case File.read(Path.join(ebin, package <> ".app")) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> :missing
    end
  end

  defp env_value(env, name) do
    case List.keyfind(env, name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end
end
