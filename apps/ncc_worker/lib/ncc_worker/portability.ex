defmodule NccWorker.Portability do
  @moduledoc """
  The compile-time half of the precompiled portability verdict (spec R1-R4),
  in phase P1: it only adds refusals. `run/3` runs the traced judge compile
  (`NccWorker.Tracer`) and `judge/5` reads its `NccWorker.Tracer.Report`;
  callers AND the verdict with rule 1 (`NccWorker.BuildSelection.portable?/4`),
  which stays unchanged.

  Order, first failure wins:

    1. an incomplete trace: any `Report` problem, a missing or failed start,
       closure, stats or end, `unjudged > 0`, any event `Events.decide/4`
       could not judge, wherever it is attributed, or a closure dependency
       whose `ebin`/`priv` no longer match the digest taken when its window
       closed (`built_check:`, on unless turned off and always in `run/3`;
       no digest then, none now, no build dir or no time left in the
       recompute budget is a mismatch too);
    1b. a declassified closure dependency built by another manager than its
       tarball's `build_tools` give (item 1, `judge/5`'s `declassified:`, "manager mismatch");
    1c. a closure dependency whose source tree was not its verified Hex
       tarball's before the compile (item 5e, `Trees`, `judge/5`'s `trees:`,
       "dependency tree differs from its tarball"); a file or listing the
       compile read that changed after that check is could-not-judge (1);
    2. a refusal outside every window (it counts against everything);
    3. a refusal in the package's window (R1, R4 through `Events`);
    4. the package's window broken (missing, lowered depth, failed
       integrity, no sentinel);
    5. R2 on the package's `ebin` (`BuildRoot`), where a bare source path
       also refuses when the module that holds it runs programs
       (`BuildRoot.program_source_paths/3`);
    6. the rebar3 rules on the package (`Rebar`);
    7. host taint of a closure dependency (R3), the first in compile order:
       its window broken or without a sentinel, a refusal in its window (but
       a reviewed guarded-module probe whose modules the package's compile
       could not see, `Guarded`, never in a firmware target's or host-native
       verdict), a compile-time call into a natively built dependency in its
       window (`native_calls`), R2, the rebar3 static rules or rebar3 trace
       coverage.

  A read in a natively built dependency's `ebin` (`Events`'
  `native_beam_reads`) is settled before steps 3 and 7: allowed when that
  dependency is clean and the read came after its window, otherwise the
  refusal of the window it fell in (`beam_reads/5`, judge revision 15).
  So is a closure dependency's own compile reading a file in its own source
  `priv` through Mix's link (`Events`' `own_priv_reads`): allowed when that
  dependency's source tree is exactly its verified tarball's after the
  compile and holds the file, otherwise the refusal of its window
  (`own_priv_reads/2`, judge revision 23), in a firmware target's trace too,
  where a read in a window the native build tool ran in always refuses.
  And so is a Mix alias of a closure dependency's own project copying a
  file of its own source tree onto another (`Events`' `own_tree_copies`,
  phoenix's `copy_core_components/1`): allowed when its verified tarball
  holds both files with the same bytes and the tree is still exactly that
  tarball's after the compile, otherwise the refusal of its window
  (`own_tree_copies/2`, judge revision 27).

  A job sent `foreign_priv: true` (`NCC_INPUT.judge.foreign_priv`) opens the
  foreign priv gate when its four conditions hold (`ForeignPriv.gate/3`):
  kino's reviewed `Kino.JS` writes into its build `priv/assets/<d>` are
  observed (`Events`), settled per window (`ForeignPriv.settle/2`: a failure
  is that window's refusal), and the settled directories are left out of
  kino's built check. A pass then carries `foreign_priv`, the package's own
  settled archives, and `foreign_priv_rule`; `trace_stats["foreign_priv"]`
  records `"on"` or `"off"`. Without the flag nothing here changes.

  A job sent `native_side: true` (`NCC_INPUT.judge.native_side`, toolchain
  judge only) sets a natively built closure dependency's native side apart
  from its beams. In a closure dependency's window, never the package's,
  the reviewed native build tool's own activity (elixir_make's compiler and
  cc_precompiler, its precompiler, each the Hex package of its name in a
  reviewed version: their host reads, `make`, the download, their cache
  dir, `priv`) is a `native_build` observation instead of a refusal or an
  input, as in a firmware target's trace; an integrity call
  and a write to the env or the application env from their frame refuse
  as there, and a package fun they run is the dependency's own. Such a
  dependency is clean only when its beams are shown to be its sources'
  alone (`side_problem/3`): it is on the native list, Mix built it, no closure NIF was mapped by its
  window's close, its tree is exactly its verified tarball's, every beam in
  its ebin compiled from that tree and every checksum file the tool
  evaluates a literal map; else that is its taint (`native build not set
  apart: `), and then every beam in the package's own ebin must have
  compiled from the package's own sources too. A dependent's reads of its beams follow revision 15's rule,
  a library of OTP's own (a download's `crypto`) mapped in its window
  allowed, and a read of any other file in its ebin refuses. Every call
  into it and every read of its `priv` still refuse. `trace_stats` records
  `"native_side"`, `"on"` or `"off"`, on the toolchain judge. No judge
  revision: the flag is the record.

  Likewise `trace_stats["relocate"]` on every toolchain verdict: `"off"`
  without `relocate: true` (`NCC_INPUT.judge.relocate`), `"on"` with it
  when nothing was held, and otherwise what `NccWorker.Portability.Relocate`
  decided (`"relocated"`, `"dependencies"`, `"refused: <why>"`), so a row
  shows which way it was judged (the umbrella re-review's Q3).

  A job sent `differential: true` (`NCC_INPUT.judge.differential`) has a
  read of a value the worker can change (the scheduler count and HOME
  anywhere, the plain arguments outside every window) observed as
  `varied_reads` instead of refused (`Events`); a verdict that would pass
  with any is held as could-not-judge (`Differential.hold/2`), and only
  `run/3` passes it, after two variant builds of the closure with those
  values at either end of their domain wrote the same app
  (`Differential.settle/6`); otherwise it refuses with the read's own
  refusal and what differed. A verdict `PrivRepro` holds as well is
  could-not-judge. Without the flag nothing here changes, and no judge
  revision does either.

  The package's own compile writing into its own build `priv`, and the
  probes `File.mkdir_p/1` makes of the directories above it (`Events`'
  `priv_writes` and `priv_probes`, judge revision 21), refuse nothing here,
  but a verdict that would pass with any of them is held as could-not-judge
  (`PrivRepro.hold/2`): only `run/3` passes it, after a second traced build
  wrote the same `priv` (`PrivRepro.settle/6`). Then the verdict carries
  `built_priv`, the files the package's own compile wrote there, relative
  to `priv`; every other pass carries `[]`. In a dependency's window, and in
  a firmware target's trace, they refuse as they always did.

  Compile-time config reads (R5) and Elixir-version reads are judged over the
  package's whole closure (`ConfigReads`, `ElixirVersion`): their refusals
  belong to the window they fell in, so in a dependency's window they taint
  it (step 7), and their problems (a toolchain read no reviewed list covers,
  no config snapshot, no Elixir version) make the trace incomplete (step
  1). A passing verdict carries `compile_env`, the closure's config reads
  as manifest items valued from the trace's config snapshot; every other
  verdict has it nil. It also carries `compile_inputs`, the closure's
  compile-time environment reads and the config reads a client must check
  itself (`CompileInputs`); every other verdict has it nil.

  Steps 1, 4, an `ebin` R2 cannot read (for the package or any closure
  dependency) and the package's own rebar3 coverage are "portability could
  not be judged"; the details go to `observations["problems"]`. Everything
  else is a refusal with its own reason. Native taint is the
  `native_closure` channel in the package's window (`Events`).

  `erlang:load_nif/2` is not call-traceable, so native libraries a compile
  maps are checked from the tracer's `/proc/self/maps` snapshots instead
  (`MappedLibs`): a new library outside the OTP root, the Elixir install and
  the closure's native dependencies refuses for the window it first shows
  up in (outside every window when it first shows at the end), and no maps
  is could-not-judge (waived only by `NCC_TRACE_ALLOW_NO_NIF_CHECK=1`, which
  the ncc_worker test helper sets on macOS and the worker never sets;
  `judge/5` also takes `nif_waiver:`).

  Only the package's closure counts, so a verdict cannot pass on another
  package's refusal: events, child traces and refusals of an app outside
  `Context.closure_of/2` of the package are dropped, and so is a stray child trace (`unknown`, an
  elixir_make `erl -eval` sub-VM: the spawn is itself traced in the Mix VM).
  An unjudged event is never dropped. Events in a native-pattern quiet
  interval are the tracer's own loading of a native dependency: dropped too,
  except an unjudged one or an integrity refusal, which count as outside
  every window.

  Never raises: anything unexpected is "portability could not be judged",
  which publishes nothing and changes no status.
  """

  alias Compatibility.{Elf, NifOrigin}
  alias Compatibility.Portability, as: Reasons
  alias NccWorker.{BuildCache, DepsLock, NativeBuild, ProcessSweep}

  alias NccWorker.Portability.{
    BuildRoot,
    CompileInputs,
    ConfigReads,
    Context,
    Declared,
    Differential,
    ElixirVersion,
    Events,
    ForeignPriv,
    Guarded,
    MappedLibs,
    PrivRepro,
    Probes,
    Rebar,
    RebarPlugins,
    Relocate,
    ReviewedScripts,
    Trees
  }

  alias NccWorker.Tracer
  alias NccWorker.Tracer.Report

  @type verdict :: %{
          required(:status) => :pass | :skip,
          required(:reason) => String.t() | nil,
          required(:observations) => map(),
          optional(:compile_env) => [ConfigReads.item()] | nil,
          optional(:compile_inputs) => [map()] | nil,
          optional(:manager) => String.t() | nil,
          optional(:foreign_priv) => [map()] | nil,
          optional(:foreign_priv_rule) => String.t() | nil
        }

  @default_timeout_ms 30 * 60 * 1000
  @caps %{
    "config_reads" => 200,
    "elixir_version" => 50,
    "native_calls" => 50,
    "native_beam_reads" => 50,
    "mix_exs_allowed" => 50,
    "build_root_source_path" => 50,
    "build_root_recompile_dir" => 50,
    "mix_project_paths" => 50,
    "env_reads" => 50,
    "endian_reads" => 50,
    "os_type_reads" => 50,
    "env_writes" => 50,
    "config_writes" => 50,
    "native_build" => 50,
    "target_reads" => 50,
    "priv_writes" => 50,
    "priv_probes" => 50,
    "own_priv_reads" => 50,
    "own_tree_copies" => 50,
    "foreign_priv" => 50,
    "holder_calls" => 50,
    "declared_absent" => 200,
    "varied_reads" => 50
  }
  @max_refusals 100
  @max_problems 20
  @integrity "compile-time tracing or system flag: "
  # The built check's recompute: all digests together, and one digest
  # (`ncc_tracer_digest`'s own default).
  @built_budget_ms 5 * 60 * 1000
  @digest_timeout_ms 60_000

  # The judge's revision (precompiled judge refinements spec, principle 4):
  # bumped by every change to what the judge accepts, written into each
  # toolchain build's `judge_revision`, and what the portal reopens skipped
  # rows by (`Portal.Catalog`, `@judge_reopen`). Never key anything on
  # reason text instead. 3: compile-time env reads and config values the
  # snapshot cannot give are recorded inputs, not refusals (bumped by two
  # while `makefile_rule2` exists). 5: rebar3's own log and colour config
  # reads are dropped, a baked source path refuses only in a module that
  # runs programs, installed OTP code may call into a module the trace
  # loaded when its `.app` lists that module's application, and a
  # dependency's `rebar.config.script` is judged by its reads and result
  # (bumped by two while `makefile_rule2` exists). 7: rule 2's text checks
  # match whole tool names, a rebar3 parent's script overrides come from its
  # `mix.rebar.config`, rebar3 hooks count only on compile commands and
  # `platform_define` is judged per branch, a `rebar3_hex` plugin from Hex is
  # let through, a mix.exs read of a path the verified tarball lacks is the
  # tree check's, a literal Version comparison in mix.exs is judged over the
  # minor series, and a source directory held only by `__mix_recompile__?/0`
  # is observed (bumped by two while `makefile_rule2` exists). 9: quic's
  # reviewed `build_nif.sh` compile hook is let through (`Rebar.reviewed_hooks/0`),
  # a `platform_define` regex the OTP major does not decide is a compile input
  # rather than a refusal, and rule 2 leaves the package's own name out of
  # its native-tool grep and counts its target reads only where they can run
  # at compile time (`NccWorker.TargetScan`), and no longer refuses a
  # mention of Nerves in the sources (bumped by two while `makefile_rule2`
  # exists). 11: the tracer's final sentinel accepts Mix's reload of a
  # natively built dependency's consolidated protocol, and toolshed 0.5.0's
  # reviewed `System.version/0` read is let through
  # (`ElixirVersion.reviewed_apps/2`) (bumped by two while `makefile_rule2`
  # exists). 13: a compile-time read of the byte order
  # (`:erlang.system_info(:endian)`, `System.endianness/0`; nx and every
  # package with nx in its closure) is an `endian` compile input the client
  # compares, valued from the tracer's start line, instead of a host read
  # (bumped by two while `makefile_rule2` exists). 15: a read in a natively
  # built dependency's `ebin` (Elixir 1.20's type checker reading a remote
  # module's beam) is allowed when that dependency's own compile is clean,
  # Mix built it, no native code ran in it and its tree is still its
  # tarball's (`beam_reads/5`), and rule 2 leaves out of the package's own
  # native-tool grep a tool its `mix.exs` names only as an optional
  # dependency (rustler_precompiled's `{:rustler, ..., optional: true}`,
  # `NccWorker.BuildCache.dep_target_agnostic_rule2?/4`), and a dependency
  # whose compile calls a natively built dependency (`native_calls`) is
  # tainted (bumped by two while `makefile_rule2` exists). 17: a
  # compile-time read of the OS type (`:os.type/0`,
  # `system_info(os_type)`; kino's `Kino.JS.__before_compile__/1` through
  # `File.rm_rf!/1`) is an `os_type` compile input the client compares,
  # valued from the tracer's start line, instead of a host read (bumped by
  # two while `makefile_rule2` exists). 19: a package fun Mix runs as an
  # alias that tail-calls `System.put_env/2` (circuits_i2c's
  # `compile: [&set_make_env/1, "compile"]`) is traced as the package's
  # write, a write with no source file of its own has recorded inputs when
  # every earlier read in its VM is recorded, and a firmware target's trace
  # is judged for its compile inputs (`target_inputs/3`) (bumped by two
  # while `makefile_rule2` exists). 21: the package's own compile may write
  # into its own build `priv` (not a link to its sources), and
  # `File.mkdir_p/1` may ask the directories above that `priv` whether they
  # are directories (kino's `Kino.JS.__before_compile__/1`), when a second
  # traced build at a build path that shares no directory with the first
  # writes that `priv` the same (`PrivRepro`: byte for byte, or a tar
  # archive whose members' times alone differ) and no file there holds one
  # of R2's roots (`PrivRoots`); its files are the verdict's `built_priv`,
  # which the static priv rules take without a tarball entry.
  # Also 21: with `makefile_rule2`, a target read in a doc file of the
  # package under test (fledex's README naming `MIX_TARGET`) no longer
  # makes it natively built in the trace (`NativeBuild.split/4`), as it does
  # not in the static rules, so Elixir 1.20's parallel checker reading the
  # package's own protocol beam back from its ebin is allowed (bumped by two
  # while `makefile_rule2` exists). 23: a closure dependency's own compile
  # may read the bytes of a file in its own source `priv` through the link
  # Mix made from its build `priv` (rustler's `Mix.Tasks.Rustler.New`
  # embedding its templates), when that dependency's whole source tree is
  # still exactly its verified tarball's after the compile and the tarball
  # holds the file (`own_priv_reads/2`); a
  # dependent reading it, a build `priv` of its own and a path that
  # resolves out of the source `priv` keep their refusal (bumped by two
  # while `makefile_rule2` exists). 25: a host-native build (only) lets
  # through rustler_precompiled's normal path (tokenizers 0.5.2): the
  # expander calling `Rustler.MACRO-__using__/2` for the tool's quote, once
  # per tool macro before it in the same process, and the ram_file driver's
  # port its `download_or_reuse_nif_file/2` opens to unpack the downloaded
  # archive (`@reviewed_unpacks`), both in the package's own window only
  # (`tool_events/2`), and the libraries the package's own priv library's
  # `DT_NEEDED` makes the loader map with it from the C library's dir
  # (`needed_libs/2`: glibc's `libdl.so.2` and `libpthread.so.0` for
  # tokenizers' NIF); a read a package's variant fun tail-calls from the
  # tool's `variant_suffix/2` is the package's (`@package_fun_frames`), and
  # its own reads of the env that overrides its triple are inputs
  # (`@tool_env_inputs`);
  # firmware target and toolchain verdicts do not change (bumped by two
  # while `makefile_rule2` exists). 27: a Mix alias of a closure
  # dependency's own project, in the process Mix runs its tasks in, may copy
  # a file of its own source tree onto another (and `File.cp/3` the
  # source's mode onto it) when its verified tarball holds both with the
  # same bytes and the tree is still exactly that tarball's after the
  # compile (`own_tree_copies/2`): phoenix's `compile:
  # [&copy_core_components/1, "compile"]`, which refused phoenix and every
  # package with it in its closure (bumped by two while `makefile_rule2`
  # exists). 29: a toolchain run asked for `deterministic: true` also
  # builds the package's deterministic sibling (`NccWorker.Deterministic`):
  # the closure's own traced compile with `ERL_COMPILER_OPTIONS=deterministic`
  # at a build path of its own, judged by every rule here on the lock and
  # tree snapshots the build was judged on, and kept only when it is the
  # build but for what the option changes (`Compatibility.DeterministicBeams`);
  # the build's own verdict does not change (bumped by two while
  # `makefile_rule2` exists).
  @judge_revision 29

  @doc "The judge revision a toolchain build made with `opts` records."
  # `NCC_INPUT.judge.makefile_rule2` adds one, so turning item 1 on
  # re-judges every skipped row once without an image change. While that
  # flag exists, the next refinement to ship bumps `@judge_revision` by two.
  @spec judge_revision(keyword()) :: pos_integer()
  def judge_revision(opts \\ []),
    do: @judge_revision + if(makefile_rule2?(opts), do: 1, else: 0)

  @doc """
  The project's Hex releases from its `mix.lock`, for `run/3`'s `releases:`.
  Take it right after `deps.get` and before any compile: an untraced build
  step could rewrite the lock and a tarball together later.
  """
  @spec lock_snapshot(String.t()) :: {:ok, map()} | :error
  def lock_snapshot(project_dir) do
    case DepsLock.hex_releases(project_dir) do
      {:ok, releases} when is_map(releases) -> {:ok, releases}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  @doc """
  Runs the traced compile of `package` in `project_dir` and judges it. In
  `:judge` mode that compile recompiles the package's closure only; in
  `:host` mode it is the run's host compile, which also compiles the project
  (`NccWorker.Tracer`). Options:

    * `env:` (required), the host compile's env;
    * `releases:` (required), `lock_snapshot/1` taken before any compile;
      without it nothing runs and the verdict is could-not-judge;
    * `hex_home:`, the run's verified Hex cache (default: `HEX_HOME` in
      `env`; without either no dependency source file is readable);
    * `run_started_at:`, the run's start in monotonic seconds, which bounds
      the compile by what is left of the run (`NccWorker.Tracer`);
    * `mode:`, `:judge` (default) or `:host`, passed to `NccWorker.Tracer.run/3`;
      any other value runs nothing and the verdict is could-not-judge;
    * `trees:`, item 5e: the `tree_snapshot/2` taken before the closure's
      first compile, or `:off` for no tree check (today's verdict). Without
      it (or with `nil`, `first_tree_snapshot/3`'s "too late") `run/3` takes the snapshot itself, which is right only before any
      compile: when the build dir already holds one of the closure's apps it
      checks nothing and the verdict is could-not-judge;
    * `makefile_rule2:`, item 1 of the judge refinements (see
      `NccWorker.NativeBuild`): `true` takes off the native list the
      dependencies whose native build file Mix never runs, and the judge
      holds them to the trace's manager (`judge/5`'s `declassified:`); a
      `deps/` that cannot be listed is then could-not-judge. Anything but
      `true` is off;
    * `native_side:`, `true` sets a natively built closure dependency's
      native side apart (see above) on the toolchain judge and reads rule
      2's target and native-tool grep finer (`NativeBuild.split/4`);
      anything but `true`, or with `target:`, is off;
    * `target:` and `host_native: true`, a host-native build's verdict
      (`NccWorker.HostNative`, `target: "host"`): judged as a firmware
      target's inputs are (`target_inputs/3`), with rustler_precompiled set
      apart too (`host_native_tools/0`; its quote's expansion of Rustler's
      macro and its unpack's ram_file port included, judge revision 25),
      the package's own priv libraries allowed to be mapped, with the
      system libraries their `DT_NEEDED` maps alongside them (judge
      revision 25), and R2 on the package's ebin; `host_native:` without
      `target:` is off;
    * `trace_dir:` (default `<project_dir>/../trace`), `log_file:`,
      `timeout_ms:`, `extra_env:`, `reap:`, `cmd:`, `sweep:` (tests);
      `declared_fetch:` replaces the declared fetch (`Declared.fetch/4`'s
      `fetch:`, tests).

  Before anything else it sweeps the container (`NccWorker.Tracer.sweep/2`):
  every process but the worker's own is killed, so nothing an untraced step
  before it left running can change what the judge checks or the compile
  reads; `NccWorker.Tracer.run/3` sweeps again once the compile is over.

  Never raises. Adds `observations["trace_stats"]["wall_ms"]` and
  `observations["trace_stats"]["judge_compile"]`, which names the traced
  compile in either mode: `"finished"` when it exited 0, `"not_run"` when it
  never started for want of `releases:`, for an unknown `mode:` or because
  the sweep before it left survivors or could not run in a portal build
  (`tracer_error` `"presweep_survived"` or `"presweep_unavailable"`) (in
  `:judge` mode the build is the host compile's, untouched; in `:host` mode
  nothing was built), and
  `"not_finished"` otherwise (a crash, a timeout, a non-zero exit, an
  exhausted budget, the judge itself raising): the build under `_build` may
  then be half-written, and callers must not judge it.

  Also adds `observations["trace_stats"]["transient"]`: `true` when the
  verdict says nothing about the package, because the judge compile did not
  finish (`judge_compile` other than `"finished"`: a timeout, a kill, an
  exhausted run budget, processes that survived the cleanup or a sweep, a
  crash) or its
  report was over the read budget (`"report_over_budget"`,
  `NccWorker.Tracer.Report`). A later run may judge it, so the portal retries
  such a build. Also `true` when a probe of what may be a module of a
  declared-absent dependency the fetch could not get decided the verdict
  (`trace_stats["declared_unknown"]`, `settle_declared/1`). `false`
  otherwise: a pass, a refusal, or a could-not-judge the
  same package and lock would get again (a missing or unverified tarball, a
  rebar3 parent's script, a beam R2 cannot read, a missing `ebin`).

  `compile_ms`, `report_ms` and `judge_ms` split `wall_ms` into the traced
  compile, reading its report and judging it (the last two only when the
  compile finished); `tracer_error` names why a compile did not finish (`nil`
  when it exited 0): the error `NccWorker.Tracer.run/3` returned (`"timeout"`,
  `"killed"`, `"run_budget_exhausted"`, `"group_survived"`,
  `"cleanup_unverified"`, `"writers_survived"`, `"sweep_survived"`,
  `"sweep_unavailable"`, `"window_sweep_failed"`, `"tracer_modified"`,
  `"exited"`, `"cmd_failed"`, ...) or `"exit_<n>"` for a non-zero exit.
  `trace_mode` (only when the compile finished) is the mode the report's start
  line names (`NccWorker.Tracer.Report.mode/1`, `"judge"` without one): a
  caller that asked for `:host` takes `_build` as the build only when it says
  `"host"` (`NccWorker.HostTrace`).
  """
  @spec run(String.t(), String.t(), keyword()) :: verdict()
  def run(project_dir, package, opts) do
    started = System.monotonic_time(:millisecond)

    project_dir
    |> guarded_run(package, opts)
    |> PrivRepro.settle(project_dir, package, opts, &run/3, &build_digest/1)
    |> Relocate.settle(project_dir, package, opts, &run/3, &build_digest/1)
    |> Differential.settle(project_dir, package, opts, &run/3, &build_digest/1)
    |> put_differential_flag(opts)
    |> settle_declared()
    |> put_stat("wall_ms", System.monotonic_time(:millisecond) - started)
    |> put_transient()
  end

  # `trace_stats["differential_flag"]`: `"on"` on every verdict a job sent
  # `differential: true` was judged with, whatever came of it (the
  # requeue's pilot check reads it); absent otherwise, a variant's own
  # included.
  defp put_differential_flag(verdict, opts) do
    if Keyword.get(opts, :differential) == true,
      do: put_stat(verdict, "differential_flag", "on"),
      else: verdict
  end

  @doc false
  # Public for tests (coverage drop 2026-11-22, F7). A declared-absent
  # dependency the pre-judge fetch could not get holds no known module
  # (`Declared`), so a probe of what may be its module refuses. When such a
  # probe decides the verdict (its reason, the package's own or a closure
  # dependency's taint, is a probe of a dependency outside the closure, not
  # from a `mix.exs`, which refuses whatever is declared), the verdict says
  # nothing about the package: it becomes the transient could-not-judge
  # (`trace_stats["declared_unknown"]`, read by `put_transient/1`), which
  # the portal retries, up to its cap, after which it stays skipped. A
  # retry judges afresh and never passes on what this one did not know. A
  # verdict another refusal decides, a pass, or a fetch that failed for
  # nothing (or was off, `NCC_DECLARED_FETCH=0`) is left as it is.
  @spec settle_declared(verdict()) :: verdict()
  def settle_declared(%{status: :skip, reason: reason, observations: obs} = verdict)
      when is_binary(reason) do
    case unfetched(get_in(obs, ["trace_stats", "declared_fetch"])) do
      [] ->
        verdict

      names ->
        if declared_probe?(reason) do
          problem =
            "declared dependencies could not be fetched: #{Enum.join(names, ", ")} " <>
              "(the probe that decided: #{reason})"

          verdict
          |> unsplit(problem)
          |> put_stat("declared_unknown", names)
        else
          verdict
        end
    end
  end

  def settle_declared(verdict), do: verdict

  defp unfetched(%{"failed" => [_ | _] = failed}), do: failed
  defp unfetched(%{"error" => ":off"}), do: []
  defp unfetched(%{"error" => why}) when is_binary(why), do: [why]
  defp unfetched(_fetch), do: []

  defp declared_probe?("closure dependency observed the host: " <> rest) do
    case :binary.match(rest, " (") do
      {at, 2} ->
        inner = binary_part(rest, at + 2, byte_size(rest) - at - 2)
        String.ends_with?(inner, ")") and declared_probe?(String.slice(inner, 0..-2//1))

      :nomatch ->
        false
    end
  end

  defp declared_probe?(reason) do
    String.starts_with?(reason, Reasons.dependency_probe()) and
      not String.ends_with?(reason, " in mix.exs")
  end

  # The digest the tracer takes of a build dir when its window closes, taken
  # again now (`PrivRepro`: the first build must not change while the second
  # one runs).
  defp build_digest(dir) when is_binary(dir) do
    case digest_now(dir, @digest_timeout_ms) do
      {:ok, digest, _files} -> {:ok, digest}
      {:error, why} -> {:error, why}
    end
  end

  defp build_digest(_dir), do: {:error, :no_build_dir}

  @doc """
  A firmware target's compile-time inputs (`NccWorker.FirmwareInputs`): the
  traced judge compile of `package`'s closure, as `run/3` runs it, in a
  project whose env (`env:`, `extra_env:`) is the target's own, Nerves's
  build env included, judged by what a firmware build needs a client to
  check rather than by R1 to R4. `target:` (required) is the `MIX_TARGET`
  it compiled for, recorded for every `Mix.target/0` read; `roots:` the
  builder's `NERVES_TOOLCHAIN` and `NERVES_SYSTEM`
  (`NccWorker.Portability.CompileInputs`). `wrapper:`, `argv:` and
  `late_env:` go to `NccWorker.Tracer.run/3`, and the env's `MIX_DEPS_PATH`
  names the dir whose trees, native build files and hook scripts are
  checked. The reviewed native build tool's
  own activity (`native_tools/0`) is set apart, never an input. Passing
  means every other compile-time read was recorded: the verdict then
  carries `compile_inputs` and `compile_env`. Anything else is `:skip`,
  and so is a `target:` that is not a target name. Never raises.
  """
  @spec target_inputs(String.t(), String.t(), keyword()) :: verdict()
  def target_inputs(project_dir, package, opts) do
    if Compatibility.CompileInputs.name?(Keyword.get(opts, :target)),
      do: run(project_dir, package, Keyword.put(opts, :mode, :judge)),
      else: not_run("no target to judge a firmware build's inputs for")
  end

  defp put_transient(%{status: :pass} = verdict), do: put_stat(verdict, "transient", false)

  defp put_transient(%{observations: obs} = verdict) do
    stats = Map.get(obs, "trace_stats") || %{}

    transient =
      stats["judge_compile"] != "finished" or stats["report_over_budget"] == true or
        stats["priv_repro"] == "not_finished" or stats["differential"] == "not_finished" or
        match?([_ | _], stats["declared_unknown"])

    put_stat(verdict, "transient", transient)
  end

  defp guarded_run(project_dir, package, opts) do
    case {releases(opts), Keyword.get(opts, :mode, :judge)} do
      {_releases, mode} when mode not in [:judge, :host] ->
        not_run("unknown tracer mode: #{inspect(mode)}")

      {{:ok, releases}, _mode} ->
        traced_run(project_dir, package, opts, releases)

      {:error, _mode} ->
        not_run("no mix.lock snapshot taken before the compile")
    end
  rescue
    e -> unfinished("judge failed: " <> Exception.message(e))
  catch
    kind, reason -> unfinished("judge failed: #{kind} #{inspect(reason, limit: 20)}")
  end

  # The traced compile never started: `_build` is as it was.
  defp not_run(why), do: why |> not_judged() |> put_stat("judge_compile", "not_run")

  # Nothing says the judge compile ran to its end, so `_build` may hold a
  # half-written build no caller may judge.
  defp unfinished(why), do: why |> not_judged() |> put_stat("judge_compile", "not_finished")

  defp releases(opts) do
    case Keyword.get(opts, :releases) do
      {:ok, map} when is_map(map) -> {:ok, map}
      map when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  # The container is swept before anything here reads what the compile will
  # (the trees, the native split, the hook scripts): whatever an untraced
  # step before it left running dies first, so nothing but the traced
  # compile can change those files until `Tracer.run/3` sweeps again after
  # it. A container that could not be shown clean runs no compile.
  defp traced_run(project_dir, package, opts, releases) do
    case Tracer.sweep(opts, :before) do
      :ok ->
        case not_fresh(Keyword.get(opts, :fresh, [])) do
          nil -> swept_run(project_dir, package, opts, releases)
          path -> not_run("a variant build path is not fresh: " <> path)
        end

      {:error, {_kind, detail}} = error ->
        detail
        |> sweep_problem()
        |> not_run()
        |> put_stat("tracer_error", tracer_error(error))
    end
  end

  # `fresh:` (a differential variant's build path, `Differential`): dirs that
  # must still be empty once the container is swept; the first that is not.
  # sobelow_skip ["Traversal.FileModule"]
  defp not_fresh(paths) do
    Enum.find(paths, fn path -> File.ls(path) != {:ok, []} end)
  end

  defp sweep_problem(procs) when is_list(procs), do: ProcessSweep.describe({:survivors, procs})
  defp sweep_problem(why), do: ProcessSweep.describe({:unavailable, why})

  defp swept_run(project_dir, package, opts, releases) do
    env = Keyword.fetch!(opts, :env)
    trace_dir = Keyword.get_lazy(opts, :trace_dir, fn -> default_trace_dir(project_dir) end)
    home = hex_home(opts, env)
    deps = deps_path(project_dir, env)

    {native, declassified, split_problem} =
      native_split(project_dir, deps, Keyword.put(opts, :package, package), releases, home)

    {trees_ms, {trees, tree_problem}} =
      timed(fn -> trees(project_dir, deps, opts, env, releases, home, native) end)

    hooks =
      hook_scripts(
        project_dir,
        env ++ Keyword.get(opts, :extra_env, []) ++ Keyword.get(opts, :late_env, [])
      )

    {compile_ms, traced} =
      timed(fn ->
        Tracer.run(project_dir, [package], tracer_opts(opts, env, trace_dir, native))
      end)

    # Read once here: the fetch below runs only when a probe `Declared`
    # decides was traced (round 3, R2-5).
    read = read_report(traced, trace_dir)

    # After the traced compile, so nothing it fetches is seen by it: the
    # modules of the dependencies the closure declares and lacks
    # (`Declared`, round-2 ruling 1).
    fetch_opts =
      [relevant: declared_relevant?(read)] ++
        Enum.map(Keyword.take(opts, [:declared_fetch]), fn {_, fun} -> {:fetch, fun} end)

    {fetch_ms, fetched} = timed(fn -> Declared.fetch(home, releases, env, fetch_opts) end)

    ctx_opts =
      [
        releases: releases,
        hex_home: home,
        declassified: declassified,
        trees: trees,
        hook_scripts: hooks,
        rebar_cache:
          rebar_cache(
            env ++ Keyword.get(opts, :extra_env, []) ++ Keyword.get(opts, :late_env, [])
          ),
        rebar_base:
          rebar_base(env ++ Keyword.get(opts, :extra_env, []) ++ Keyword.get(opts, :late_env, [])),
        deps_path: deps,
        build_path: build_path(project_dir, env)
      ] ++
        Keyword.take(opts, [
          :moved_deps,
          :target,
          :roots,
          :host_native,
          :foreign_priv,
          :native_side,
          :relocate,
          :holders,
          :differential
        ])

    project_dir
    |> verdict(package, traced, read, native, ctx_opts)
    |> unsplit(split_problem)
    |> unsplit(tree_problem)
    |> put_stat("judge_compile", judge_compile(traced))
    |> put_stat("trees_ms", trees_ms)
    |> put_stat("compile_ms", compile_ms)
    |> put_stat("declared_fetch", declared_fetch(fetched, fetch_ms))
    |> put_stat("tracer_error", tracer_error(traced))
    |> put_stat("makefile_rule2", makefile_rule2?(opts))
  end

  defp declared_fetch({:ok, %{fetched: fetched, failed: failed}}, ms),
    do: %{"fetched" => fetched, "failed" => failed, "ms" => ms}

  defp declared_fetch({:error, why}, ms), do: %{"error" => inspect(why, limit: 5), "ms" => ms}

  defp read_report({:ok, 0}, trace_dir), do: timed(fn -> Report.read(trace_dir) end)
  defp read_report(_traced, _trace_dir), do: nil

  defp declared_relevant?({_ms, report}),
    do: Enum.any?(all_events(report), &Probes.declared_relevant?/1)

  defp declared_relevant?(nil), do: false

  # Item 1 (behind `makefile_rule2: true`): the native list without the
  # dependencies whose native build file Mix never runs, which the judge
  # then holds to the manager the trace recorded (`declassified:`). The
  # `build_tools` come from each dependency's tarball verified against the
  # lock snapshot, never from `mix.lock` itself. `package:` is the package
  # under test, whose doc files do not count (`NativeBuild.split/4`, judge
  # revision 21), as in the static rules.
  # `NativeBuild.split/4` reads an unlistable `deps/` as no dependencies at
  # all; with the flag on that is a problem instead (fail closed), which
  # `unsplit/2` turns into could-not-judge once the compile is over. `deps`
  # is the dir the compile reads the dependencies from (`deps_path/2`).
  # sobelow_skip ["Traversal.FileModule"]
  defp native_split(project_dir, deps, opts, releases, home) do
    cond do
      not makefile_rule2?(opts) ->
        {native_deps(project_dir, deps), %{}, nil}

      match?({:ok, _}, File.ls(deps)) ->
        {native, declassified} =
          NativeBuild.split(
            project_dir,
            &Context.release_tarball(home, releases, &1),
            deps,
            Keyword.take(opts, [:package, :native_side])
          )

        {native, declassified, nil}

      true ->
        {[], %{}, "deps/ could not be listed for rule 2 (makefile_rule2)"}
    end
  end

  defp makefile_rule2?(opts), do: Keyword.get(opts, :makefile_rule2) == true

  @doc false
  # Public for tests. The sha256 of each reviewed rebar3 hook script
  # (`Rebar.reviewed_hooks/0`) under the compile's deps dir (`deps_path/2`
  # of `env`), taken before the compile, for the apps whose variable the
  # compile's `env` and this VM's environment (which the compile inherits)
  # both leave unset. A script that is not a regular file, or any set value,
  # even an empty one, leaves the app out: its hook then counts.
  @spec hook_scripts(String.t(), [{String.t(), String.t() | nil}]) :: %{String.t() => String.t()}
  def hook_scripts(project_dir, env) do
    deps = deps_path(project_dir, env)

    for {app, {file, var}} <- Rebar.reviewed_hooks(),
        System.get_env(var) == nil,
        not Enum.any?(env, &match?({^var, value} when is_binary(value), &1)),
        sha = regular_sha256(Path.join([deps, app, file])),
        sha != nil,
        into: %{},
        do: {app, sha}
  end

  @max_hook_script_bytes 1024 * 1024

  # sobelow_skip ["Traversal.FileModule"]
  defp regular_sha256(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_hook_script_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  @doc """
  Item 5e's tree snapshot (`NccWorker.Portability.Trees.snapshot/5`) of
  `project_dir` for `run/3`'s `trees:`, with the native list `run/3` would
  use for the same `opts` (`releases:`, `hex_home:` (default `HEX_HOME`),
  `makefile_rule2:`, `deps_path:`, the dependencies' dir, default
  `<project_dir>/deps`, and `package:`, the package `run/3` is given;
  without it the package's tree may be left unchecked). Take it before the
  first compile of the closure,
  right after the `deps.get` that fetched it: a compile writes into a
  dependency's own source dir (Mix's leex and yecc compilers put the `.erl`
  they generate in `src/`). Never raises; `%{}` (nothing checked) when it
  cannot be taken.
  """
  @spec tree_snapshot(String.t(), keyword()) :: %{String.t() => Trees.tree()}
  def tree_snapshot(project_dir, opts) do
    case releases(opts) do
      {:ok, releases} ->
        home = Keyword.get_lazy(opts, :hex_home, fn -> System.get_env("HEX_HOME") end)
        deps = Keyword.get(opts, :deps_path) || Path.join(project_dir, "deps")
        {native, _declassified, _problem} = native_split(project_dir, deps, opts, releases, home)
        Trees.snapshot(project_dir, releases, home, native, deps_path: deps)

      _ ->
        %{}
    end
  rescue
    _ -> %{}
  end

  @doc """
  `tree_snapshot/2` for a run whose first compile is still to come (the
  full run's, taken after `Project.add_package/3`'s `deps.get`), or `nil`
  when the build dir `env` names already holds one of the locked apps: some
  step compiled the closure before it (a `deps.get` hook such as Nerves 1's
  nerves_bootstrap), so the trees may already hold what that compile wrote
  (leex and yecc output in `src/`). `nil` passed on as `run/3`'s `trees:`
  is could-not-judge, as no `trees:` at all is once the closure is
  compiled, never a refusal. The trees are the ones under the dir `env`
  names for the dependencies (`MIX_DEPS_PATH`, else `deps/`). Never raises.
  """
  @spec first_tree_snapshot(String.t(), [{String.t(), String.t()}], keyword()) ::
          %{String.t() => Trees.tree()} | nil
  def first_tree_snapshot(project_dir, env, opts) do
    opts = Keyword.put(opts, :deps_path, deps_path(project_dir, env))

    case releases(opts) do
      {:ok, releases} ->
        if compiled_apps(project_dir, env, releases) == [],
          do: tree_snapshot(project_dir, opts)

      :error ->
        tree_snapshot(project_dir, opts)
    end
  rescue
    _ -> nil
  end

  # `run/3`'s trees: the caller's pre-compile snapshot (`trees:`, `:off` for
  # none), else (no `trees:`, or `nil`, `first_tree_snapshot/3`'s "too late")
  # one taken now, which is before any compile only when the build dir holds
  # none of the closure's apps; otherwise nothing is checked and the verdict
  # is could-not-judge (a snapshot after a compile would refuse what the
  # compile itself wrote). An app native now is never checked, whatever the
  # snapshot said.
  defp trees(project_dir, deps, opts, env, releases, home, native) do
    case Keyword.get(opts, :trees) do
      trees when is_map(trees) ->
        {Map.new(trees, fn {app, tree} -> {app, unless_native(app, tree, native)} end), nil}

      :off ->
        {%{}, nil}

      _none ->
        case compiled_apps(project_dir, env, releases) do
          [] ->
            {Trees.snapshot(project_dir, releases, home, native, deps_path: deps), nil}

          apps ->
            {%{},
             "no tree snapshot taken before the closure was compiled: " <>
               Enum.join(Enum.take(apps, 5), ", ")}
        end
    end
  end

  defp unless_native(app, tree, native),
    do: if(app in native, do: {:unverified, "native build"}, else: tree)

  # The dir the compile's env names for the dependencies (`MIX_DEPS_PATH`,
  # which a firmware target's build sets to `deps_<target>`), else the
  # project's `deps/`: where its trees, native build files and hook scripts
  # are read, as Mix reads them.
  defp deps_path(project_dir, env) do
    case env_value(env, "MIX_DEPS_PATH") do
      nil -> Path.join(project_dir, "deps")
      path -> Path.expand(path, project_dir)
    end
  end

  # The build path the compile writes (`MIX_BUILD_PATH`), `nil` when the env
  # names none: Mix's own default then depends on the env and target.
  defp build_path(project_dir, env) do
    case env_value(env, "MIX_BUILD_PATH") do
      nil -> nil
      path -> Path.expand(path, project_dir)
    end
  end

  # The locked apps the build dir the compile writes already holds an ebin of.
  # sobelow_skip ["Traversal.FileModule"]
  defp compiled_apps(project_dir, env, releases) do
    build =
      env_value(env, "MIX_BUILD_PATH") ||
        Path.join([project_dir, "_build", env_value(env, "MIX_ENV") || "dev"])

    releases
    |> Map.keys()
    |> Enum.sort()
    |> Enum.filter(&File.dir?(Path.join([build, "lib", &1, "ebin"])))
  end

  @doc false
  # Public for tests: a finished compile's verdict is not passed when
  # `native_split/5` could not list `deps/`.
  @spec unsplit(verdict(), String.t() | nil) :: verdict()
  def unsplit(verdict, nil), do: verdict

  def unsplit(%{observations: obs} = verdict, problem) do
    %{
      verdict
      | status: :skip,
        reason: Reasons.could_not_judge(),
        observations: Map.put(obs, "problems", [problem | Map.get(obs, "problems") || []])
    }
    |> Map.put(:compile_env, nil)
    |> Map.put(:compile_inputs, nil)
    |> ForeignPriv.unpass()
  end

  defp judge_compile({:ok, 0}), do: "finished"
  defp judge_compile(_traced), do: "not_finished"

  defp timed(fun) do
    started = System.monotonic_time(:millisecond)
    result = fun.()
    {System.monotonic_time(:millisecond) - started, result}
  end

  # Short and stable, for `trace_stats` and for callers that tell a compile
  # that left processes behind from one that merely failed. `Tracer.run/3`
  # already turns exits 124 and 137 into `:timeout` and `:killed`.
  defp tracer_error({:ok, 0}), do: nil
  defp tracer_error({:ok, status}) when is_integer(status), do: "exit_#{status}"
  defp tracer_error({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)

  defp tracer_error({:error, reason}) when is_tuple(reason) and is_atom(elem(reason, 0)),
    do: Atom.to_string(elem(reason, 0))

  defp tracer_error(_other), do: "other"

  defp default_trace_dir(project_dir), do: Path.join(Path.dirname(project_dir), "trace")

  defp hex_home(opts, env) do
    case Keyword.get(opts, :hex_home) do
      home when is_binary(home) -> home
      _ -> env_value(env, "HEX_HOME")
    end
  end

  defp env_value(env, name) do
    case List.keyfind(env, name, 0) do
      {_, value} when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp tracer_opts(opts, env, trace_dir, native) do
    [
      trace_dir: trace_dir,
      native: native,
      env: env,
      log_file: Keyword.get(opts, :log_file),
      timeout_ms: Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      extra_env: Keyword.get(opts, :extra_env, []),
      run_started_at: Keyword.get(opts, :run_started_at),
      mode: Keyword.get(opts, :mode, :judge)
    ] ++
      Keyword.take(opts, [
        :reap,
        :cmd,
        :wrapper,
        :argv,
        :late_env,
        :sweep,
        :window_sweep,
        :holders,
        :plain_args
      ])
  end

  defp verdict(project_dir, package, {:ok, 0}, {report_ms, report}, native, ctx_opts) do
    {judge_ms, verdict} =
      timed(fn ->
        judge(project_dir, package, report, native, ctx_opts ++ [built_check: true])
      end)

    verdict
    |> put_stat("report_over_budget", report.over_budget)
    |> put_stat("trace_mode", Atom.to_string(Report.mode(report)))
    |> put_stat("report_ms", report_ms)
    |> put_stat("judge_ms", judge_ms)
  end

  defp verdict(_project_dir, _package, {:ok, status}, _trace_dir, _native, _ctx_opts),
    do: not_judged("traced compile exited #{inspect(status)}")

  defp verdict(_project_dir, _package, {:error, :window_sweep_failed}, _dir, _native, _ctx),
    do:
      not_judged("processes left running in a window of the traced compile could not be stopped")

  defp verdict(_project_dir, _package, {:error, {:sweep_survived, procs}}, _dir, _native, _ctx),
    do: not_judged("after the traced compile: " <> sweep_problem(procs))

  defp verdict(_project_dir, _package, {:error, {:sweep_unavailable, why}}, _dir, _native, _ctx),
    do: not_judged("after the traced compile: " <> sweep_problem(why))

  defp verdict(_project_dir, _package, {:error, reason}, _trace_dir, _native, _ctx_opts),
    do: not_judged("tracer: " <> inspect(reason, limit: 20))

  defp verdict(_project_dir, _package, other, _trace_dir, _native, _ctx_opts),
    do: not_judged("tracer: " <> inspect(other, limit: 20))

  defp not_judged(why),
    do: %{status: :skip, reason: Reasons.could_not_judge(), observations: %{"problems" => [why]}}

  defp put_stat(%{observations: obs} = verdict, key, value) do
    stats = Map.get(obs, "trace_stats") || %{}
    %{verdict | observations: Map.put(obs, "trace_stats", Map.put(stats, key, value))}
  end

  @doc """
  The dependencies under `deps/` (or `deps`, the dir the compile reads them
  from) that build native code or read the target (spec R3 native taint).
  """
  @spec native_deps(String.t(), String.t() | nil) :: [String.t()]
  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  def native_deps(project_dir, deps \\ nil) do
    deps = deps || Path.join(project_dir, "deps")

    case File.ls(deps) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reject(&BuildCache.dep_target_agnostic?(deps, &1))

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Judges one read trace. `opts` go to `Context.build/5` (`releases:`,
  `hex_home:`); without them the context reads the project's `mix.lock` and
  this process's `HEX_HOME` now, which only tests should rely on.
  Every closure dependency's build dir must also match the digest the tracer
  took when its window closed, all of them recomputed within
  `built_budget_ms:` (default 5 minutes; `built_clock:` for tests);
  `built_check: false` turns that off for a hand-built report with no
  `built` lines (`run/3` always checks). `declassified:` is what
  `NativeBuild.split/2` declassified (`%{app => manager}`, item 1, default
  none): each such dependency in the package's closure must have been built
  by that manager, as the trace's closure line records. `trees:` is the
  `NccWorker.Portability.Trees.snapshot/5` taken before the compile (item
  5e, default none, so no tree is checked): a closure dependency whose tree
  differed from its tarball refuses, and the files and listings the compile
  read are re-checked. The verdict's
  `manager` is the package's own manager from that line (nil when unknown).
  Never raises.
  """
  @spec judge(String.t(), String.t(), Report.t(), [String.t()], keyword()) :: verdict()
  def judge(project_dir, package, report, native, opts \\ [])

  def judge(project_dir, package, %Report{} = report, native, opts) do
    Context.with_link_cache(fn ->
      facts = facts(project_dir, package, report, native, opts)

      if target(opts),
        do: target_verdict_of(facts),
        else:
          facts
          |> verdict_of()
          |> put_stat("native_side", on_off(native_side?(opts)))
          |> put_stat("relocate", on_off(Relocate.enabled(opts) != false))
    end)
  rescue
    e -> not_judged("judge failed: " <> Exception.message(e))
  catch
    kind, reason -> not_judged("judge failed: #{kind} #{inspect(reason, limit: 20)}")
  end

  def judge(_project_dir, _package, other, _native, _opts),
    do: not_judged("not a trace report: " <> inspect(other, limit: 5))

  # --- gathering ---------------------------------------------------------------

  # Read only when a probe it decides was traced: the declared-absent
  # dependencies' tarballs are parsed for their modules.
  defp declared(ctx, report) do
    if Enum.any?(all_events(report), &Probes.declared_relevant?/1),
      do: Declared.index(ctx),
      else: ctx.declared
  end

  defp all_events(report),
    do:
      Stream.concat(report.events, Stream.flat_map(report.children, fn {_app, c} -> c.events end))

  defp facts(project_dir, package, report, native, opts) do
    ctx = Context.build(project_dir, package, report, native, opts)
    scope = MapSet.new(Context.closure_of(ctx, ctx.package))
    gate = ForeignPriv.gate(ctx, scope, opts)

    ctx = %{
      ctx
      | foreign_priv: gate,
        declared: declared(ctx, report),
        differential: differential?(opts)
    }

    side = side_mode(opts, ctx, scope, native)

    {decided, guarded_tags} =
      decide_all(report, ctx, scope, target_mode(opts, ctx, scope, native), side)

    decided = tool_events(decided, ctx.package)

    host_native = host_native?(opts)
    # A probe's text names its window (`keep/3`); the portal's reason cause
    # leaves the owner out (`Compatibility.Portability.unowned/1`).
    unjudged = for {_owner, {:unjudged, why}} <- decided, do: why
    decided = for {owner, decision} <- decided, in_scope?(owner, scope), do: {owner, decision}

    libs =
      mapped_libs(
        report,
        ctx,
        scope,
        Keyword.get_lazy(opts, :nif_waiver, &MappedLibs.waived?/0),
        host_native
      )

    decided = decided ++ libs.decided
    elixir = elixir_of(report)

    config =
      ConfigReads.judge(
        decided,
        elixir,
        report.config_env,
        ConfigReads.trees(ctx),
        ctx.nested,
        ConfigReads.app_defaults(ctx)
      )

    version =
      ElixirVersion.judge(
        decided,
        elixir,
        ElixirVersion.reviewed_apps(elem(ctx.hex, 1), ctx.trees)
      )

    decided =
      (decided ++ config.refusals ++ version.refusals)
      |> own_priv_reads(ctx)
      |> own_tree_copies(ctx)

    {decided, settled} = ForeignPriv.settle(decided, ctx)

    package_r2 = package_build_root(ctx)

    # A firmware target's or host-native verdict refuses on any refusal of
    # the closure (`target_verdict_of/1`): no taint is waived there.
    waivers = if target(opts), do: %{}, else: Guarded.waivers(ctx, report, guarded_tags)

    {decided, deps} =
      dep_results(ctx, report, decided, libs, {target(opts) != nil, side != nil}, waivers)

    {package_rebar, package_inputs} = rebar(ctx, report, ctx.package)
    rebar_inputs = Enum.uniq(package_inputs ++ Enum.flat_map(deps, &elem(&1, 1).inputs))
    endian = endian_of(report)
    os_type = os_type_of(report)

    %{
      ctx: ctx,
      scope: scope,
      report: report,
      decided: decided,
      config: config,
      inputs:
        CompileInputs.build(
          decided,
          config.inputs ++ rebar_inputs,
          endian,
          os_type,
          Keyword.take(opts, [:roots, :target])
        ),
      trace_problems:
        trace_problems(report, ctx) ++
          built_problems(ctx, report, opts, settled.exclude) ++
          unjudged ++
          libs.problems ++
          config.problems ++
          version.problems ++
          endian_problems(decided, endian) ++ os_type_problems(decided, os_type),
      libs: libs,
      plugins: plugin_record(ctx, scope),
      package_window: window_problem(report, ctx.package),
      guarded: waivers,
      package_r2: package_r2,
      package_rebar: package_rebar,
      deps: deps,
      manager_mismatch: manager_mismatch(ctx, scope, Keyword.get(opts, :declassified, %{})),
      tree_refusal: tree_refusal(ctx, scope),
      native_output: if(target(opts), do: native_output(ctx, scope)),
      host_native: host_native,
      relocate: Relocate.enabled(opts),
      slots: Relocate.slots(ctx, opts),
      foreign: %{
        stat: ForeignPriv.stat(opts, gate),
        gate: gate,
        flag: Keyword.get(opts, :foreign_priv) == true,
        entries: settled.entries,
        exclude: settled.exclude
      }
    }
  end

  # A firmware target's trace (`target_inputs/3`) sets the native build
  # tool's own activity apart, and `make` is no process the tracer follows:
  # what the native build wrote, from inputs nobody records (its own reads
  # of the environment, the Nerves system's headers), is no event, and
  # both builds wrote the same, so binding the published beams to the
  # trace's (`NccWorker.FirmwareInputs`) cannot tell. Nothing it wrote may
  # reach the package's beams: every natively built closure dependency's
  # source tree must still be exactly its verified tarball's after the
  # compile (`tree_clean?/2`: no source generated there for the compile to
  # read or compile, which the trees checked before it never covered), and
  # every beam in the package's ebin compiled from a file in its source
  # dir (`compiled_in?/2`: no module the native build put there).
  defp native_output(ctx, scope) do
    native =
      scope |> Enum.filter(&(Context.dep?(ctx, &1) and ctx.deps[&1].native?)) |> Enum.sort()

    Enum.find_value(native, fn app ->
      unless tree_clean?(ctx, app),
        do: "natively built dependency's source tree is not its verified tarball's: #{app}"
    end) || foreign_beam(ctx)
  end

  defp foreign_beam(ctx) do
    with ebin when is_binary(ebin) <- Context.ebin(ctx, ctx.package),
         dest when is_binary(dest) <- Context.dest(ctx, ctx.package) do
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.find_value(&foreign_beam(&1, dest))
    else
      _ -> "no build of the package to check its beams' sources"
    end
  end

  defp foreign_beam(beam, dest) do
    unless compiled_in?(beam, dest),
      do: "beam not compiled from the package's own sources: #{Path.basename(beam)}"
  end

  # The source a beam's compile info names: a regular file under `dest`.
  # sobelow_skip ["Traversal.FileModule"]
  defp compiled_in?(beam, dest) do
    with {:ok, {_module, [compile_info: info]}} <-
           :beam_lib.chunks(String.to_charlist(beam), [:compile_info]),
         source when is_list(source) <- Keyword.get(info, :source),
         real when is_binary(real) <- Context.realpath(List.to_string(source)) do
      Context.under?(real, dest) and File.regular?(real)
    else
      _ -> false
    end
  end

  # Item 5e: a closure dependency whose source tree was not its verified
  # tarball's before the compile refuses, the first by app name.
  defp tree_refusal(ctx, scope) do
    ctx.trees
    |> Enum.sort()
    |> Enum.find_value(fn
      {app, {:differs, detail}} ->
        if MapSet.member?(scope, app), do: Reasons.tree_differs() <> "#{app} (#{detail})"

      _ ->
        nil
    end)
  end

  # Item 1: a closure dependency rule 2 took off the native list because its
  # verified tarball's `build_tools` and its files say Mix runs mix or
  # rebar3 must have been built by exactly that manager, as the trace's
  # closure line records Mix's own answer. Another manager, or none recorded, refuses: its Makefile may
  # have run.
  defp manager_mismatch(ctx, scope, declassified) do
    declassified
    |> Enum.sort()
    |> Enum.find_value(fn {app, computed} ->
      traced = Context.manager(ctx, app)

      if MapSet.member?(scope, app) and traced != computed,
        do:
          Reasons.manager_mismatch() <>
            "#{app} (trace #{traced || "none"}, tarball #{computed})"
    end)
  end

  # The byte order the traced compile ran with: the one every VM's start
  # line names (the Mix VM's and each child's), else nil. A child VM runs on
  # the same machine, so a disagreement or a missing value means the trace
  # cannot say what a byte-order read returned.
  defp endian_of(%Report{start: start, children: children}) do
    values = [start | Enum.map(children || %{}, fn {_app, child} -> child.start end)]

    case values |> Enum.map(&endian_value/1) |> Enum.uniq() do
      [endian] when endian in ["little", "big"] -> endian
      _ -> nil
    end
  end

  defp endian_value(%{"endian" => endian}), do: endian
  defp endian_value(_start), do: nil

  # A byte-order read the build cannot value is could-not-judge (step 1):
  # `CompileInputs` would record it as `config_unrecorded`, a miss for every
  # client, so the trace is the one at fault.
  defp endian_problems(decided, endian) do
    read? = Enum.any?(decided, &match?({_owner, {:observe, "endian_reads", _}}, &1))
    if read? and endian == nil, do: ["byte order read but not recorded by the tracer"], else: []
  end

  # The OS type the traced compile ran with, `[family, name]`: the one every
  # VM's start line names, else nil, as for the byte order.
  defp os_type_of(%Report{start: start, children: children}) do
    values = [start | Enum.map(children || %{}, fn {_app, child} -> child.start end)]

    case values |> Enum.map(&os_type_value/1) |> Enum.uniq() do
      [[family, name] = os_type] ->
        if family in Compatibility.CompileInputs.os_families() and
             Compatibility.CompileInputs.os_name?(name),
           do: os_type,
           else: nil

      _ ->
        nil
    end
  end

  defp os_type_value(%{"os_type" => os_type}), do: os_type
  defp os_type_value(_start), do: nil

  defp os_type_problems(decided, os_type) do
    read? = Enum.any?(decided, &match?({_owner, {:observe, "os_type_reads", _}}, &1))
    if read? and os_type == nil, do: ["OS type read but not recorded by the tracer"], else: []
  end

  defp elixir_of(%Report{start: %{"elixir" => elixir}}) when is_binary(elixir), do: elixir
  defp elixir_of(_report), do: nil

  # Every event as `{owner, decision}`: the Mix VM's by `Context.owner/2`,
  # a closure dependency's child VM's by its app (child clocks do not align
  # with the Mix VM's windows). One `MixExsSlice.analyse/1` per `mix.exs`.
  # Each VM's events are decided with that VM's own ensure_loaded probes
  # (`Context.ensured`): pids and times mean nothing in another VM.
  defp decide_all(report, ctx, scope, target_mode, side) do
    main = for event <- report.events, do: {Context.owner(ctx, event), event}

    children =
      for {app, child} <- Enum.sort(report.children),
          Context.dep?(ctx, app),
          do: {"child:" <> app, for(event <- child.events, do: {app, event})}

    vms = [{"main", main} | children]
    owned = Enum.flat_map(vms, &elem(&1, 1))
    slices = Events.mix_exs_slices(ctx, Enum.reject(owned, &match?({:quiet, _}, &1)))

    decided =
      for {vm_name, vm} <- vms,
          vm_ctx = %{ctx | ensured: Probes.ensured(vm)},
          {owner, event} <- vm,
          decision =
            event
            |> Events.decide(vm_ctx, owner, slices)
            |> in_vm(vm_name)
            |> targeted(event, vm_name, target_mode)
            |> sided(event, owner, vm_name, side),
          kept = keep(owner, decision, scope),
          kept != nil,
          do: {kept, guarded_site(kept, event, vm_ctx)}

    # Every refusal with the reviewed guarded site it came from, if any
    # (`Guarded`, coverage drop 2026-11-22, F4).
    tags = for {{owner, {:refuse, reason}}, site} <- decided, do: {owner, reason, site}
    {Enum.map(decided, &elem(&1, 0)), tags}
  end

  defp guarded_site({owner, {:refuse, _reason}}, event, ctx) when is_binary(owner),
    do: Guarded.site(event, ctx, owner)

  defp guarded_site(_kept, _event, _ctx), do: nil

  # Env reads and writes keep the VM they were made in: timestamps compare
  # only within one VM (`CompileInputs`). So does a read of a natively built
  # dependency's beam, which only the Mix VM's clock orders against that
  # dependency's window (`beam_read/5`).
  defp in_vm({:observe, kind, item}, vm)
       when kind in ["env_reads", "env_writes", "native_beam_reads"],
       do: {:observe, kind, Map.put(item, "vm", vm)}

  defp in_vm(decision, _vm), do: decision

  # --- a firmware target's inputs ---------------------------------------------

  # The reviewed native build tools (`target_inputs/3`): a Mix compiler that
  # runs the package's native build, whose own host reads decide only what
  # that build writes to `priv`, which the target's system and toolchain
  # match covers. Each needs its modules named by its own `.app` and by no
  # other closure application's.
  @native_tools ["elixir_make"]

  # A host-native build (`host_native: true`, design addendum for #85) also
  # sets apart rustler_precompiled: its own code reads the target triple and
  # the NIF version, downloads the archive its package's checksum file pins
  # and writes the NIF into the package's priv, all of which the build's
  # triple, NIF version and `Compatibility.NifOrigin` check cover. A package
  # fun it runs (a variant's CPU probe) is the package's and is not set apart.
  @host_native_tools ["rustler_precompiled"]

  # The tool's entry points a host-native package's own code calls: `use
  # RustlerPrecompiled` expands the macro and calls `__using__/2` from the
  # package's module body. A call into any other of the tool's functions
  # stays the `native_closure` refusal it is everywhere else.
  @host_native_entries MapSet.new([
                         "RustlerPrecompiled.MACRO-__using__/2",
                         "RustlerPrecompiled.__using__/2"
                       ])

  # Judge revision 25. The tool's macro returns a quote whose
  # `{:force_build, only_rustler_opts}` branch is `use Rustler,
  # only_rustler_opts` whenever Rustler is loaded (a closure that has the
  # optional rustler), so the expander calls Rustler's macro while it
  # expands that quote, whichever branch the module body then takes.
  # Rustler's `__using__/2` (rustler 0.37, 0.38) is a `bind_quoted` quote:
  # calling it reads nothing and runs nothing. What it returns runs only in
  # the force-build branch, and then calls `Rustler.Compiler.compile_crate/3`
  # from the package's module body and Rustler's `__before_compile__/2`,
  # which keep their refusal. `tool_events/2` lets one such expansion
  # through per tool macro before it, in the package's own window and the
  # same process.
  @tool_macro "RustlerPrecompiled.MACRO-__using__/2"
  @host_native_expansions MapSet.new(["Rustler.MACRO-__using__/2"])
  @expanded_tools ["rustler"]

  # Judge revision 25. The tool's `download_or_reuse_nif_file/2` unpacks the
  # archive it downloaded with `:erl_tar.extract({:binary, tar_gz},
  # [:compressed, ...])`, which opens a port to OTP's ram_file driver
  # (`ram_file:ll_open/3`): a driver linked into the VM that holds the
  # archive in memory, runs no program and reads nothing of the host. Only
  # that port, opened by OTP's own `ram_file`, right under that function of
  # the tool, in the package's own window (`tool_events/2`); any other port
  # or program from the tool's frame keeps its refusal. OTP's zlib is a NIF
  # and opens no port. Unpacking a cached archive instead spawns
  # `raw_file_io_inflate`, whose read of the archive no tool frame owns, so
  # a build that reuses a cached archive stays refused.
  @reviewed_unpacks [{"Elixir.RustlerPrecompiled", "download_or_reuse_nif_file", 2}]
  @ram_file_port ~s({spawn,"ram_file_drv"})

  # What a host-native tool's own frame may read of the machine and still be
  # set apart: the target triple, the NIF version and the OTP release it
  # picks the archive by, and the OS type. Any other OS identity read or a
  # program run from its frame (but `@reviewed_unpacks`' ram_file port)
  # keeps its refusal: a package fun the tool runs that tail-calls one (a
  # variant's CPU probe ending in `:os.version/0`) leaves the tool's frame
  # on top, and what it reads would pick a NIF the triple does not cover.
  @host_tool_reads ~w(system_architecture nif_version otp_release version wordsize os_type)

  @tool_never_writes ["env_write", "config_write"]

  # The env a host-native tool reads that overrides the triple it picks the
  # NIF by: rustler_precompiled's `maybe_override_with_env_vars/2` (set for
  # a cross build, Nerves's or by hand). Each read is the `compile_inputs`
  # item a package's own read is (unset on a builder, so a client that sets
  # one misses), not set apart. Its other env reads (proxies, cache dirs,
  # CA certs, the IP family) choose only how the checksum-pinned archive is
  # fetched.
  @tool_env_inputs ~w(TARGET_ARCH TARGET_VENDOR TARGET_OS TARGET_ABI)

  @doc "The native build tools whose activity a firmware target's trace sets apart."
  @spec native_tools() :: [String.t()]
  def native_tools, do: @native_tools

  @doc "The native build tools a host-native build's trace also sets apart."
  @spec host_native_tools() :: [String.t()]
  def host_native_tools, do: @host_native_tools

  defp target(opts), do: Keyword.get(opts, :target)

  # Only in target mode: a host-native build is a target build for the
  # host's own triple.
  defp host_native?(opts), do: target(opts) != nil and Keyword.get(opts, :host_native) == true

  defp tools(opts),
    do: if(host_native?(opts), do: @native_tools ++ @host_native_tools, else: @native_tools)

  # --- a natively built dependency's native side ------------------------------

  # The reviewed native build tools whose own activity in a closure
  # dependency's window `native_side: true` sets apart on the toolchain
  # judge: elixir_make's Mix compiler, and cc_precompiler, the precompiler
  # elixir_make calls to pick and fetch the NIF (`make_precompiler:`). What
  # their own code reads (the OS type, the architecture, the NIF version,
  # the env, `priv`, their cache dir, the network) and runs (`make`) decides
  # only the native files the dependency's build writes, which no
  # dependent's compile may read: a call into the dependency, a read of its
  # `priv` or of any file but a beam in its build dir keeps its refusal. A
  # precompiler of the dependency's own is its own code, not set apart.
  @side_tools ["elixir_make", "cc_precompiler"]

  # Review M3. A tool is trusted by the Hex package the lock resolved for its
  # app, never by the app name alone (`{:elixir_make, "~> 1.0", hex: :other}`
  # names any package so), and only in the versions whose sources were
  # reviewed for what they read, write and run: the same surface from
  # elixir_make 0.7.8 to 0.10.1 and cc_precompiler 0.1.10 to 0.1.11. A
  # pre-release matches no range.
  @side_tool_versions %{
    "elixir_make" => ">= 0.7.8 and <= 0.10.1",
    "cc_precompiler" => ">= 0.1.10 and <= 0.1.11"
  }

  defp native_side?(opts), do: target(opts) == nil and Keyword.get(opts, :native_side) == true

  defp on_off(true), do: "on"
  defp on_off(false), do: "off"

  # nil unless `native_side: true` on the toolchain judge (a firmware
  # target's trace sets the tool apart already, `target_mode/4`); else the
  # tools' modules, as `target_mode/4` takes them: none unless the tracer
  # put call patterns on every tool in the closure (each on the native
  # list), so that a dependency's own call into one is an event of its own,
  # and none unless every tool in the closure is a reviewed release
  # (`reviewed_tools?/2`).
  defp side_mode(opts, ctx, scope, native) do
    if native_side?(opts) do
      tools =
        if reviewed_tools?(ctx, scope),
          do: tool_modules(ctx, scope, native, @side_tools),
          else: MapSet.new()

      %{tool_modules: tools, package: ctx.package}
    end
  end

  defp reviewed_tools?(%Context{hex: {_home, releases}}, scope) when is_map(releases),
    do:
      Enum.all?(@side_tools, fn tool ->
        not MapSet.member?(scope, tool) or reviewed_release?(tool, Map.get(releases, tool))
      end)

  defp reviewed_tools?(_ctx, _scope), do: false

  defp reviewed_release?(tool, %{name: tool, version: version}) when is_binary(version) do
    case Version.parse(version) do
      {:ok, parsed} ->
        Version.match?(parsed, Map.fetch!(@side_tool_versions, tool), allow_pre: false)

      :error ->
        false
    end
  end

  defp reviewed_release?(_tool, _release), do: false

  # A closure dependency's window only, never the package's: the package's
  # own native files are what it would publish. Every event of the
  # dependency's own code, and every event outside its windows, keeps its
  # decision, and so does a package fun the tool runs.
  defp sided(decision, _event, _owner, _vm, nil), do: decision
  defp sided({:unjudged, _} = decision, _event, _owner, _vm, _side), do: decision
  defp sided(:ignore, _event, _owner, _vm, _side), do: :ignore

  defp sided(decision, event, owner, vm, %{tool_modules: tools, package: package}) do
    if is_binary(owner) and owner != package and tool_event?(event, tools) and
         not package_fun_frame?(event),
       do: side_decision(decision, event, vm),
       else: decision
  end

  # As in a firmware target's trace (`tool_decision/4`): an integrity call
  # keeps its refusal, and a write to the env or the application env from
  # the tool's frame refuses (a value it hands the dependency's own compile
  # of its beams); anything else is `native_build`.
  defp side_decision(decision, event, vm) do
    cond do
      event["channel"] == "integrity" -> decision
      event["channel"] in @tool_never_writes -> tool_write_refusal(event)
      true -> native_build(event, vm)
    end
  end

  defp tool_write_refusal(event),
    do: {:refuse, "compile-time write from the native build tool's frame: #{event["mfa"]}"}

  # nil outside target mode; else the native tools' modules (strings, as
  # the tracer names them). A tool is set apart only when the tracer put call
  # patterns on its modules (it is in `native`): then every call the
  # package's own code makes into it is an event of its own, which refuses.
  # A tool in the closure that is not traced so sets nothing apart.
  defp target_mode(opts, ctx, scope, native) do
    if target(opts) do
      tools = tool_modules(ctx, scope, native, tools(opts))
      host_native = host_native?(opts)
      entries = if host_native, do: @host_native_entries, else: MapSet.new()

      host_tools =
        if host_native and MapSet.size(tools) > 0,
          do: traced_tool_modules(ctx, scope, @host_native_tools),
          else: MapSet.new()

      expanded =
        if MapSet.size(host_tools) > 0,
          do: traced_tool_modules(ctx, scope, @expanded_tools),
          else: MapSet.new()

      %{
        tool_modules: tools,
        entries: entries,
        host_tools: host_tools,
        expanded: expanded,
        host_native: host_native
      }
    end
  end

  defp tool_modules(ctx, scope, native, tools) do
    if Enum.any?(tools, &(MapSet.member?(scope, &1) and &1 not in native)),
      do: MapSet.new(),
      else: traced_tool_modules(ctx, scope, tools)
  end

  defp traced_tool_modules(ctx, scope, tool_apps) do
    listed =
      for app <- scope,
          Context.dep?(ctx, app),
          into: %{},
          do: {app, Context.app_modules(ctx, app)}

    {tools, others} = Enum.split_with(listed, fn {app, _mods} -> app in tool_apps end)
    other = others |> Enum.map(&elem(&1, 1)) |> Enum.reduce(MapSet.new(), &MapSet.union/2)

    tools
    |> Enum.map(&elem(&1, 1))
    |> Enum.reduce(MapSet.new(), &MapSet.union/2)
    |> MapSet.difference(other)
  end

  # In target mode, what a native tool's own code did is `native_build`
  # (never an input, never a refusal), and a target read is `target_reads`
  # (a `mix_target` input the client compares). An unjudged event stays
  # unjudged. What the tool's own code never does is not set apart: a
  # package fun the tool runs (elixir_make's `make_env` and `versions` funs,
  # a precompiler's callbacks, the `checksum.exs` it evaluates) that
  # tail-calls a wrapper (`System.put_env/2`, `Process.info/1`) leaves the
  # tool's frame first, so an integrity call keeps its refusal and a write
  # to the environment or the application env refuses.
  defp targeted(decision, _event, _vm, nil), do: decision
  defp targeted({:unjudged, _} = decision, _event, _vm, _mode), do: decision
  defp targeted(:ignore, _event, _vm, _mode), do: :ignore

  defp targeted(decision, event, vm, %{tool_modules: tools} = mode) do
    if tool_event?(event, tools) and not package_fun_frame?(event),
      do: tool_decision(decision, event, vm, mode),
      else: package_decision(decision, event, vm, mode)
  end

  # The tool frames that run nothing of the tool's own but a package fun
  # (`@package_fun_frames`): rustler_precompiled's `variant_suffix/2` calls
  # each of the package's variant funs from a callback that tail-calls it,
  # so a variant fun that tail-calls a read (`fn -> System.get_env("X")
  # end`, `fn -> File.exists?(path) end`) leaves that frame first, and what
  # it reads picks the NIF. Such a read is the package's, as it would be with
  # the fun's own frame on top.
  @package_fun_frames [{"Elixir.RustlerPrecompiled", "variant_suffix", 2}]

  defp package_fun_frame?(%{"user" => %{"module" => module, "function" => fun}})
       when is_binary(module) and is_binary(fun),
       do: Enum.any?(@package_fun_frames, &package_fun_frame?(&1, module, fun))

  defp package_fun_frame?(_event), do: false

  defp package_fun_frame?({module, name, arity}, module, fun),
    do: fun == name or String.starts_with?(fun, "-#{name}/#{arity}-")

  defp package_fun_frame?(_frame, _module, _fun), do: false

  defp package_decision(decision, event, vm, mode) do
    cond do
      target_read?(event) and match?({:refuse, _}, decision) ->
        {:observe, "target_reads", %{"mfa" => event["mfa"], "ts" => event["ts"], "vm" => vm}}

      own_priv?(decision) ->
        {:refuse, elem(decision, 2)["refusal"]}

      tool_entry?(event, mode) ->
        event |> native_build(vm) |> entry_pid(event)

      tool_expansion?(event, mode) ->
        held("tool_expansions", event, vm, decision)

      true ->
        decision
    end
  end

  # An event `tool_events/2` settles once every event is decided, with the
  # decision it keeps when it is not let through.
  defp held(kind, event, vm, decision),
    do:
      {:observe, kind,
       %{
         "mfa" => event["mfa"],
         "module" => user_module(event),
         "ts" => event["ts"],
         "vm" => vm,
         "pid" => event["pid"],
         "decision" => decision
       }}

  # The tool macro's process, which `tool_events/2` pairs Rustler's
  # expansion with and then drops.
  defp entry_pid({:observe, kind, item}, %{"mfa" => @tool_macro, "pid" => pid})
       when is_binary(pid),
       do: {:observe, kind, Map.put(item, "pid", pid)}

  defp entry_pid(decision, _event), do: decision

  # A firmware target's trace has no second build (`PrivRepro`), so the
  # package's own priv writes and the probes above that priv refuse there
  # as they did before judge revision 21, and a foreign priv write (never
  # observed there: the gate stays closed in target mode).
  defp own_priv?({:observe, kind, %{"refusal" => refusal}})
       when kind in ["priv_writes", "priv_probes", "foreign_priv"] and is_binary(refusal),
       do: true

  defp own_priv?(_decision), do: false

  # An event of a native tool's own code.
  defp tool_decision(decision, event, vm, mode) do
    cond do
      event["channel"] == "integrity" ->
        decision

      event["channel"] in @tool_never_writes ->
        tool_write_refusal(event)

      host_tool?(event, mode) and reviewed_unpack?(event) ->
        held("tool_unpacks", event, vm, decision)

      kept?(event, mode) ->
        decision

      true ->
        native_build(event, vm)
    end
  end

  # A native tool's own event that keeps the decision it had instead of being
  # set apart: a host-native tool's read of the env that overrides its
  # triple, an unreviewed host read, and in a host-native build a config read.
  defp kept?(event, mode),
    do:
      (host_tool?(event, mode) and tool_env_input?(event)) or
        unreviewed_host_read?(event, mode) or tool_config_read?(event, mode)

  defp native_build(event, vm),
    do:
      {:observe, "native_build",
       %{"mfa" => event["mfa"], "module" => user_module(event), "ts" => event["ts"], "vm" => vm}}

  # The tool's own code (its frame is the topmost one that is not the
  # toolchain's), or Mix's task runner calling into it with no package frame
  # on the stack (Mix running its compiler). A call the package's own code
  # makes into it has the package's frame on top and is not the tool's.
  defp tool_event?(event, tools) do
    case user_module(event) do
      nil -> MapSet.member?(tools, mfa_module(event["mfa"]) || "") and run_by_mix?(event)
      module -> MapSet.member?(tools, module)
    end
  end

  defp run_by_mix?(%{"caller" => %{"module" => "Elixir.Mix.Task", "function" => fun}})
       when is_binary(fun),
       do: String.starts_with?(fun, "-run_task/")

  defp run_by_mix?(_event), do: false

  # A host-native package's own call into a reviewed tool's entry point
  # (`@host_native_entries`), when the tool's modules are set apart.
  defp tool_entry?(%{"channel" => "native_closure", "mfa" => mfa}, %{entries: entries} = mode)
       when is_binary(mfa),
       do: MapSet.member?(entries, mfa) and MapSet.member?(mode.tool_modules, mfa_module(mfa))

  defp tool_entry?(_event, _mode), do: false

  # The expander calling Rustler's macro (`@host_native_expansions`): the
  # call is made by `elixir_dispatch:expand_macro_fun/7` with no frame of
  # any package on the stack, so it expands code (a quote the tool's macro
  # returned); a call the package's own code makes, or a call into any
  # other of Rustler's functions, is not one. Only a module rustler's own
  # `.app` lists.
  defp tool_expansion?(
         %{
           "channel" => "native_closure",
           "mfa" => mfa,
           "extent" => "dispatcher",
           "user" => nil,
           "caller_kind" => "toolchain",
           "caller" => %{"module" => "elixir_dispatch", "function" => "expand_macro_fun"},
           "pid" => pid
         },
         %{expanded: expanded}
       )
       when is_binary(mfa) and is_binary(pid),
       do:
         MapSet.member?(@host_native_expansions, mfa) and
           MapSet.member?(expanded, mfa_module(mfa))

  defp tool_expansion?(_event, _mode), do: false

  # Judge revision 25, in the package's own window only (where the tool
  # picks and unpacks the NIF the build serves): a Rustler expansion
  # (`@host_native_expansions`) needs a tool macro (`@tool_macro`) before it
  # in the same VM and process that no other expansion took, and the ram_file
  # port (`@reviewed_unpacks`) nothing more; either is then the tool's
  # (`native_build`). Anywhere else each keeps the decision it had, as before
  # (a dependency's window is tainted for it). Events are in trace order, and
  # one process's calls in the order it made them. The macro's process is
  # dropped once used.
  defp tool_events(decided, package) do
    {decided, _open} =
      Enum.map_reduce(decided, %{}, fn
        {owner, {:observe, "native_build", %{"mfa" => @tool_macro, "pid" => pid} = item}}, open ->
          key = {owner, item["vm"], pid}

          {{owner, {:observe, "native_build", Map.delete(item, "pid")}},
           Map.update(open, key, 1, &(&1 + 1))}

        {owner, {:observe, "tool_expansions", item}}, open ->
          key = {owner, item["vm"], item["pid"]}

          case {owner == package, Map.get(open, key, 0)} do
            {true, n} when n > 0 -> {{owner, tool_build(item)}, Map.put(open, key, n - 1)}
            _ -> {{owner, item["decision"]}, open}
          end

        {owner, {:observe, "tool_unpacks", item}}, open ->
          {{owner, if(owner == package, do: tool_build(item), else: item["decision"])}, open}

        entry, open ->
          {entry, open}
      end)

    decided
  end

  defp tool_build(item), do: {:observe, "native_build", Map.drop(item, ["pid", "decision"])}

  # In a host-native build this holds for every native tool, elixir_make
  # too: a firmware target's system match covers whatever its `make` writes
  # to priv, but a host-native build serves a priv library only when the
  # package's checksum file pins it, and which of the archives listed there
  # ends up in priv is then up to a process the tracer does not follow (a
  # `make` that picks one by the builder's CPU and fetches it itself).
  defp unreviewed_host_read?(event, mode) do
    (host_tool?(event, mode) or Map.get(mode, :host_native) == true) and
      (event["channel"] == "programs" or
         (event["channel"] == "os_identity" and not reviewed_host_read?(event)))
  end

  # A host-native build: an application config read a native tool's own code
  # makes (elixir_make's `config :elixir_make, :force_build, app: true`) is
  # judged as any closure read (`ConfigReads`), so it is a `compile_env` item
  # the client compares: a user whose config makes their own compile build
  # from source never gets the downloaded library. A read OTP's code makes
  # under the tool (inets and ssl starting for its download) stays set apart.
  defp tool_config_read?(%{"channel" => "config", "first_kind" => kind}, %{host_native: true}),
    do: kind != "toolchain"

  defp tool_config_read?(_event, _mode), do: false

  defp host_tool?(event, %{host_tools: host_tools}) do
    module = user_module(event) || mfa_module(event["mfa"])
    MapSet.member?(host_tools, module || "")
  end

  # `@reviewed_unpacks`: the ram_file driver's port, opened by OTP's own
  # `ram_file:ll_open/3` right under the tool's unpack.
  defp reviewed_unpack?(%{
         "channel" => "programs",
         "mfa" => "erlang:open_port/2",
         "arg" => %{"port" => @ram_file_port},
         "first_kind" => "toolchain",
         "first" => %{"module" => "ram_file", "function" => "ll_open", "arity" => 3},
         "user" => %{"module" => module, "function" => fun, "arity" => arity}
       }),
       do: {module, fun, arity} in @reviewed_unpacks

  defp reviewed_unpack?(_event), do: false

  defp tool_env_input?(%{"channel" => "env", "arg" => %{"name" => name}}),
    do: name in @tool_env_inputs

  defp tool_env_input?(_event), do: false

  defp reviewed_host_read?(%{"mfa" => "os:type/0"}), do: true

  defp reviewed_host_read?(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => key}}),
    do: key in @host_tool_reads

  defp reviewed_host_read?(_event), do: false

  defp user_module(%{"user" => %{"module" => module}}) when is_binary(module), do: module
  defp user_module(_event), do: nil

  defp target_read?(%{"channel" => "mix_state", "arg" => %{"fun" => "target"}}), do: true
  defp target_read?(_event), do: false

  # The module of a tracer `mfa` string as an atom's text: `"os:getenv/1"`
  # is `"os"`, `"Mix.Tasks.Compile.ElixirMake.run/1"` is
  # `"Elixir.Mix.Tasks.Compile.ElixirMake"`.
  @doc false
  @spec mfa_module(term()) :: String.t() | nil
  def mfa_module(mfa) when is_binary(mfa) do
    case String.split(mfa, "/", parts: 2) do
      [call, _arity] -> call_module(String.split(call, ":", parts: 2))
      _ -> nil
    end
  end

  def mfa_module(_mfa), do: nil

  defp call_module([module, _fun]), do: module

  defp call_module([call]) do
    case call |> String.split(".") |> Enum.drop(-1) do
      [] -> nil
      parts -> "Elixir." <> Enum.join(parts, ".")
    end
  end

  # An unjudged event counts wherever it fell (`:any`, never in scope). An
  # integrity refusal (the trace itself tampered with) refuses wherever it
  # fell too: from a quiet interval or an owner outside the package's
  # closure (its window or its child VM) it counts as `:outside`.
  # A probe's text names the window it fell in (S8 review R5): the owning
  # app's name, an app outside the closure included, or `outside` for a
  # quiet interval (an owner that is no app name), so a firmware target's
  # judge and the withhold snippets tell a dependency's probe from the
  # package's own.
  defp keep(owner, {:unjudged, why}, _scope), do: {:any, {:unjudged, owned_problem(owner, why)}}

  defp keep(owner, {:refuse, @integrity <> _} = decision, scope),
    do: if(in_scope?(owner, scope), do: {owner, decision}, else: {:outside, decision})

  defp keep(:quiet, _decision, _scope), do: nil
  defp keep(_owner, :ignore, _scope), do: nil
  defp keep(owner, decision, _scope), do: {owner, decision}

  defp in_scope?(:outside, _scope), do: true
  defp in_scope?(owner, scope), do: MapSet.member?(scope, owner)

  # The loaded-library check (`MappedLibs`, which says why). The Mix VM's
  # snapshots in order (start, every window close, end): a library first
  # seen at a window's close belongs to that window's app (Mix compiles one
  # dependency at a time), one first seen at the end to no window
  # (`:outside`, against everything). A closure child VM's start against its
  # `libs` lines (a child that compiled nothing wrote none: its start alone;
  # one that compiled and wrote none is unavailable)
  # counts against its app. Only owners in the package's closure count, as
  # for events. Allowed: the OTP root, the Elixir install, and a native
  # closure dependency's own dirs (never the package's) (its NIF, loaded when the tracer sets its
  # patterns; calls into it are the native_closure channel).
  defp mapped_libs(report, ctx, scope, waiver, host_native) do
    own = if host_native, do: own_priv_dirs(ctx), else: []
    allowed? = &lib_allowed?(ctx, scope, own, &1)
    snapshots = main_snapshots(report)

    needed =
      if host_native,
        do: needed_libs(report.start, own),
        else: fn _prev, _snap -> MapSet.new() end

    children =
      for {app, child} <- Enum.sort(report.children), Context.dep?(ctx, app) do
        {app, MappedLibs.check(child.start, child_snapshots(child), allowed?)}
      end

    main = main_libs(report.start, snapshots, allowed?, needed)
    results = Enum.filter(main ++ children, &in_scope?(elem(&1, 0), scope))
    by_owner = Enum.group_by(results, &elem(&1, 0), &elem(&1, 1))
    acc = %{decided: [], problems: [], native: [], waived: false, by_owner: by_owner}

    Enum.reduce(results, acc, fn
      {owner, {:refuse, reason}}, acc ->
        %{acc | decided: acc.decided ++ [{owner, {:refuse, reason}}]}

      {_owner, {:ok, libs}}, acc ->
        %{acc | native: Enum.uniq(acc.native ++ libs)}

      {_owner, :unavailable}, acc when waiver ->
        %{acc | waived: true}

      {_owner, :unavailable}, acc ->
        %{acc | problems: Enum.uniq(acc.problems ++ ["native library check unavailable"])}
    end)
  end

  # A child's `libs` lines. A child that compiled nothing wrote none and its
  # start is all there is; one that compiled and wrote none is unavailable.
  defp child_snapshots(%{libs: [_ | _] = libs}), do: libs
  defp child_snapshots(%{compiles: [_ | _]}), do: []
  defp child_snapshots(child), do: [child.start]

  # The Mix VM's snapshots after its start, in order: every window close,
  # then the end (`:outside`).
  defp main_snapshots(report) do
    closes =
      report.windows
      |> Enum.filter(&is_integer(&1.close))
      |> Enum.sort_by(& &1.close)
      |> Enum.map(&{&1.app, Map.get(&1, :libs)})

    closes ++ [{:outside, report.ending}]
  end

  # Each snapshot against the one before it, with what `needed` lets
  # through in that snapshot alone.
  defp main_libs(start, snapshots, allowed?, needed) do
    {_last, results} =
      Enum.reduce(snapshots, {start, []}, fn {owner, snap}, {prev, acc} ->
        here = needed.(prev, snap)
        check = MappedLibs.check(prev, [snap], &(allowed?.(&1) or MapSet.member?(here, &1)))
        {snap, [{owner, check} | acc]}
      end)

    Enum.reverse(results)
  end

  # Judge revision 25, a host-native build's Mix VM only: loading the
  # package's own priv library (its `@on_load`) makes the dynamic loader map
  # the libraries its `DT_NEEDED` names that the VM had not mapped yet
  # (tokenizers 0.5.2's NIF needs glibc's `libdl.so.2` and
  # `libpthread.so.0`, which a VM linked against glibc 2.34 or later never
  # maps itself). Such a library may be mapped when it first shows in the
  # same snapshot as a library of the package's own priv whose `DT_NEEDED`
  # names its `DT_SONAME` (its file name when it has none), directly or
  # through another library let through so, and its real path is in the
  # directory the VM's own C library was mapped from at start. Nothing else
  # is read to decide it: the published NIF's bytes (checksum-pinned,
  # `NccWorker.HostNative`) name these libraries, and a client resolves the
  # same sonames (`elf.needs`). One mapped earlier, anywhere else, or not
  # named so keeps its refusal: what a snapshot lets through holds for that
  # snapshot only, so one first mapped in another window, unmapped and
  # mapped again with the NIF, still refuses where it first showed.
  defp needed_libs(start, own) do
    dirs =
      case MappedLibs.libs(start) do
        {:ok, before} -> libc_dirs(before)
        :error -> MapSet.new()
      end

    # What `snap` adds to `prev`, as `MappedLibs.check/3` compares them.
    fn prev, snap ->
      with {:ok, before} <- MappedLibs.libs(prev),
           {:ok, libs} <- MappedLibs.libs(snap) do
        needed_by_own(Enum.uniq(libs) -- before, own, dirs)
      else
        :error -> MapSet.new()
      end
    end
  end

  # The real directories of the C library mapped at start.
  defp libc_dirs(libs) do
    for path <- libs,
        real = Context.realpath(path),
        is_binary(real),
        Regex.match?(~r/^libc(\.so(\.\d+)*|-\d+\.\d+\.so)$/, Path.basename(real)),
        into: MapSet.new(),
        do: Path.dirname(real)
  end

  defp needed_by_own(added, own, dirs) do
    {roots, rest} = Enum.split_with(added, &own_lib?(&1, own))

    candidates =
      for path <- rest,
          real = Context.realpath(path),
          is_binary(real) and MapSet.member?(dirs, Path.dirname(real)),
          {:ok, %{type: :dyn} = info} <- [Elf.read_file(real)],
          do: {info.soname || Path.basename(real), path, info.needed}

    roots |> Enum.flat_map(&elf_needed/1) |> take_needed(candidates, MapSet.new())
  end

  defp own_lib?(path, own) do
    real = Context.realpath(path)
    is_binary(real) and Enum.any?(own, &Context.under?(real, &1))
  end

  defp elf_needed(path) do
    case Elf.read_file(Context.realpath(path) || path) do
      {:ok, %{needed: needed}} -> needed
      _ -> []
    end
  end

  # Each soname takes every candidate it names, whose own `DT_NEEDED` then
  # joins the list; a candidate is taken once.
  defp take_needed([], _candidates, acc), do: acc

  defp take_needed([soname | rest], candidates, acc) do
    {hits, others} = Enum.split_with(candidates, &(elem(&1, 0) == soname))
    acc = Enum.reduce(hits, acc, &MapSet.put(&2, elem(&1, 1)))
    take_needed(rest ++ Enum.flat_map(hits, &elem(&1, 2)), others, acc)
  end

  defp lib_allowed?(ctx, scope, own, path) do
    real = Context.realpath(path) || path
    under? = &(is_binary(&1) and String.starts_with?(real, &1 <> "/"))

    dirs =
      [ctx.otp_root, ctx.elixir_root] ++
        for app <- scope,
            app != ctx.package,
            Context.dep?(ctx, app),
            ctx.deps[app].native?,
            do: [ctx.deps[app].build, ctx.deps[app].dest]

    dirs |> List.flatten() |> Enum.any?(under?) or own_published?(own, real, under?)
  end

  # A host-native build's own priv library only while the file it was
  # mapped from is still there for the judge, which `NccWorker.HostNative`
  # then holds to a checksum-pinned archive. One removed or replaced since
  # (the map names it `<path> (deleted)`) is none of the files the build
  # publishes. The path is the run's own build or source tree.
  # sobelow_skip ["Traversal.FileModule"]
  defp own_published?(own, real, under?),
    do: Enum.any?(own, under?) and File.regular?(real)

  # A host-native build publishes the package's own priv libraries, and
  # loading one is what its compile does (rustler's `@on_load` runs in the
  # compiler VM once the module is compiled): its build's and its source's
  # `priv`, each as it resolves, may be mapped. Nothing else of the package's.
  defp own_priv_dirs(ctx) do
    if Context.dep?(ctx, ctx.package) do
      dep = ctx.deps[ctx.package]

      for dir <- [dep.build, dep.dest],
          is_binary(dir),
          priv = Path.join(dir, "priv"),
          path <- Enum.uniq([priv, Context.realpath(priv) || priv]),
          do: path
    else
      []
    end
  end

  # What the trace itself says about whether it can be used at all. The
  # Report collects most of these; a report built some other way (tests,
  # a later reader) is held to the same checks here, each passed only by an
  # explicit value.
  defp trace_problems(report, ctx) do
    ending = report.ending || %{}

    [
      {report.refused_start != nil, "tracer refused to start"},
      {report.start == nil, "no start line"},
      {report.closure == nil, "no closure line"},
      {report.ending == nil, "no end line"},
      {report.ending != nil and ending["status"] != "ok",
       "traced compile ended #{inspect(ending["status"])}"},
      {ending != %{} and not clean_end?(ending), "the end failed its checks"},
      {report.overflow != [], "trace overflowed"},
      {not match?(%{"unjudged" => 0}, report.stats), "stats missing or unjudged events"},
      {report.closure != nil and not Context.dep?(ctx, ctx.package),
       "package not in the traced closure"}
    ]
    |> Enum.filter(&elem(&1, 0))
    |> Enum.map(&elem(&1, 1))
    |> Kernel.++(report.problems)
  end

  # R3: no closure dependency is judged without a trace of its own compile.
  # The tracer took a digest of each dependency's ebin and priv when its
  # window closed; one that is missing, or that differs from the build dir
  # now, means the files judged are not the files the trace saw compiled
  # (restored, reused or rewritten since). Fails closed: no digest then, no
  # digest now, or no build dir is never a match.
  #
  # The recompute is bounded as a whole (`built_budget_ms:`, default 5 min)
  # on top of each digest's own limits: a dependency checked once the
  # budget is spent is not judged ("no time left").
  defp built_problems(ctx, report, opts, exclude) do
    if Keyword.get(opts, :built_check, true) do
      clock = Keyword.get(opts, :built_clock, fn -> System.monotonic_time(:millisecond) end)
      deadline = clock.() + Keyword.get(opts, :built_budget_ms, @built_budget_ms)

      ctx
      |> Context.closure_of(ctx.package)
      |> Enum.map(
        &built_mismatch(ctx, report, &1, deadline - clock.(), excluded(ctx, &1, exclude))
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.map(&("built outside the trace: " <> &1))
    else
      []
    end
  end

  # Foreign priv spec 3.5: kino's digest leaves out exactly the directories
  # that settled in a window other than kino's (`ForeignPriv.settle/2`).
  # Equal to the one taken when kino's window closed, it shows nothing else
  # changed and no file was under them then.
  defp excluded(%Context{foreign_priv: %{target: app}}, app, exclude), do: exclude
  defp excluded(_ctx, _app, _exclude), do: []

  defp built_mismatch(_ctx, _report, app, left_ms, _exclude) when left_ms <= 0,
    do: "#{app} (no time left)"

  defp built_mismatch(ctx, report, app, left_ms, exclude) do
    recorded = Map.get(report.built || %{}, app)

    case {recorded, Map.get(ctx.deps, app)} do
      {%{digest: want}, %{build: dir}} when is_binary(want) and is_binary(dir) ->
        compare_built(app, want, digest_now(dir, left_ms, exclude))

      {%{error: why}, _dep} when is_binary(why) ->
        "#{app} (digest failed at window close: #{why})"

      {%{digest: want}, _dep} when is_binary(want) ->
        "#{app} (no build dir)"

      _ ->
        "#{app} (no digest recorded)"
    end
  end

  defp compare_built(_app, want, {:ok, want, _files}), do: nil
  defp compare_built(app, _want, {:ok, _other, _files}), do: app

  defp compare_built(app, _want, {:error, why}),
    do: "#{app} (digest failed now: #{inspect(why, limit: 5, printable_limit: 200)})"

  # The digest's own limits, its time cut to what is left of the budget, and
  # the build-dir-relative paths it leaves out (`excluded/3`).
  defp digest_now(dir, left_ms, exclude \\ []) do
    opts = %{timeout_ms: min(left_ms, @digest_timeout_ms)}
    opts = if exclude == [], do: opts, else: Map.put(opts, :exclude, exclude)

    case :ncc_tracer_digest.dir(dir, opts) do
      {:ok, digest, files} when is_binary(digest) -> {:ok, digest, files}
      {:error, why} -> {:error, why}
      other -> {:error, {:unexpected, other}}
    end
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp clean_end?(ending) do
    ending["overflow"] == false and
      Enum.all?(~w(depth_ok final_sentinel integrity_ok delivered), &(ending[&1] == true))
  end

  defp window_problem(report, app) do
    case Enum.filter(report.windows, &match?(%{app: ^app}, &1)) do
      [window] -> window_checks(report, window)
      [] -> "no window for #{inspect(app)}"
      _ -> "#{app}'s window is broken (more than one)"
    end
  end

  defp window_checks(report, %{app: app, open: open, close: close} = window) do
    cond do
      not (is_integer(open) and is_integer(close)) ->
        "#{app}'s window is broken"

      not intact?(window) ->
        "#{app}'s window is broken"

      not Enum.any?(report.sentinels, &sentinel_in?(&1, app, open, close)) ->
        "sentinel missing in #{app}'s window"

      true ->
        nil
    end
  end

  defp intact?(window) do
    Map.get(window, :depth_ok) == true and Map.get(window, :integrity_ok) == true and
      Map.get(window, :delivered) == true
  end

  defp sentinel_in?(%{app: app, ts: ts} = sentinel, app, open, close) when is_integer(ts),
    do: ts >= open and ts <= close and Map.get(sentinel, :integrity_ok) == true

  defp sentinel_in?(_sentinel, _app, _open, _close), do: false

  # R2: `nil` (clean), `{:observe, list}`, `{:refuse, reason}` or
  # `{:error, why}`.
  defp build_root(ctx, app) do
    case Context.ebin(ctx, app) do
      nil ->
        {:error, "no ebin for #{inspect(app)}"}

      ebin ->
        ebin
        |> BuildRoot.check(Context.roots(ctx), &Context.closure_file?(ctx, &1), r2_opts(ctx))
        |> r2()
    end
  end

  # R2 for the package's own beams (closure dependencies are not published
  # by this build): a bare source path, otherwise an observation, refuses
  # when the module that holds it runs programs
  # (`BuildRoot.program_source_paths/3`).
  defp package_build_root(ctx) do
    case Context.ebin(ctx, ctx.package) do
      nil ->
        {:error, "R2: no ebin for #{inspect(ctx.package)}"}

      ebin ->
        ebin
        |> BuildRoot.program_source_paths(
          Context.roots(ctx),
          &Context.closure_file?(ctx, &1),
          r2_opts(ctx)
        )
        |> r2()
    end
  end

  # A template root only `__mix_recompile__?/0` holds is an observation
  # (`BuildRoot`, "build_root_recompile_dir").
  defp r2_opts(ctx), do: [closure_dir?: &Context.closure_dir?(ctx, &1)]

  defp r2(:ok), do: nil
  defp r2({:observe, list}) when is_list(list), do: {:observe, list}
  defp r2({:refuse, reason}) when is_binary(reason), do: {:refuse, reason}
  defp r2({:error, why}), do: {:error, "R2: #{why}"}
  defp r2(other), do: {:error, "R2: unexpected #{inspect(other, limit: 5)}"}

  # The rebar3 rules, with the compile inputs they record (`platform_define`
  # items, `Rebar`): `{nil, []}` for a Mix-built app, else the result,
  # `{:refuse, reason}`, `{:error, why}` (coverage, taint for a dependency),
  # `{:unjudged, why}` (could not be judged), `{:gap, module}` or `:ok`.
  defp rebar(ctx, report, app) do
    if Context.manager(ctx, app) == "rebar3", do: rebar3(ctx, report, app), else: {nil, []}
  end

  defp rebar3(ctx, report, app) do
    case Context.dest(ctx, app) do
      nil -> {{:unjudged, "rebar3 source dir missing"}, []}
      dest -> rebar3(static_rebar(ctx, report, app, dest), ctx, report, app)
    end
  end

  defp rebar3({:refuse, _} = refusal, _ctx, _report, _app), do: {refusal, []}
  defp rebar3({:unjudged, _} = unjudged, _ctx, _report, _app), do: {unjudged, []}
  defp rebar3(:ok, ctx, report, app), do: rebar3({:inputs, []}, ctx, report, app)

  defp rebar3({:inputs, items}, ctx, report, app),
    do: {Rebar.coverage(Context.ebin(ctx, app), Map.get(report.children, app)), items}

  # The static rules on the app's rebar.config from its verified Hex
  # tarball and its rebar3 parents' (their overrides), then the
  # mix.rebar.config rebar3 read. A script on disk counts as one in the
  # tarball: judged by that mix.rebar.config and the trace (`Rebar`).
  defp static_rebar(ctx, report, app, dest) do
    parents = Context.rebar3_parents(ctx, app)

    with {:ok, own} <- Rebar.tarball_sources(Context.tarball(ctx, app)),
         {:ok, inherited} <- parent_sources(ctx, parents) do
      own = %{own | script?: own.script? or disk_script?(dest)}

      own = Map.put(own, :reviewed, reviewed_hooks(ctx, report, app))

      own =
        Map.put(
          own,
          :reviewed_scripts,
          Rebar.allowed_app_src_scripts(Context.tarball(ctx, app), Map.get(ctx.trees, app))
        )

      mix_config = mix_rebar_config(ctx, app)

      own
      |> Rebar.check_sources(inherited, mix_config)
      |> installed_plugins(ctx, dest, Rebar.named_plugins(own, mix_config), mix_config)
    end
  end

  # The static rules passed: every plugin rebar3 installed for the app must
  # be a reviewed release (`RebarPlugins`), every reviewed one it names too,
  # under `_build` and the `base_dir` rebar3 built the app under
  # (`Rebar.base_dirs/2`, coverage drop 2026-11-22, F9), which, when it
  # cannot be judged, cannot be judged either.
  defp installed_plugins(result, ctx, dest, named, mix_config)
       when result == :ok or elem(result, 0) == :inputs do
    with {:ok, bases} <- Rebar.base_dirs(mix_config, ctx.rebar_base),
         :ok <-
           RebarPlugins.check(
             dest,
             ctx.rebar_cache,
             named,
             RebarPlugins.pins(),
             ctx.moved_deps,
             bases
           ) do
      result
    end
  end

  defp installed_plugins(result, _ctx, _dest, _named, _mix_config), do: result

  # The compile's `REBAR_BASE_DIR`, the last value `env` gives it, else this
  # VM's, which the compile inherits (as `rebar_cache/1` reads its names).
  defp rebar_base(env) do
    case env |> Enum.reverse() |> List.keyfind("REBAR_BASE_DIR", 0) do
      {_name, value} -> value
      nil -> System.get_env("REBAR_BASE_DIR")
    end
  end

  # rebar3's cache dir of a compile with `env` (`rebar_dir:global_cache_dir/1`):
  # `REBAR_CACHE_DIR`, else `$HOME/.cache/rebar3`, each the last value `env`
  # gives it, as the compile's environment applies them, or, when `env` does
  # not name it, this VM's, which the compile inherits. A name `env` unsets
  # (`nil`) is unset.
  @doc false
  @spec rebar_cache([{String.t(), String.t() | nil}]) :: String.t() | nil
  def rebar_cache(env) do
    get = fn name ->
      case env |> Enum.reverse() |> List.keyfind(name, 0) do
        {^name, value} -> value
        nil -> System.get_env(name)
      end
    end

    case {get.("REBAR_CACHE_DIR"), get.("HOME")} do
      {dir, _home} when is_binary(dir) and dir != "" -> dir
      {_dir, home} when is_binary(home) and home != "" -> Path.join([home, ".cache", "rebar3"])
      _ -> nil
    end
  end

  # The reviewed compile hooks `app` may run (`Rebar.allowed_hooks/3`):
  # none when the compile wrote the hook's variable anywhere it was traced,
  # as rebar3 inherits the Mix VM's environment.
  defp reviewed_hooks(ctx, report, app) do
    case Map.get(Rebar.reviewed_hooks(), app) do
      {_file, var} ->
        if env_written?(report, var),
          do: [],
          else: Rebar.allowed_hooks(app, Context.tarball(ctx, app), ctx.hook_scripts[app])

      nil ->
        []
    end
  end

  defp env_written?(report, var) do
    events = report.events ++ Enum.flat_map(report.children, fn {_app, c} -> c.events end)

    # A write whose name the trace did not record as a string counts.
    Enum.any?(events, fn
      %{"channel" => "env_write", "arg" => %{"name" => name}} when is_binary(name) -> name == var
      %{"channel" => "env_write"} -> true
      _ -> false
    end)
  end

  # A scripted parent's overrides are what its script evaluated to: Mix
  # wrote them into the parent's own mix.rebar.config (`Rebar`).
  defp parent_sources(ctx, parents) do
    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, acc} ->
      case Rebar.tarball_sources(Context.tarball(ctx, parent)) do
        {:ok, %{script?: true} = sources} ->
          {:cont, {:ok, acc ++ [Map.put(sources, :mix_config, mix_rebar_config(ctx, parent))]}}

        {:ok, sources} ->
          {:cont, {:ok, acc ++ [sources]}}

        {:unjudged, why} ->
          {:halt, {:unjudged, "rebar3 parent #{parent}: #{why}"}}
      end
    end)
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp disk_script?(dest), do: File.exists?(Path.join(dest, "rebar.config.script"))

  # The config Mix wrote for rebar3 (`REBAR_CONFIG`), next to the ebin.
  defp mix_rebar_config(ctx, app) do
    case Context.ebin(ctx, app) do
      nil -> {:unjudged, "rebar3 build dir missing"}
      ebin -> Path.join(Path.dirname(ebin), "mix.rebar.config")
    end
  end

  # Every closure dependency but the package, in compile order (the
  # closure line's), with what R3 makes of it, and `decided` with every
  # `native_beam_reads` observation settled (`beam_reads/5`): a dependency's
  # own reads before its R3 result, since a refused one taints it, then
  # everyone else's (the package's, outside every window).
  defp dep_results(ctx, report, decided, libs, {target?, side?}, waivers) do
    scope = Context.closure_of(ctx, ctx.package)

    order =
      for %{"app" => app} <- closure_deps(report), app != ctx.package, app in scope, do: app

    sided = if side?, do: side_built(decided, ctx.package), else: MapSet.new()

    decided =
      cond do
        target? -> Enum.map(decided, &native_file_read/1)
        side? -> Enum.map(decided, &side_file_read(&1, sided))
        true -> decided
      end

    {decided, results} =
      Enum.reduce(order, {decided, %{}}, fn app, {decided, results} ->
        decided = beam_reads(decided, ctx, report, {results, libs}, &(&1 == app))
        result = dep_result(ctx, report, decided, app, {libs, sided, Map.get(waivers, app)})
        {decided, Map.put(results, app, result)}
      end)

    decided =
      decided
      |> own_beam_reads(ctx, target?)
      |> beam_reads(ctx, report, {results, libs}, &(&1 not in order))

    {decided, Enum.map(order, &{&1, results[&1]})}
  end

  # A firmware target's trace (`target_inputs/3`): the package's own compile
  # reading a beam it wrote itself (Elixir 1.20's type checker on a module
  # compiled earlier in the same compile) reads nothing but that compile's
  # own output, whose files the target publishes as they are. Settled
  # before `beam_reads/5`, which refuses it on the host. Only a beam: any
  # other file in that ebin is the native build's, which nobody traced
  # (`native_output/2` checks the beams).
  defp own_beam_reads(decided, _ctx, false), do: decided

  defp own_beam_reads(decided, ctx, true) do
    Enum.map(decided, fn
      {owner, {:observe, "native_beam_reads", %{"app" => app, "vm" => "main"} = item}} = entry
      when owner == ctx.package and app == ctx.package ->
        if beam_path?(item), do: {owner, {:observe, "own_beam_reads", item}}, else: entry

      entry ->
        entry
    end)
  end

  # A firmware target's trace sets the native build tool's activity apart,
  # so a natively built dependency's own compile is clean however its native
  # build ran (`clean_native?/3`), and `make` is no traced process: a file
  # other than a beam in its ebin may be one `make` wrote, from inputs
  # nobody records. A compile reading one, in any window, refuses as it
  # would on the host.
  defp native_file_read({owner, {:observe, "native_beam_reads", item}} = entry) do
    if beam_path?(item), do: entry, else: {owner, {:refuse, item["refusal"]}}
  end

  defp native_file_read(entry), do: entry

  defp beam_path?(%{"arg" => %{"path" => path}}) when is_binary(path),
    do: Path.extname(path) == ".beam"

  defp beam_path?(_item), do: false

  # Judge revision 15. A read in a natively built dependency's `ebin`
  # (`Events`, `native_beam_reads`: Elixir 1.20's type checker reading a
  # remote module's beam, as bumblebee's compile reads
  # `Tokenizers.Tokenizer.beam`) is allowed only when it reads exactly what
  # Mix compiles on the user's side, and is otherwise the refusal it always
  # was. That holds when the read comes from the Mix VM after the
  # dependency's window closed (the built check then pins the beam to what
  # that window wrote) and the dependency is clean (`clean_native?/4`).
  #
  # Dependency by dependency, not module by module: a host value the
  # dependency's compile read can reach any later compile without a traced
  # event, through a persistent term, an ETS table or a process
  # (`fx_uses_pt` in the tracer fixtures), so a tainted dependency's beams
  # are never read, whichever module was.
  defp beam_reads(decided, ctx, report, {results, libs}, owner?) do
    calls = for {owner, {:observe, "native_calls", _}} <- decided, into: MapSet.new(), do: owner
    known = %{results: results, libs: libs, calls: calls}

    {decided, _memo} =
      Enum.map_reduce(decided, %{}, fn
        {owner, {:observe, "native_beam_reads", item}} = entry, memo ->
          if owner?.(owner) do
            {allowed?, memo} = beam_read(item, ctx, report, known, memo)
            {if(allowed?, do: entry, else: {owner, {:refuse, item["refusal"]}}), memo}
          else
            {entry, memo}
          end

        entry, memo ->
          {entry, memo}
      end)

    decided
  end

  defp beam_read(%{"app" => app} = item, ctx, report, known, memo) do
    cond do
      app == ctx.package or not is_binary(item["refusal"]) ->
        {false, memo}

      not Map.has_key?(known.results, app) ->
        {false, memo}

      item["vm"] != "main" or not after_window?(report, app, item["ts"]) ->
        {false, memo}

      Map.has_key?(memo, app) ->
        {memo[app], memo}

      true ->
        clean = clean_native?(ctx, app, known)
        {clean, Map.put(memo, app, clean)}
    end
  end

  defp beam_read(_item, _ctx, _report, _known, memo), do: {false, memo}

  defp after_window?(report, app, ts) when is_integer(ts) do
    Enum.any?(report.windows, fn
      %{app: ^app, close: close} when is_integer(close) -> ts > close
      _window -> false
    end)
  end

  defp after_window?(_report, _app, _ts), do: false

  # A natively built dependency whose beams are what Mix compiles on the
  # user's side: its own compile is clean by R3 (no taint, R2 and the rebar3
  # rules judged), Mix built it itself (manager mix or rebar3, so no `make`
  # ran outside the trace), no native code ran during its compile (no new
  # mapped library in its window, no call into another natively built
  # dependency), and its source tree is still exactly its verified tarball's
  # (`Trees`), so every source the compile saw is the user's: the trees of a
  # natively built dependency are not checked before the compile, and its
  # native build may have generated sources.
  defp clean_native?(ctx, app, known) do
    result = known.results[app]

    result.taint == nil and not match?({:error, _}, result.r2) and
      not match?({:unjudged, _}, result.rebar) and
      Context.manager(ctx, app) in ["mix", "rebar3"] and
      (libs_clean?(known.libs, app) or result.side == true) and
      not MapSet.member?(known.calls, app) and
      tree_clean?(ctx, app)
  end

  # The tree on disk now, after the compile, against the dependency's
  # verified tarball (`Trees.snapshot/5`, the one before the compile skips
  # natively built dependencies): nothing a build generated, nothing
  # changed. No verified tarball, no source dir at `<deps>/<app>` (the
  # compile's deps dir, `Context.deps_path/1`) or no time left is not clean.
  defp tree_clean?(ctx, app), do: clean_tree(ctx, app) != nil

  # `tree_clean?/2`'s check, with the tarball's members when it holds, else nil.
  defp clean_tree(%Context{project_dir: project, hex: {home, releases}} = ctx, app)
       when is_binary(project) do
    deps = Context.deps_path(ctx)

    with %{} = release <- Map.get(releases, app),
         true <- is_binary(deps) and Context.dest(ctx, app) == Path.join(deps, app),
         %{^app => {:ok, members}} <-
           Trees.snapshot(project, %{app => release}, home, [], deps_path: deps) do
      members
    else
      _ -> nil
    end
  end

  defp clean_tree(_ctx, _app), do: nil

  # Judge revision 23. A closure dependency's own compile reading a file in
  # its own source `priv` through Mix's link (`Events`, `own_priv_reads`:
  # rustler's `Mix.Tasks.Rustler.New` embedding its templates) read what
  # every user's compile of it reads, its verified tarball's bytes, when
  # that dependency's whole source tree is still exactly that tarball's
  # after the compile (`clean_tree/2`, the check revision 15 makes: a
  # natively built dependency's tree is not checked before the compile, and
  # nothing a build wrote there may be what was read) and the tarball holds
  # the file. A tree any compile wrote into (Mix's leex and yecc output in
  # `src/`) is not clean, so its reads keep their refusal. Allowed then,
  # refused as the host read it always was otherwise: in the dependency's
  # window, before its R3 result, so a refused read taints it. A firmware
  # target's trace is judged the same: the same tree check is what it
  # already asks of every natively built dependency (`native_output/2`).
  # Except in a window the native build tool ran in (`native_build`): the
  # `make` it runs is no traced process, and may rewrite a file of the
  # tarball in `priv`, or relink the build `priv`, before the read and put
  # the tarball's bytes back before the window closes (the digest taken
  # then and the tree check after the compile both see the tarball), or
  # regenerate it with the bytes the tarball happens to hold on this
  # builder. What it wrote may not reach the beams (`native_file_read/1`),
  # so such a read keeps its refusal.
  defp own_priv_reads(decided, ctx) do
    built =
      for {owner, {:observe, "native_build", _item}} <- decided, into: MapSet.new(), do: owner

    {decided, _memo} =
      Enum.map_reduce(decided, %{}, fn
        {owner, {:observe, "own_priv_reads", item}} = entry, memo ->
          {members, memo} = clean_members(ctx, item["app"], memo)

          allowed? =
            owner == item["app"] and not MapSet.member?(built, owner) and is_map(members) and
              is_binary(item["source"]) and Map.has_key?(members, item["source"])

          {if(allowed?, do: entry, else: {owner, {:refuse, own_priv_refusal(item)}}), memo}

        entry, memo ->
          {entry, memo}
      end)

    decided
  end

  defp clean_members(ctx, app, memo) do
    case memo do
      %{^app => members} ->
        {members, memo}

      _ ->
        members = if Context.dep?(ctx, app), do: clean_tree(ctx, app)
        {members, Map.put(memo, app, members)}
    end
  end

  defp own_priv_refusal(%{"refusal" => refusal}) when is_binary(refusal), do: refusal
  defp own_priv_refusal(item), do: "compile-time host read: #{item["mfa"]}"

  # Judge revision 27. A Mix alias of a dependency's own project copying one
  # file of its own source tree onto another (`Events`, `own_tree_copies`:
  # phoenix's `copy_core_components/1`, run before its compile) changed no
  # byte when that dependency's verified tarball holds both files with the
  # same bytes and its whole tree is still exactly that tarball's after the
  # compile (`clean_tree/2`): the copy wrote the bytes that were there, so
  # every read of either file, before or after it, read what every user's
  # compile of it reads. The copy ran in the process Mix runs its tasks in
  # and returned before Mix went on, so no compile of it ran while the file
  # was being written; and `Events` never observes one in a natively built
  # dependency, whose untraced build tool may. The mode `File.cp/3` writes
  # onto the copy after it is allowed only onto the destination of such a
  # copy in the same window. A copy onto its own source, by another
  # spelling or another hard link, empties it, so the two must be two
  # files (`one_name?/3`). Anything else is the write it always was, in
  # that dependency's window, so a refused one taints it.
  defp own_tree_copies(decided, ctx) do
    items = for {owner, {:observe, "own_tree_copies", item}} <- decided, do: {owner, item}

    trees =
      for app <- Enum.uniq(for({_owner, %{"app" => app}} <- items, do: app)),
          into: %{},
          do: {app, if(Context.dep?(ctx, app), do: clean_tree(ctx, app))}

    copied =
      for {owner, item} <- items,
          unchanged_copy?(owner, item, trees, ctx),
          into: MapSet.new(),
          do: {owner, item["path"]}

    Enum.map(decided, fn
      {owner, {:observe, "own_tree_copies", item}} = entry ->
        allowed? =
          if is_binary(item["source"]),
            do: unchanged_copy?(owner, item, trees, ctx),
            else: owner == item["app"] and MapSet.member?(copied, {owner, item["path"]})

        if allowed?, do: entry, else: {owner, {:refuse, copy_refusal(item)}}

      entry ->
        entry
    end)
  end

  defp unchanged_copy?(owner, %{"app" => app, "path" => path, "source" => source}, trees, ctx)
       when owner == app and is_binary(path) and is_binary(source) and path != source do
    case Map.get(trees, app) do
      %{^path => sha, ^source => sha} -> one_name?(ctx, app, path) and one_name?(ctx, app, source)
      _ -> false
    end
  end

  defp unchanged_copy?(_owner, _item, _trees, _ctx), do: false

  # A regular file no other name links to: a copy onto a hard link of its
  # own source opens that one file for writing first, so it empties it. The
  # tree check compares bytes only, and a link made before the snapshot
  # passes it (an untraced `mix deps.get` evaluates every `mix.exs`); a
  # link made or removed during the compile is a refused write.
  # sobelow_skip ["Traversal.FileModule"]
  defp one_name?(ctx, app, rel) do
    match?(
      {:ok, %File.Stat{type: :regular, links: 1}},
      File.lstat(Path.join(Context.dest(ctx, app), rel))
    )
  end

  defp copy_refusal(%{"refusal" => refusal}) when is_binary(refusal), do: refusal
  defp copy_refusal(item), do: "compile-time write outside ebin: #{item["mfa"]}"

  defp libs_clean?(libs, app) do
    case Map.get(libs.by_owner, app, []) do
      [] -> false
      checks -> Enum.all?(checks, &(&1 == {:ok, []} or (&1 == :unavailable and libs.waived)))
    end
  end

  defp closure_deps(%Report{closure: %{"deps" => deps}}) when is_list(deps),
    do: Enum.filter(deps, &match?(%{"app" => app} when is_binary(app), &1))

  defp closure_deps(_report), do: []

  defp dep_result(ctx, report, decided, app, {libs, sided, waiver}) do
    r2 = build_root(ctx, app)
    {rebar, inputs} = rebar(ctx, report, app)
    side? = MapSet.member?(sided, app)

    taint =
      Enum.find_value(
        [
          fn -> window_problem(report, app) end,
          fn -> first_refusal(unwaived(decided, app, waiver), app) end,
          fn -> native_call(decided, app) end,
          fn -> holder_call(decided, app) end,
          fn -> refusal_of(r2) end,
          fn -> unless match?({:error, _}, r2), do: rebar_taint(rebar) end,
          fn -> if side?, do: side_problem(ctx, libs, app) end
        ],
        & &1.()
      )

    %{taint: taint, r2: r2, rebar: rebar, inputs: inputs, side: side?}
  end

  # --- a natively built dependency's native side, settled ---------------------

  # The closure dependencies (never the package) whose window ran the
  # reviewed native build tool under `native_side: true` (`sided/5`).
  defp side_built(decided, package) do
    for {owner, {:observe, "native_build", _item}} <- decided,
        is_binary(owner) and owner != package,
        into: MapSet.new(),
        do: owner
  end

  # A read of a file other than a beam in the ebin of a dependency whose
  # native build ran: one `make` may have written, from inputs nobody
  # records, as in a firmware target's trace (`native_file_read/1`).
  defp side_file_read({_owner, {:observe, "native_beam_reads", %{"app" => app}}} = entry, sided) do
    if MapSet.member?(sided, app), do: native_file_read(entry), else: entry
  end

  defp side_file_read(entry, _sided), do: entry

  # `native_side: true`. The tool's activity in this dependency's window was
  # set apart (`sided/5`), so what it decided must be shown to stop at the
  # native files: the dependency's beams, which a dependent compiles
  # against, must be its own sources' alone. It is on the native list (its
  # build dir unreadable to a dependent), Mix built it (the tool is a
  # Mix compiler), no NIF of a closure dependency was mapped by its window's
  # close (its own module bodies ran no native code; a library of OTP's
  # own, the download's `crypto`, may be), its source tree is exactly its
  # verified tarball's after the compile (`tree_clean?/2`: no source the
  # native build generated was compiled), every beam in its ebin was
  # compiled from a file of that tree (`compiled_in?/2`: no module the
  # native build put there), and every checksum file elixir_make evaluates
  # from it is a literal map (`Compatibility.NifOrigin.parse/1`: evaluating
  # it runs nothing). The first that fails is its taint.
  defp side_problem(ctx, libs, app) do
    Enum.find_value(
      [
        fn -> unless native?(ctx, app), do: side_refusal("not on the native list") end,
        fn -> side_manager(Context.manager(ctx, app)) end,
        fn ->
          if lib = side_lib(ctx, libs, app), do: "compile-time native library load: " <> lib
        end,
        fn ->
          unless tree_clean?(ctx, app),
            do: side_refusal("source tree is not its verified tarball's")
        end,
        fn ->
          if beam = foreign_dep_beam(ctx, app),
            do: side_refusal("beam not compiled from its own sources: " <> beam)
        end,
        fn ->
          if file = evaluated_checksum(ctx, app),
            do: side_refusal("checksum file is not a literal map: " <> file)
        end,
        fn ->
          if file = beam_build_file(ctx, app),
            do: side_refusal("native build file compiles BEAM code: " <> file)
        end
      ],
      & &1.()
    )
  end

  defp side_manager("mix"), do: nil

  defp side_manager(manager),
    do: side_refusal("built by #{manager || "an unknown manager"}, not Mix")

  # Review L2. A native build file (a Makefile, a CMake list, a make
  # include) that names `erlc`, `elixirc` or a `.beam` may compile or copy
  # BEAM code into the dependency's ebin, and a build that runs after Mix's
  # compilers can rewrite a beam Mix compiled and keep its compile info,
  # which `compiled_in?/2` cannot tell apart. The first such file of the
  # dependency's source tree, relative to it, by name; a file too large or
  # unreadable, or a tree too large to walk, counts as one. Writing
  # `$(MIX_COMPILE_PATH)/../priv`, as most do, is no mention.
  @beam_build_files ~r/\A(?:GNUmakefile|[Mm]akefile(?:\..+)?|CMakeLists\.txt|.+\.mk|.+\.cmake)\z/
  @beam_build_words ~r/\berlc\b|\belixirc\b|\.beam\b/i
  @beam_build_skip ~w(.git _build node_modules)
  @beam_build_max_depth 8
  @beam_build_max_entries 20_000
  @beam_build_max_bytes 4 * 1024 * 1024

  defp beam_build_file(ctx, app) do
    with dest when is_binary(dest) <- Context.dest(ctx, app),
         {:ok, files, _seen} <- build_files(dest, "", 0, {[], 0}) do
      files |> Enum.sort() |> Enum.find(&beam_build?(Path.join(dest, &1)))
    else
      nil -> "(no source dir)"
      :too_large -> "(source tree too large to scan)"
    end
  end

  # The native build files under `rel` of `root`, with the entries seen so
  # far: `{:ok, files, seen}`, or `:too_large` past the depth or entry
  # bounds or for a directory that cannot be listed. Links are not followed.
  # sobelow_skip ["Traversal.FileModule"]
  defp build_files(_root, _rel, depth, _acc) when depth > @beam_build_max_depth, do: :too_large

  defp build_files(root, rel, depth, {found, seen}) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} when seen + length(names) <= @beam_build_max_entries ->
        names
        |> Enum.sort()
        |> Enum.reduce_while(
          {:ok, found, seen + length(names)},
          &build_step(root, rel, depth, &1, &2)
        )

      _too_large_or_unlistable ->
        :too_large
    end
  end

  defp build_step(root, rel, depth, name, {:ok, found, seen}) do
    case build_entry(root, Path.join(rel, name), name, depth, {found, seen}) do
      {:ok, _found, _seen} = acc -> {:cont, acc}
      :too_large -> {:halt, :too_large}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp build_entry(root, rel, name, depth, {found, seen}) do
    case File.lstat(Path.join(root, rel)) do
      {:ok, %File.Stat{type: :directory}} ->
        if name in @beam_build_skip,
          do: {:ok, found, seen},
          else: build_files(root, rel, depth + 1, {found, seen})

      {:ok, %File.Stat{type: :regular}} ->
        if Regex.match?(@beam_build_files, name),
          do: {:ok, [rel | found], seen},
          else: {:ok, found, seen}

      _other ->
        {:ok, found, seen}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp beam_build?(path) do
    with {:ok, %File.Stat{size: size}} when size <= @beam_build_max_bytes <- File.stat(path),
         {:ok, text} <- File.read(path) do
      BuildCache.match_or_error?(@beam_build_words, text)
    else
      _ -> true
    end
  end

  defp side_refusal(why), do: Reasons.native_side() <> why

  # On the native list (`Context`: its build dir unreadable to every other
  # compile, which is what keeps the native build's output from a
  # dependent). A dependency the list leaves out has a readable build dir,
  # so a file `make` wrote there could reach a dependent (review M1).
  defp native?(ctx, app), do: Context.dep?(ctx, app) and ctx.deps[app].native? == true

  # The first library mapped at the close of `app`'s window that lies under
  # a closure dependency's build or source dir (`MappedLibs` lets one
  # through there: a natively built dependency's own NIF).
  defp side_lib(ctx, libs, app) do
    dirs =
      for {_app, dep} <- ctx.deps,
          dir <- [dep.build, dep.dest],
          is_binary(dir),
          path <- Enum.uniq([dir, Context.realpath(dir) || dir]),
          do: path

    libs.by_owner
    |> Map.get(app, [])
    |> Enum.find_value(fn
      {:ok, added} -> Enum.find(added, &under_any?(Context.realpath(&1) || &1, dirs))
      _check -> nil
    end)
  end

  defp under_any?(path, dirs), do: Enum.any?(dirs, &String.starts_with?(path, &1 <> "/"))

  defp foreign_dep_beam(ctx, app) do
    with ebin when is_binary(ebin) <- Context.ebin(ctx, app),
         dest when is_binary(dest) <- Context.dest(ctx, app) do
      ebin
      |> Path.join("*.beam")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.find_value(&unless(compiled_in?(&1, dest), do: Path.basename(&1)))
    else
      _ -> "(no build dir)"
    end
  end

  # The dependency's checksum files (`Compatibility.NifOrigin.checksum_file?/1`)
  # at its source root, which elixir_make's `ElixirMake.Artefact` evaluates
  # in its own frame: the first that is not a literal map, by name.
  # sobelow_skip ["Traversal.FileModule"]
  defp evaluated_checksum(ctx, app) do
    with dest when is_binary(dest) <- Context.dest(ctx, app),
         {:ok, names} <- File.ls(dest) do
      names
      |> Enum.filter(&NifOrigin.checksum_file?/1)
      |> Enum.sort()
      |> Enum.find(&(not literal_checksum?(Path.join(dest, &1))))
    else
      _ -> "(no source dir)"
    end
  end

  # Review M2. With a closure dependency's native side set apart, its
  # `make` ran untraced and might have put a module in the package's own
  # ebin before the package compiled (the package's built digest is taken
  # at its window's close, so it would include it). Every beam there must
  # have compiled from a file in the package's own source dir, as a firmware
  # target's trace asks (`native_output/2`). Nothing set apart: nothing to
  # check.
  defp side_output(%{deps: deps, ctx: ctx}) do
    if Enum.any?(deps, fn {_app, result} -> Map.get(result, :side) == true end) do
      case foreign_beam(ctx) do
        "beam not compiled from the package's own sources: " <> _ = why -> side_refusal(why)
        nil -> nil
        _no_build -> side_refusal("no build of the package to check its beams' sources")
      end
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp literal_checksum?(path) do
    case File.read(path) do
      {:ok, source} -> NifOrigin.parse(source) != :error
      {:error, _} -> false
    end
  end

  defp refusal_of({:refuse, reason}), do: reason
  defp refusal_of(_result), do: nil

  # A compile-time call into a natively built closure dependency made in
  # this dependency's window (`Events`' `native_calls`) taints it, as the
  # same call refuses in the package's window. The callee's NIF, loaded from
  # its own dirs, is allowed by the mapped-library check and its return is
  # not traced, so a host value it hands back (CPU features, the target) can
  # sit in this dependency's beams, which the package expands or reads with
  # no event of its own. Whether the callee is clean says nothing about what
  # its NIF returns.
  defp native_call(decided, owner) do
    Enum.find_value(decided, fn
      {^owner, {:observe, "native_calls", %{"mfa" => mfa}}} ->
        "calls natively built dependency at compile time: " <> to_string(mfa)

      {^owner, {:observe, "native_calls", _item}} ->
        "calls natively built dependency at compile time"

      _ ->
        nil
    end)
  end

  # S4: a call into a holder module made in this dependency's window
  # (`Events`' `holder_calls`, a relocation's second build only) taints it:
  # whatever it made of the path it was handed is no literal the rewrite
  # reaches.
  defp holder_call(decided, owner) do
    Enum.find_value(decided, fn
      {^owner, {:observe, "holder_calls", item}} ->
        "calls a build-path holder at compile time: " <> to_string(item["mfa"])

      _ ->
        nil
    end)
  end

  # For a dependency, a rebar3 coverage error is host taint (spec R3: its
  # rebar3 sentinel missing), unless R2 could not read its ebin, which makes
  # the whole verdict could-not-judge instead.
  defp rebar_taint({:refuse, reason}), do: reason
  defp rebar_taint({:error, why}), do: why
  defp rebar_taint(_result), do: nil

  # A dependency's refusals but those a guarded-module waiver covers
  # (`Guarded.waivers/3`).
  defp unwaived(decided, _app, nil), do: decided

  defp unwaived(decided, app, %{reasons: reasons}) do
    Enum.reject(decided, fn
      {^app, {:refuse, reason}} -> MapSet.member?(reasons, reason)
      _ -> false
    end)
  end

  defp first_refusal(decided, owner) do
    Enum.find_value(decided, fn
      {^owner, {:refuse, reason}} -> reason
      _ -> nil
    end)
  end

  # --- the verdict -------------------------------------------------------------

  defp verdict_of(facts) do
    problems = problems(facts)

    reason =
      Enum.find_value(
        [
          fn -> if facts.trace_problems != [], do: Reasons.could_not_judge() end,
          fn -> facts.manager_mismatch end,
          fn -> facts.tree_refusal end,
          fn -> first_refusal(facts.decided, :outside) end,
          fn -> plugin_refusal(facts) end,
          fn -> first_refusal(facts.decided, facts.ctx.package) end,
          fn -> if facts.package_window, do: Reasons.could_not_judge() end,
          fn -> package_r2(facts.package_r2) end,
          fn -> package_rebar(facts.package_rebar) end,
          fn -> closure(facts.deps) end,
          fn -> side_output(facts) end
        ],
        & &1.()
      )

    status = if reason, do: :skip, else: :pass

    verdict =
      %{
        status: status,
        reason: reason,
        observations: observations(facts, problems),
        compile_env: if(status == :pass, do: facts.config.items),
        compile_inputs: if(status == :pass, do: facts.inputs),
        manager: Context.manager(facts.ctx, facts.ctx.package)
      }
      |> ForeignPriv.put_verdict(facts.foreign, status, facts.ctx.package)

    if status == :pass,
      do: verdict |> PrivRepro.hold(own_priv(facts)) |> Differential.hold(varied(facts)),
      else: Relocate.hold(verdict, facts, &verdict_of(relocation_facts(facts, &1)))
  end

  # S4 (`Relocate.hold/3`): `facts` as they would be had R2 not refused
  # `apps`, the package or closure dependencies whose only refusal is a
  # baked deps or build path, with relocation off, for `verdict_of/1`.
  defp relocation_facts(facts, apps) do
    package_r2 = if facts.ctx.package in apps, do: nil, else: facts.package_r2

    deps =
      Enum.map(facts.deps, fn {app, result} ->
        if app in apps, do: {app, %{result | taint: nil, r2: nil}}, else: {app, result}
      end)

    %{facts | package_r2: package_r2, deps: deps, relocate: false}
  end

  # Differential builds (the job's `differential` flag, a toolchain build's
  # judge only: never a firmware target's or a host-native build's, which
  # take `target:`): the variant builds themselves (`:variant`) observe the
  # varied reads too, and hold them, but never settle them.
  defp differential?(opts),
    do: Keyword.get(opts, :differential) in [true, :variant] and target(opts) == nil

  # What `Differential.hold/2` needs: the varied reads (`Events`'
  # `varied_reads`, by owner), the package's build dir, the tree snapshot
  # it was judged on and, when a read was of the plain arguments, the
  # verified tarballs that hold a `rebar.config.script` of every locked
  # release Mix may have evaluated one of: the closure's rebar3
  # dependencies, and every locked release outside the closure line, whose
  # manager the trace does not name (Mix evaluates every dependency's
  # script when it loads the project, outside every window).
  defp varied(%{ctx: ctx, decided: decided}) do
    reads =
      for {owner, {:observe, "varied_reads", item}} <- decided,
          do: Map.put(item, "owner", owner_name(owner))

    build = Context.dep?(ctx, ctx.package) && ctx.deps[ctx.package].build
    plain? = Enum.any?(reads, &(&1["read"] == "plain_args"))

    %{
      reads: Enum.uniq(reads),
      build: build,
      trees: ctx.trees,
      scripts: if(plain?, do: script_releases(ctx), else: [])
    }
  end

  @doc false
  # The locked releases whose `rebar.config.script` Mix may have evaluated in
  # the traced VM, each `%{app, release, status}` (and `why` when
  # `:unverified`): every release of the lock but a closure dependency Mix
  # builds itself (`"mix"`) whose verified tarball holds a
  # `rebar.config.script`, `:reviewed` when it is a `ReviewedScripts`
  # release whose tree on disk was exactly its verified tarball's before the
  # compile (the tree check, `ctx.trees`: Mix evaluates the files there,
  # review S4) and `:unreviewed` when it is no reviewed release.
  # `:unverified` (it may hold one, or one that is not what was reviewed): a
  # tarball that cannot be verified or read, a script member that is no
  # regular file (review N5: Mix follows a link), a `rebar.config.script` on
  # disk under the dependencies' dir whose tarball holds none, or a reviewed
  # release whose tree check is not "ok". Public for tests.
  @spec script_releases(Context.t()) :: [map()]
  def script_releases(%Context{hex: {home, releases}} = ctx) do
    for app <- releases |> Map.keys() |> Enum.sort(),
        not (Context.dep?(ctx, app) and Context.manager(ctx, app) == "mix"),
        entry =
          script_release(ctx, app, releases[app], Context.release_tarball(home, releases, app)),
        entry != nil,
        do: entry
  end

  defp script_release(_ctx, app, _release, nil),
    do: unverified(app, "no verified tarball")

  defp script_release(ctx, app, %{name: name, version: version} = release, bytes) do
    case ReviewedScripts.script_members(bytes) do
      {:ok, :scripted} ->
        entry = %{app: app, release: "#{name} #{version}"}

        cond do
          not ReviewedScripts.reviewed?(name, version, Map.get(release, :checksum)) ->
            Map.put(entry, :status, :unreviewed)

          match?({:ok, _}, Map.get(ctx.trees, app)) ->
            Map.put(entry, :status, :reviewed)

          true ->
            Map.merge(entry, %{
              status: :unverified,
              why: "its tree was not its verified tarball's"
            })
        end

      {:ok, :none} ->
        if script_on_disk?(ctx, app),
          do: unverified(app, "a rebar.config.script on disk its tarball does not hold")

      {:unverified, why} ->
        unverified(app, why)
    end
  end

  defp unverified(app, why), do: %{app: app, release: nil, status: :unverified, why: why}

  # Mix's own test (`Mix.Rebar.load_config/1`: `File.exists?`), without
  # following a link: any entry there is one.
  # sobelow_skip ["Traversal.FileModule"]
  defp script_on_disk?(%Context{deps_path: deps}, app) when is_binary(deps),
    do: match?({:ok, _}, File.lstat(Path.join([deps, app, "rebar.config.script"])))

  defp script_on_disk?(_ctx, _app), do: false

  # Judge revision 21: what the package's own compile did in its own build
  # `priv` and above it (`Events`' `priv_writes` and `priv_probes`). `built`
  # is every file a write set the bytes of that is a regular file in that
  # `priv` now, relative to it; `roots` are R2's, which no file there may
  # hold (`PrivRoots`); `trees` the snapshot this build was judged on, which
  # the second build is judged on too.
  defp own_priv(%{ctx: ctx, decided: decided}) do
    items =
      for {owner, {:observe, kind, item}} <- decided,
          owner == ctx.package,
          kind in ["priv_writes", "priv_probes"],
          do: item

    dir = Context.own_priv(ctx, ctx.package)

    built =
      for %{"written" => rel} <- items,
          is_binary(rel) and rel != "" and is_binary(dir),
          regular_file?(Path.join(dir, rel)),
          uniq: true,
          do: rel

    %{
      observed?: items != [],
      dir: dir,
      build: Context.dep?(ctx, ctx.package) && ctx.deps[ctx.package].build,
      built: Enum.sort(built),
      roots: Context.roots(ctx),
      trees: ctx.trees
    }
  end

  # A path the trace named under the package's own build priv, checked
  # without following a link.
  # sobelow_skip ["Traversal.FileModule"]
  defp regular_file?(path), do: match?({:ok, %File.Stat{type: :regular}}, File.lstat(path))

  # A firmware target's verdict (`target_inputs/3`): only whether the trace
  # recorded every compile-time input of the package's closure. The trace
  # must be whole (step 1), the trees their tarballs', the package's window
  # intact and the rebar3 coverage judged; and nothing in it may refuse, a
  # dependency's window included: the native tool's activity and the target
  # reads are no refusals here (`targeted/4`), and every other host read is
  # an input no client could check. Nor may anything the native build wrote
  # reach the package's beams (`native_output/2`). R2 is the firmware
  # build's own (`NccWorker.FirmwareBuildRoot`), on the files it publishes;
  # a host-native build (`host_native: true`) has no such pass, so R2 on the
  # package's ebin is part of its verdict, as on the toolchain judge.
  defp target_verdict_of(facts) do
    problems = problems(facts)

    reason =
      Enum.find_value(
        [
          fn -> if facts.trace_problems != [], do: Reasons.could_not_judge() end,
          fn -> facts.manager_mismatch end,
          fn -> facts.tree_refusal end,
          fn -> any_refusal(facts.decided) end,
          fn -> if facts.package_window, do: Reasons.could_not_judge() end,
          fn -> if facts.host_native, do: package_r2(facts.package_r2) end,
          fn -> package_rebar(facts.package_rebar) end,
          fn -> closure(facts.deps) end,
          fn -> facts.native_output end
        ],
        & &1.()
      )

    status = if reason, do: :skip, else: :pass

    %{
      status: status,
      reason: reason,
      observations: observations(facts, problems),
      compile_env: if(status == :pass, do: facts.config.items),
      compile_inputs: if(status == :pass, do: facts.inputs),
      manager: Context.manager(facts.ctx, facts.ctx.package),
      refusal_texts: refusal_texts(facts)
    }
  end

  # Every rebar3 refusal of the closure, the package's and each
  # dependency's, by app (review S1): a dependency's taint keeps only its
  # first reason, and the package's rebar3 rule is reached only on an
  # otherwise clean trace, so an earlier host read hid it.
  defp rebar_refusals(facts) do
    for {app, {:refuse, reason}} <-
          [{facts.ctx.package, facts.package_rebar} | dep_rebar(facts.deps)],
        is_binary(reason),
        into: %{},
        do: {app, reason}
  end

  # Every refusal text of a target trace, uncut (review S1, N5), for the
  # firmware judge's classes (`NccWorker.FirmwareJudge`): what `reason` names
  # is only the first, and `observations["problems"]` is cut.
  defp refusal_texts(facts) do
    decided =
      for {owner, {:refuse, reason}} <- facts.decided, do: "#{owner_name(owner)}: #{reason}"

    deps =
      Enum.flat_map(facts.deps, fn {app, result} ->
        for text <- [result.taint, refusal_of(result.rebar)],
            is_binary(text),
            do: "closure dependency observed the host: #{app} (#{text})"
      end)

    [
      facts.manager_mismatch,
      facts.tree_refusal,
      facts.package_window,
      package_r2(facts.package_r2),
      refusal_of(facts.package_rebar),
      facts.native_output
    ]
    |> Kernel.++(facts.trace_problems ++ problems(facts) ++ decided ++ deps)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp any_refusal(decided) do
    Enum.find_value(decided, fn
      {_owner, {:refuse, reason}} -> reason
      _ -> nil
    end)
  end

  defp package_r2({:refuse, reason}), do: reason
  defp package_r2({:error, _why}), do: Reasons.could_not_judge()
  defp package_r2(_result), do: nil

  defp package_rebar({:refuse, reason}), do: reason
  defp package_rebar({:error, _why}), do: Reasons.could_not_judge()
  defp package_rebar({:unjudged, _why}), do: Reasons.could_not_judge()
  defp package_rebar(_result), do: nil

  # The first dependency in compile order that is host-tainted, or whose
  # beams R2 cannot read or whose rebar3 build could not be judged.
  defp closure(deps) do
    Enum.find_value(deps, fn
      {app, %{taint: taint}} when is_binary(taint) ->
        "closure dependency observed the host: #{app} (#{taint})"

      {_app, %{r2: {:error, _}}} ->
        Reasons.could_not_judge()

      {_app, %{rebar: {:unjudged, _}}} ->
        Reasons.could_not_judge()

      _ ->
        nil
    end)
  end

  defp problems(facts) do
    package = facts.ctx.package

    facts.trace_problems ++
      List.wrap(facts.package_window) ++
      error_text(package, facts.package_r2) ++
      error_text(package, facts.package_rebar) ++
      Enum.flat_map(facts.deps, fn {app, result} ->
        error_text(app, result.r2) ++ unjudged_text(app, result.rebar)
      end)
  end

  defp error_text(app, {:error, why}), do: ["#{app}: #{why}"]
  defp error_text(app, {:unjudged, why}), do: ["#{app}: #{why}"]
  defp error_text(_app, _result), do: []

  defp unjudged_text(app, {:unjudged, why}), do: ["#{app}: #{why}"]
  defp unjudged_text(_app, _result), do: []

  # --- observations ------------------------------------------------------------

  defp observations(facts, problems) do
    observed =
      for {owner, {:observe, kind, item}} <- facts.decided,
          do: {kind, Map.put(item, "owner", owner_name(owner))}

    # Foreign priv: kino's own window alone makes more accepted calls than
    # the cap (each Kino.JS module's `File.mkdir_p!/1` probes every directory
    # from `/` down), and they are inert (`ForeignPriv`). Every other
    # window's come first, in order, so the cap keeps the writers'.
    observed = Enum.sort_by(observed, &kino_own_call?(&1, facts.ctx.foreign_priv))

    refusals =
      for {owner, {:refuse, reason}} <- facts.decided,
          do: %{"owner" => owner_name(owner), "reason" => reason}

    facts
    |> caps()
    |> differential_caps(facts.ctx.differential)
    |> Map.new(fn {kind, cap} -> {kind, collect(observed ++ r2_observed(facts), kind, cap)} end)
    |> Map.merge(%{
      "trace_stats" => stats(facts),
      "refusals" => refusals |> Enum.uniq() |> Enum.take(@max_refusals),
      "taint" => for({app, %{taint: t}} when is_binary(t) <- facts.deps, into: %{}, do: {app, t}),
      "guarded_taint" => guarded_taint(facts.guarded),
      "rebar" => rebar_refusals(facts),
      "native_libs" => Enum.take(facts.libs.native, 50),
      "config_unreviewed" => Enum.take(facts.config.unreviewed, 50),
      "nif_check" => if(facts.libs.waived, do: "waived", else: "ok"),
      "tree_check" => tree_summary(facts),
      "rebar3_plugins" => rebar3_plugins(facts),
      "problems" => problems |> Enum.uniq() |> Enum.take(@max_problems)
    })
  end

  # The dependencies whose reviewed guarded-module refusals were waived
  # (`Guarded`), each with the entries and the refusal texts.
  defp guarded_taint(waivers) do
    for {app, %{reasons: reasons, entries: entries}} <- Enum.sort(waivers) do
      %{"app" => app, "entries" => Enum.sort(entries), "reasons" => Enum.sort(reasons)}
    end
  end

  # The rebar3 plugin releases installed for every rebar3 app in the
  # package's closure (`RebarPlugins.releases/2`), each once with the apps
  # that ran it, so the portal can find each build that ran one
  # (`Portal.Precompiled.PluginWatch`). Never cut (review S5 R3): `{:over,
  # record}` past `RebarPlugins.max_releases/0`, which refuses the build.
  defp plugin_record(ctx, scope) do
    scope
    |> Enum.sort()
    |> Enum.filter(&(Context.manager(ctx, &1) == "rebar3" and is_binary(Context.dest(ctx, &1))))
    |> Enum.map(
      &{&1,
       RebarPlugins.releases(
         Context.dest(ctx, &1),
         ctx.rebar_cache,
         ctx.moved_deps,
         record_bases(ctx, &1)
       )}
    )
    |> RebarPlugins.record()
  end

  # The dirs a rebar3 app's record reads its plugins from: `Rebar.base_dirs/2`'s,
  # or `_build` alone when they cannot be judged (the check refuses then).
  defp record_bases(ctx, app) do
    case Rebar.base_dirs(mix_rebar_config(ctx, app), ctx.rebar_base) do
      {:ok, bases} -> bases
      _ -> ["_build"]
    end
  end

  defp rebar3_plugins(%{plugins: {_ok_or_over, record}}), do: record

  defp plugin_refusal(%{plugins: {:over, _record}}),
    do: "rebar3 build runs more than #{RebarPlugins.max_releases()} plugin releases"

  defp plugin_refusal(_facts), do: nil

  defp tree_summary(%{ctx: ctx, scope: scope}) do
    for {app, tree} <- ctx.trees, MapSet.member?(scope, app), into: %{} do
      case tree do
        {:ok, _members} -> {app, "ok"}
        {:differs, detail} -> {app, "differs: " <> detail}
        {:unverified, why} -> {app, "unverified: " <> why}
      end
    end
  end

  defp r2_observed(facts) do
    results = [
      {facts.ctx.package, facts.package_r2} | Enum.map(facts.deps, &{elem(&1, 0), elem(&1, 1).r2})
    ]

    for {app, {:observe, list}} <- results,
        {:observe, kind, path} <- list,
        do: {kind, %{"owner" => owner_name(app), "path" => path}}
  end

  # Without the job's flag the observations are exactly as before it (plan
  # ruling 3): no `foreign_priv` list, not even an empty one. Nor a
  # `holder_calls` one without relocation (S4).
  defp caps(facts) do
    caps = if facts.foreign.flag, do: @caps, else: Map.delete(@caps, "foreign_priv")
    if facts.relocate, do: caps, else: Map.delete(caps, "holder_calls")
  end

  # Likewise without the differential flag: no `varied_reads` list.
  defp differential_caps(caps, true), do: caps
  defp differential_caps(caps, _off), do: Map.delete(caps, "varied_reads")

  defp kino_own_call?({"foreign_priv", %{"owner" => owner}}, %{target: owner}), do: true
  defp kino_own_call?(_observed, _gate), do: false

  # `declared_absent` (round 3, R2-1) is a list the portal decides on
  # (`Portal.Catalog.ModuleIndex`): past its cap, one `truncated` item says
  # so, which refuses there. Each item once, by what it says, not by which
  # window saw it.
  defp collect(observed, "declared_absent" = kind, cap) do
    items =
      observed
      |> Enum.filter(&(elem(&1, 0) == kind))
      |> Enum.map(
        &(&1
          |> elem(1)
          |> Map.take(["kind", "module", "declared", "declared_apps", "via"]))
      )
      |> Enum.uniq()
      |> Enum.sort()

    if length(items) > cap,
      do: Enum.take(items, cap - 1) ++ [%{"kind" => "truncated"}],
      else: items
  end

  defp collect(observed, kind, cap) do
    observed
    |> Enum.filter(&(elem(&1, 0) == kind))
    |> Enum.map(&(&1 |> elem(1) |> public_item()))
    |> Enum.uniq()
    |> Enum.take(cap)
  end

  # What the build observed, without any value a read returned or a write
  # set: values go to `compile_env` and `compile_inputs` only, where a
  # private name is never recorded (`CompileInputs`). Nor a write's time,
  # which only orders it against reads: a `mix.exs` Mix evaluates again
  # makes the same write, which is one item.
  defp public_item(item) do
    item = Map.drop(item, ["returned", "value", "ts", "refusal"])

    case item do
      %{"arg" => %{} = arg} -> %{item | "arg" => Map.delete(arg, "value")}
      _ -> item
    end
  end

  defp stats(%{report: report} = facts) do
    gaps =
      for {app, {:gap, module}} <- [
            {facts.ctx.package, facts.package_rebar} | dep_rebar(facts.deps)
          ],
          into: %{},
          do: {app, module}

    (report.stats || %{})
    |> Map.delete("kind")
    |> Map.merge(%{
      "windows" => length(report.windows),
      "sentinels" => length(report.sentinels),
      "events_read" => length(report.events),
      "children" => map_size(report.children),
      "rebar3_untraced_last" => gaps,
      "config_items" => length(facts.config.items),
      "config_dropped" => facts.config.dropped
    })
    |> put_schedulers_stat(facts.ctx.differential, report.start)
    |> put_foreign_stat(facts)
  end

  # The Mix VM's scheduler count, from the tracer's start line (nil without
  # one), which `Differential` holds a variant to: only with the
  # differential flag, so a verdict without it is main's (review R8).
  defp put_schedulers_stat(stats, true, start),
    do: Map.put(stats, "schedulers_online", schedulers_online(start))

  defp put_schedulers_stat(stats, _off, _start), do: stats

  defp schedulers_online(%{"schedulers_online" => n}) when is_integer(n) and n > 0, do: n
  defp schedulers_online(_start), do: nil

  defp put_foreign_stat(stats, %{foreign: %{stat: nil}}), do: stats

  defp put_foreign_stat(stats, %{foreign: %{stat: stat}}),
    do: Map.put(stats, "foreign_priv", stat)

  defp dep_rebar(deps), do: Enum.map(deps, fn {app, result} -> {app, result.rebar} end)

  defp owned_problem(owner, why) do
    if Compatibility.Portability.probe_text?(why),
      do: "#{window_name(owner)}: #{why}",
      else: why
  end

  defp window_name(owner) when is_binary(owner), do: owner
  defp window_name(_quiet_or_outside), do: "outside"

  defp owner_name(owner) when is_binary(owner), do: owner
  defp owner_name(owner) when is_atom(owner), do: Atom.to_string(owner)
  defp owner_name(owner), do: inspect(owner)
end
