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
       as its firmware build compiled it (below), from the run's own
       `deps/` (`NccWorker.Portability.target_inputs/3`), which records
       every read a client must check and passes only when nothing else
       was read;
    3. the binding: the beams that compile wrote for the package carry the
       code (`:beam_lib.md5/1`) and the attributes chunk of the published
       ones, module for module,
       and its `.app` is the published one byte for byte, so what the trace
       recorded is what the published files were compiled from.

  The binding cannot tell a compile that read otherwise and wrote the same
  beams: a package that can tell the trace from the firmware build could
  read an env variable only in the build, bake the same value in the trace
  without reading it, and leave that read out of what the trace records.
  So the trace runs as the build ran, wherever a package can look without
  the trace seeing it:

    * at the build's paths (`in_build_layout/4`): the project dir (also
      the cwd), the target's build dir (`MIX_BUILD_PATH`, `_build/<target>`,
      the published build moved aside for the trace's) and deps dir
      (`MIX_DEPS_PATH`, `deps_<target>`, holding the run's `deps/` for the
      trace, the target's own moved aside): `__DIR__`,
      `Mix.Project.build_path/0`, `deps_path/0`, `app_path/0` and the
      source paths in the beams are the build's;
    * in the target's build env as it is (`MIX_TARGET`, `MIX_ENV`,
      `MIX_BUILD_PATH`, `MIX_DEPS_PATH`, its own `HEX_HOME`), under the
      build's own command (`firmware_command/0`: `fakeroot`, with its
      `FAKEROOTKEY` and `LD_PRELOAD`, and `System.argv/0` `["firmware"]`),
      `MIX_OS_DEPS_COMPILE_PARTITION_COUNT` unset in both (the worker never
      sets it, nerves_bootstrap clears it, the tracer will not start with
      it);
    * with Nerves's variables put in the env only once every dependency's
      `mix.exs` has been evaluated (`NccWorker.Tracer`'s `late_env:`), as
      `mix firmware`'s `nerves_bootstrap.init` loads the deps and then
      exports them, and the deps then loaded again, as the compile's own
      `deps.loadpaths` loads them: a `mix.exs`'s module body sees them
      unset, its `project/0` set at that second load and when its project
      is pushed to compile, and a rebar3 dependency is compiled with its
      `rebar.config.script` evaluated with them set;
    * no node name in either, and each dependency compiled by Mix's own
      `Mix.Tasks.Deps.Compile.compile_single/3`.

  What still differs, and why it records no other inputs than the build
  read:

    * the Nerves roots, at links of their own, and the variables that name
      them: what the binding proves (above);
    * the tracer's variables (`NCC_TRACE_*`), the `-pa`/`-s` it adds to
      `ERL_AFLAGS` for child VMs, and `fakeroot`'s session key: reading a
      `NCC_*` name records an unrecordable value, any other of them a value
      naming the trace dir or the session, and the whole environment
      `env_all`, so a client never matches a package that looked;
    * the tracer itself, where a package's look is judged and refuses:
      probing a module it loaded or listing the loaded modules (`Probes`),
      reading the code path, another process's dictionary, backtrace or
      mailbox, or touching tracing or the system flags;
    * not traced, and so not closed here: `:persistent_term` (the tracer's
      collector, where `mix firmware` holds Nerves's build plan), the
      process list, the clock and file times (the trace runs later), the
      resolver (`:inet_db`'s `lookup`, Erlang's own in the trace, so its
      window sweeps can clear what a download left, `ncc_tracer`), and
      the stacks: the tracer's backtrace depth of 64 frames (8 in the
      build), and a stack the compile takes of itself (`__STACKTRACE__`)
      or of the Mix process (`Process.info/2`'s `current_stacktrace`), in
      which the trace's driver stands in for `mix firmware`'s tasks. A
      package has to look for these on purpose; closing them needs
      patterns the tracer does not have.

  The trace runs with the toolchain and system dirs at other paths than the
  firmware build had them, their artifact names (and so their versions)
  included (`move/4`: a link per dir, every Nerves variable rewritten to
  them), so the binding also proves the package's code does not depend on
  those paths: a client then compares a variable that names them
  (`CROSSCOMPILE`) with those paths cut out (`set_by: "nerves"`), and may
  do so on another release of its system. The paths
  must be artifact dirs of the one artifacts dir (`NERVES_ARTIFACTS_DIR`),
  which `NccWorker.FirmwareBuildRoot` keeps out of the published files.

  `NCC_INPUT.firmware_inputs: false` turns it off (the rollback, which the
  portal sends while its own `NCC_FIRMWARE_INPUTS=0`; an older portal sends
  nothing, which is on), and so does `NCC_FIRMWARE_INPUTS=0` in the
  worker's own env: no target gets inputs, as before (`enabled?/1`).

  Only a target that publishes its own first build is judged: one that kept
  its optional dependencies, or publishes variants, was compiled against
  another closure than the run's, which the trace compiles. Anything that
  does not hold leaves the target as it was, without `compile_inputs`, and
  a client refuses its build as before. Statuses and firmware images never
  change.

  ## The firmware judge (stream S8)

  With `ctx.judge` (`judge_enabled?/1`: only when `NCC_INPUT.firmware_judge`
  is `true`, a portal node's NCC_FIRMWARE_JUDGE=1) every such target is
  traced, whatever its package reads, and its verdict is kept as the
  target's `firmware_judge`: `%{status, reason, classes}`. The classes come
  from every refusal text of the verdict, not only its first reason
  (`NccWorker.FirmwareJudge.texts/1`).

    * `"pass"`: the trace passed and its beams bind; the files publish.
    * `"skipped"`: the verdict refused for a probe, a rebar3 plugin or hook,
      or a dependency's taint by one (`NccWorker.FirmwareJudge.classes/1`,
      listed in `classes`), whether or not the beams bind: the target's own
      `footprint.file_manifest` is removed, so nothing of it is archived or
      published, as `NccWorker.FirmwareBuildRoot` withholds a baked build
      path.
    * `"unjudged"`: any other refusal, no verdict (the trace did not run or
      finish, the beams do not bind, the run's or the judge's budget is
      spent), or a target built against another closure; the files
      publish, as every firmware target's did before.

  A `"pass"` also keeps the trace's `compile_inputs` and `compile_env`, as
  for an env-reading package, whatever its package reads (stream S11): a
  compile-time read the `.app` does not list, an OS type a module attribute
  bakes or Logger's purge config, otherwise reaches the published beams with
  no client check. `compile_env` is the `.app`'s own items, then the trace's
  config reads it does not list (`merged_env/2`). The inputs pass's rollback
  (`enabled?/1`) keeps them out. A target the judge alone traces starts
  only within its own budget (`judge_budget/1`: `NCC_INPUT.firmware_judge_budget_sec`,
  default 1800 s, counted from the start of this pass).

  The portal holds a target the judge refused, every later build of it that
  is no judge pass (`Portal.Precompiled.Holds`): an unjudged target is
  published here as before, and held there.
  """

  alias Compatibility.CompileInputs
  alias NccWorker.{BeamScan, FirmwareJudge, HexHome, Portability, TargetScan, Tracer}
  alias NccWorker.Portability.{ConfigReads, Context}
  alias NccWorker.FirmwareInputs.LayoutNotRestored

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
  `work_dir` and `log_dir` where it writes; `enabled` (default true)
  is `enabled?/1` of the run's input; `judge` (default false) is
  `judge_enabled?/1` of it, and `judge_budget_sec` the judge's own budget
  (`judge_budget/1` of it);
  `hex_home` (default this VM's `HEX_HOME`) the Hex cache holding the run's
  tarballs.
  """
  @type ctx :: %{
          optional(:enabled) => boolean(),
          optional(:judge) => boolean(),
          optional(:judge_budget_sec) => non_neg_integer(),
          optional(:hex_home) => String.t() | nil,
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
  could be recorded for, and, with `ctx.judge`, the target's
  `firmware_judge` (`NccWorker.FirmwareJudge`). Returns the systems and one
  line per target tried, for the run's log, or `{:error,
  {:firmware_inputs_layout_not_restored, why}}` when a target's dirs could
  not be put back after its trace (`in_build_layout/4`) or its trace left
  processes running that may still write them: the run fails (exit 10)
  rather than publish from a project its build did not leave. `record`
  (default `record/4`) is for tests.
  """
  @spec put(%{String.t() => map()}, ctx(), keyword()) ::
          {%{String.t() => map()}, [String.t()]}
          | {:error, {:firmware_inputs_layout_not_restored, String.t()}}
  def put(systems, ctx, opts \\ []) do
    record = Keyword.get(opts, :record, &record/4)
    judge? = Map.get(ctx, :judge, false) == true

    passing =
      for {name, result} <- Enum.sort(systems),
          published_pass?(result),
          {:ok, target_env} <- [Map.fetch(ctx.targets, name)],
          do: {name, target_env, eligible?(result)}

    inputs? = enabled?(%{firmware_inputs: Map.get(ctx, :enabled, true)})

    reader? =
      passing != [] and inputs? and
        env_reads?(Path.join([ctx.project_dir, "deps", ctx.package]))

    if passing == [] or not (judge? or reader?) do
      {systems, []}
    else
      how = %{
        reader?: reader?,
        judge?: judge?,
        inputs?: inputs?,
        deadline: judge_deadline(ctx),
        package: ctx.package
      }

      Enum.reduce(passing, {systems, []}, fn {name, target_env, eligible?}, {acc, lines} ->
        {acc, new_lines} = put_target(acc, name, target_env, eligible?, {record, ctx, how})
        {acc, lines ++ new_lines}
      end)
    end
  rescue
    e in LayoutNotRestored -> {:error, {:firmware_inputs_layout_not_restored, e.message}}
  end

  # A target the run's `deps/` did not build (optional deps kept, variants
  # published): its inputs are never recorded, and the judge cannot speak
  # for it.
  defp put_target(systems, name, _target_env, false, {_record, _ctx, %{judge?: true}}),
    do: unjudged(systems, name, "closure differs from the run's")

  defp put_target(systems, _name, _target_env, false, _how), do: {systems, []}

  defp put_target(systems, name, target_env, true, {record, ctx, how}) do
    if how.reader? or System.monotonic_time(:second) < how.deadline do
      outcome = try_one(record, name, target_env, ctx, systems[name])
      put_one(systems, name, outcome, how)
    else
      unjudged(systems, name, "firmware judge budget spent")
    end
  end

  # The judge's own budget for the targets it alone traces (an env-reading
  # package's are traced for their inputs as before): `ctx.judge_budget_sec`
  # (`judge_budget/1` of the run's input), counted from the start of this
  # pass, `put/3`, not of the run.
  @judge_budget_sec 1800

  defp judge_deadline(ctx),
    do:
      System.monotonic_time(:second) +
        judge_budget(%{firmware_judge_budget_sec: ctx[:judge_budget_sec]})

  @doc """
  The judge's own budget of a run with `input` (`NCC_INPUT`, atom keys):
  its `firmware_judge_budget_sec` (the portal's
  NCC_FIRMWARE_JUDGE_BUDGET_SEC), a non-negative integer, else
  #{@judge_budget_sec} s.
  """
  @spec judge_budget(map()) :: non_neg_integer()
  def judge_budget(input) when is_map(input) do
    case Map.get(input, :firmware_judge_budget_sec) do
      n when is_integer(n) and n >= 0 -> n
      _ -> @judge_budget_sec
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

  @doc """
  Whether a run with `input` (`NCC_INPUT`, atom keys) records firmware
  targets' inputs: unless its `firmware_inputs` is `false` or the worker's
  own `NCC_FIRMWARE_INPUTS` is `"0"`. An input without the key is on.
  """
  @spec enabled?(map()) :: boolean()
  def enabled?(input) when is_map(input),
    do: Map.get(input, :firmware_inputs) != false and System.get_env("NCC_FIRMWARE_INPUTS") != "0"

  @doc """
  Whether a run with `input` judges every passing firmware target
  (`NccWorker.FirmwareJudge`): only when its `firmware_judge` is `true`,
  which a portal node sends while its NCC_FIRMWARE_JUDGE is `1`. An input
  without the key (an older portal, or the judge off) is off. The
  container sees no env of the host's, so no worker variable turns it on.
  """
  @spec judge_enabled?(map()) :: boolean()
  def judge_enabled?(input) when is_map(input), do: Map.get(input, :firmware_judge) == true

  # A pass whose beams bind keeps what its trace read, for an env reader and,
  # with the judge on, for every package (stream S11): the trace's
  # `compile_inputs`, and its config reads after the `.app`'s own
  # (`merged_env/2`). Only the inputs pass's rollback (`enabled?/1`) keeps
  # them out.
  defp put_one(systems, name, {:ok, %{compile_inputs: inputs, compile_env: env}}, how)
       when is_list(inputs) do
    {systems, inputs_lines} =
      if how.reader? or (how.judge? and how.inputs?),
        do:
          {Map.update!(
             systems,
             name,
             &Map.merge(&1, %{compile_inputs: inputs, compile_env: merged_env(&1, env)})
           ), ["Compile inputs of #{name} recorded"]},
        else: {systems, []}

    {systems, judge_lines} = judged(systems, name, how, {"pass", nil, []})
    {systems, inputs_lines ++ judge_lines}
  end

  defp put_one(systems, name, {:skip, reason, texts}, how) do
    lines = not_recorded(name, reason, how)

    {systems, judge_lines} =
      case FirmwareJudge.classes(texts, how.package) do
        [] -> judged(systems, name, how, {"unjudged", reason, []})
        classes -> judged(systems, name, how, {"skipped", reason, classes})
      end

    {systems, lines ++ judge_lines}
  end

  defp put_one(systems, name, {:error, why}, how) do
    {systems, judge_lines} = judged(systems, name, how, {"unjudged", why, []})
    {systems, not_recorded(name, why, how) ++ judge_lines}
  end

  defp put_one(systems, name, _other, how) do
    {systems, judge_lines} = judged(systems, name, how, {"unjudged", "no inputs", []})
    {systems, not_recorded(name, "no inputs", how) ++ judge_lines}
  end

  # The published `.app`'s own `compile_env`, then every config read of the
  # trace it does not list (`NccWorker.Portability.ConfigReads.merge/2`, as R5
  # lists a toolchain build's). Logger's compile-time purge keys, which every
  # `Logger` macro reads with `Application.get_env/3` and no `.app` lists, come
  # in this way. A `.app` whose list could not be read stays `nil`, which no
  # client matches.
  defp merged_env(result, env), do: ConfigReads.merge(result[:compile_env], env || [])

  defp not_recorded(name, why, %{reader?: true}),
    do: ["Compile inputs of #{name} not recorded: #{why}"]

  defp not_recorded(_name, _why, _how), do: []

  defp judged(systems, _name, %{judge?: false}, _verdict), do: {systems, []}

  defp judged(systems, name, _how, {"pass", nil, []}) do
    {put_judge(systems, name, "pass", nil, []), ["Firmware judge of #{name}: pass"]}
  end

  defp judged(systems, name, _how, {"unjudged", why, []}), do: unjudged(systems, name, why)

  # A refusal in a firmware channel withholds the target's own files, as R2
  # does (`NccWorker.FirmwareBuildRoot`): its `footprint.file_manifest` goes,
  # its status, firmware image and log stay.
  defp judged(systems, name, _how, {"skipped", reason, classes}) do
    systems =
      systems
      |> put_judge(name, "skipped", reason, classes)
      |> Map.update!(name, &withhold/1)

    {systems,
     ["Files of #{name} not published: firmware judge (#{Enum.join(classes, ", ")}): #{reason}"]}
  end

  defp unjudged(systems, name, why) do
    {put_judge(systems, name, "unjudged", why, []),
     ["Firmware judge of #{name}: unjudged (#{why})"]}
  end

  defp put_judge(systems, name, status, reason, classes) do
    Map.update!(
      systems,
      name,
      &Map.put(&1, :firmware_judge, %{status: status, reason: reason, classes: classes})
    )
  end

  defp withhold(%{beam_scan: %{"footprint" => footprint} = scan} = result) do
    %{result | beam_scan: Map.put(scan, "footprint", Map.delete(footprint, "file_manifest"))}
  end

  # A passing target that publishes its own first build and nothing else.
  defp eligible?(result) do
    result[:deps_lock] == nil and List.wrap(result[:published_variants]) == []
  end

  defp published_pass?(result),
    do: result[:status] in [:pass, "pass"] and published?(result[:beam_scan])

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
  Records one target's inputs: `{:ok, %{compile_inputs, compile_env}}`,
  `{:skip, reason, texts}` when the trace's verdict refused (its texts,
  `NccWorker.FirmwareJudge.texts/1`, whether or not the beams bind), or
  `{:error, why}` when any other step does not hold. `result` is the target's
  system result. Raises only `LayoutNotRestored` (`in_build_layout/4`, or a
  trace that left processes running), which `put/3` returns as the run's
  error. `nerves_env:` and `target_inputs:` (tests) replace step 1 and
  `NccWorker.Portability.target_inputs/3`.
  """
  @spec record(String.t(), {String.t(), list()}, ctx(), map(), keyword()) ::
          {:ok, %{compile_inputs: [map()], compile_env: [map()]}}
          | {:skip, String.t(), [String.t()]}
          | {:error, String.t()}
  def record(name, target_env, ctx, result, opts \\ [])

  # The run's own work dir.
  # sobelow_skip ["Traversal.FileModule"]
  def record(name, {target, env}, ctx, _result, opts) do
    dir = Path.join(ctx.work_dir, "fw-inputs-#{target}")
    nerves_env = Keyword.get(opts, :nerves_env, &nerves_env/3)
    target_inputs = Keyword.get(opts, :target_inputs, &Portability.target_inputs/3)
    _ = File.rm_rf(dir)
    File.mkdir_p!(dir)
    # Where the trace's build is kept for the binding: a name nothing the
    # trace ran can know, so none of it can have put a build there.
    kept = Path.join(dir, "traced-" <> Base.url_encode64(:crypto.strong_rand_bytes(12)))

    try do
      with {:ok, layout} <- layout(ctx.project_dir, target, env),
           {:ok, nerves} <- nerves_env.(ctx.project_dir, env, dir),
           {:ok, artifacts, roots} <- roots(nerves),
           {:ok, moved, roots} <- move(nerves, artifacts, roots, dir),
           # Named before the move, while it is there to resolve.
           moved_from = moved_from(layout),
           {:ok, verdict, traced} <-
             in_build_layout(layout, dir, kept, fn ->
               trace(target_inputs, {name, target, env}, moved, roots, {ctx, moved_from}, dir)
             end),
           :ok <- bound(traced, layout.build, ctx.package) do
        {:ok, %{compile_inputs: verdict.compile_inputs, compile_env: verdict.compile_env}}
      end
    rescue
      e in LayoutNotRestored -> reraise e, __STACKTRACE__
      e -> {:error, "firmware inputs: " <> Exception.message(e)}
    after
      # A published build that could not be put back stays where it is.
      unless lexists?(stash(dir)), do: File.rm_rf(dir)
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
  # and tree snapshots describe, compiled for the target as its firmware
  # build compiled it: in its build env as it is, under the same command
  # (`firmware_command/0`), at its own paths (`in_build_layout/4` has laid
  # them out), with Nerves's variables exported once every dependency is
  # loaded (`late_env:`). The compile writes the build's own dirs, so a
  # process it left running that the tracer could not kill (`Tracer.left_running/0`,
  # as `NccWorker.HostTrace` reads them) could go on writing them once they
  # are back: that fails the run, as a dir that cannot be put back does.
  defp trace(target_inputs, {name, target, env}, nerves, roots, {ctx, moved_from}, dir) do
    {wrapper, argv} = firmware_command()

    verdict =
      target_inputs.(ctx.project_dir, ctx.package,
        env: env,
        late_env: Enum.reject(nerves, fn {var, _} -> Regex.match?(@own_env, var) end),
        wrapper: wrapper,
        argv: argv,
        releases: ctx.releases,
        trees: ctx.trees,
        hex_home: Map.get_lazy(ctx, :hex_home, fn -> System.get_env("HEX_HOME") end),
        run_started_at: ctx.started_at,
        timeout_ms: @trace_timeout_ms,
        trace_dir: Path.join(dir, "trace"),
        log_file: Path.join(ctx.log_dir, "#{name}-inputs-trace.log"),
        target: target,
        roots: roots,
        moved_deps: moved_from
      )

    HexHome.publish(env_value(env, "HEX_HOME"))

    error = get_in(verdict, [:observations, "trace_stats", "tracer_error"])

    cond do
      error == "presweep_survived" ->
        raise LayoutNotRestored,
              "processes left running before the trace of #{target} could not be stopped " <>
                "(#{error})"

      error in Tracer.left_running() ->
        raise LayoutNotRestored, "the trace of #{target} left processes running (#{error})"

      true ->
        :ok
    end

    outcome(verdict)
  end

  defp outcome(%{status: :pass, compile_inputs: inputs, compile_env: env}) when is_list(inputs),
    do: {:ok, %{compile_inputs: inputs, compile_env: env || []}}

  defp outcome(%{status: :skip, reason: reason} = verdict),
    do: {:skip, reason || "not judged", FirmwareJudge.texts(verdict)}

  defp outcome(%{reason: reason}), do: {:error, reason || "not judged"}

  @doc """
  How the worker runs a target's firmware build (`NccWorker.Worker`):
  `mix` with `argv`, under `wrapper` (`fakeroot`, when the image has one)
  or on its own. A target's trace runs its compile the same way.
  """
  @spec firmware_command() :: {String.t() | nil, [String.t()]}
  def firmware_command, do: {System.find_executable("fakeroot"), ["firmware"]}

  @typedoc "Where a target's firmware build had its dirs, and the run's own `deps/`."
  @type layout :: %{build: String.t(), deps: String.t(), host_deps: String.t()}

  @doc false
  # The target's build dir and deps dir (its env's `MIX_BUILD_PATH` and
  # `MIX_DEPS_PATH`, `deps/` when it set none) and the run's own `deps/`:
  # real dirs inside the project, none inside another. Its env must be the
  # target's own, and its deps dir not the run's `deps/`: the trace compiles
  # in that tree, where the published build's `priv` links lead, so what the
  # compile writes in source would be published (the worker gives every
  # target its own).
  @spec layout(String.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, layout()} | {:error, String.t()}
  def layout(project_dir, target, env) do
    project = Path.expand(project_dir)
    host_deps = Path.join(project, "deps")
    build = expanded(env, "MIX_BUILD_PATH", project)
    deps = expanded(env, "MIX_DEPS_PATH", project) || host_deps
    layout = %{build: build, deps: deps, host_deps: host_deps}

    case Enum.find(layout_checks(layout, project, target, env), fn {holds?, _} ->
           not holds?.()
         end) do
      nil -> {:ok, layout}
      {_check, why} -> {:error, why}
    end
  end

  # In order: each check may count on the ones before it.
  defp layout_checks(layout, project, target, env) do
    %{build: build, deps: deps, host_deps: host_deps} = layout

    [
      {fn -> env_value(env, "MIX_TARGET") == target end, "the build env is not the target's"},
      {fn -> build != nil end, "no build path"},
      {fn -> inside?(build, project) and inside?(deps, project) end,
       "the target's build or deps dir is outside the project"},
      {fn -> deps != host_deps end, "the target's build used the run's deps/"},
      {fn -> not overlapping?(layout) end, "the target's build and deps dirs overlap"},
      {fn -> dir?(build) and dir?(host_deps) end, "no published build or deps dir to trace"},
      {fn -> not lexists?(deps) or dir?(deps) end, "the target's deps dir is no dir"}
    ]
  end

  # The run's `deps/` as the compiles before the trace wrote it, expanded and
  # real: the trace compiles it at the target's deps dir, so an absolute path
  # a build wrote into it, rebar3's link from the `prod` profile to a plugin
  # dir, names the old place (S8 pilot, F382; `RebarPlugins`).
  defp moved_from(%{host_deps: host_deps}) do
    Enum.uniq(Enum.reject([host_deps, Context.realpath(host_deps)], &is_nil/1))
  end

  defp overlapping?(%{build: build, deps: deps, host_deps: host_deps}),
    do: nested?(build, deps) or nested?(build, host_deps) or nested?(deps, host_deps)

  defp expanded(env, name, project) do
    case env_value(env, name) do
      nil -> nil
      path -> Path.expand(path, project)
    end
  end

  defp inside?(path, dir), do: String.starts_with?(path, dir <> "/")
  defp nested?(a, b), do: a == b or inside?(a, b) or inside?(b, a)

  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(path), do: match?({:ok, %File.Stat{type: :directory}}, File.lstat(path))

  # sobelow_skip ["Traversal.FileModule"]
  defp lexists?(path), do: match?({:ok, _}, File.lstat(path))

  defp stash(dir), do: Path.join(dir, "published")

  @doc false
  # Runs `fun` (the trace) in the project laid out at the paths the
  # target's firmware build used, so whatever path its compile can see
  # (`__DIR__`, `Mix.Project.build_path/0`, `deps_path/0`, a source path in
  # a beam) is the build's: the published build moved aside
  # (`<dir>/published`), leaving its path for the trace to build into, and
  # the run's own `deps/` at the target's deps dir, whose own tree is moved
  # aside too. Renames only, within the run's work dir. Afterwards the
  # trace's build is at `kept` (removed if it cannot be moved there) and
  # every dir is back; whatever the trace left at a path one was moved from
  # is removed first. Returns `{:ok, result, kept}` for a `{:ok, result}` of
  # `fun`, its result as it is otherwise. A move that cannot be undone raises
  # `LayoutNotRestored`: nothing may go on to publish files from a project
  # laid out otherwise than the build left it.
  @spec in_build_layout(layout(), String.t(), String.t(), (-> result)) ::
          {:ok, term(), String.t()} | result | {:error, String.t()}
        when result: term()
  # sobelow_skip ["Traversal.FileModule"]
  def in_build_layout(layout, dir, kept, fun) do
    File.mkdir_p!(stash(dir))

    case move_all(moves(layout, dir), []) do
      {:ok, done} ->
        try do
          with {:ok, result} <- fun.(), do: {:ok, result, kept}
        after
          keep_trace_build(layout.build, kept)
          undo!(done)
          File.rmdir(stash(dir))
        end

      {:error, why} ->
        File.rmdir(stash(dir))
        {:error, why}
    end
  end

  defp moves(layout, dir) do
    own_deps =
      if lexists?(layout.deps), do: [{layout.deps, Path.join(stash(dir), "deps")}], else: []

    [{layout.build, Path.join(stash(dir), "build")}] ++
      own_deps ++ [{layout.host_deps, layout.deps}]
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp move_all([], done), do: {:ok, done}

  defp move_all([{from, to} | rest], done) do
    case File.rename(from, to) do
      :ok ->
        move_all(rest, [{from, to} | done])

      {:error, why} ->
        undo!(done)
        {:error, "could not lay out the build's dirs: #{from}: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp keep_trace_build(build, kept) do
    if lexists?(build) and File.rename(build, kept) != :ok, do: File.rm_rf(build)
  end

  # Most recent move first.
  # sobelow_skip ["Traversal.FileModule"]
  defp undo!(done) do
    Enum.each(done, fn {from, to} ->
      _ = if lexists?(from), do: File.rm_rf(from)

      case File.rename(to, from) do
        :ok -> :ok
        {:error, why} -> raise LayoutNotRestored, "#{to} -> #{from}: #{inspect(why)}"
      end
    end)
  end

  # Step 3: the traced compile's beams for the package (under `kept`, where
  # `in_build_layout/4` left them) against the published build's, by the
  # code and the attributes each holds.
  defp bound(kept, build_path, package) do
    traced = Path.join([kept, "lib", package, "ebin"])

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

  @doc false
  # Every beam in `ebin` by module, with the md5 of its code and its
  # attributes chunk as it is (`module_info(:attributes)`: persisted
  # attributes, which the md5 leaves out); `%{}` when any cannot be read.
  # The other chunks the md5 leaves out (`CInf`, `Dbgi`, `Docs`) hold the
  # source path and compile options, which nothing running reads.
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

defmodule NccWorker.FirmwareInputs.LayoutNotRestored do
  @moduledoc """
  A firmware target's dirs could not be put back after its trace
  (`NccWorker.FirmwareInputs.in_build_layout/4`), or the trace left
  processes running that may still write them: the run must stop rather
  than publish from them.
  """
  defexception [:message]
end
