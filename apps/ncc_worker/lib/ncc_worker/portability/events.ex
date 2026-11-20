defmodule NccWorker.Portability.Events do
  @moduledoc """
  Stage 2 of the compile-time trace (precompiled portability spec, R1 step
  4): what one user-extent event means for the window it fell in. Each event
  is ignored, observed, refused, or could not be judged.

  The config and Elixir-version channels are observed here and judged by the
  verdict over the whole closure (`NccWorker.Portability.ConfigReads`, R5,
  and `NccWorker.Portability.ElixirVersion`); their observations keep the
  first frame, its kind and the extent. An Elixir-version read in a closure
  dependency's `mix.exs` goes to R4 (`MixExsSlice`) instead: one that can
  reach a compile-relevant key refuses (`compile-time Elixir patch
  dependence: `, compile options that may differ between patches), unless
  its line holds only direct literal comparisons
  (`MixExsSlice.direct_version_line?/3`), which `ElixirVersion` then judges
  over the build's whole minor; any other is ignored. Everything else is allowed by a narrow rule or refused:

    * OS identity: `system_info(otp_release)` is allowed, and `os:type/0`,
      `os:version/0` or `system_info(os_type)` when the first frame after
      the wrappers is one of the path internals that read it themselves
      (`:ncc_tracer_channels.path_os_frames/0`: `Path.major_os_type/0`,
      `:filename.split/1` and the like, and `:erl_prim_loader`'s unexported
      `pathtype/1`, `normalize/2` and `real_path/4`; never a function that runs a fun it
      was given, so a package callback tail-calling the read is refused).
      `machine`, `smp_support`, `threads` and `heap_type` are allowed
      (constant within an OTP major); `schedulers_online` is ignored only
      when Elixir's type checker reads it to size its pool
      (`:ncc_tracer_channels.checker_pool_frames/0`): the value caps how many
      verification processes run at once and reaches no beam. A
      dependency's `mix.exs` with code outside a plain `defmodule` (inflex's
      `Hex.start()`) starts such a checker in its window. The same read
      from any other frame refuses; `endian` is observed as
      `endian_reads`, a compile input `CompileInputs` records with the
      builder's byte order for the client to compare, wherever it is read
      (judge revision 13); `os:type/0` and `system_info(os_type)` outside
      those path internals are observed as `os_type_reads`, a compile input
      `CompileInputs` records with the builder's OS type (judge revision
      17); every other key refuses, and the
      reason names the key and, when another function than the package's
      made the call, that function (`via`). The tracer
      writes no line for those path-handling reads (it counts them as
      `path_os_reads`): a line would always be ignored here.
      In an epp server process (no user frame, the stack's bottom frame
      `epp:server`/`epp:init_server`), `system_info(machine)`,
      `system_info(otp_release)` and `os:type/0` are its predefined macros
      and ignored; every other read there stays user. `system_info(wordsize)`
      is ignored only when its immediate caller (the event's `caller`) is
      `erlang:big_binary_to_int/2`, OTP converting a big integer literal.
    * OTP code loading (item 5a): erl_prim_loader resolving a beam's path
      for `code:ensure_loaded/1`. Its `system_info(os_type)` reads are path
      handling (`erl_prim_loader:pathtype/1` and friends, above), and its
      `prim_file:read_link/1` reads are ignored when they carry the tracer's
      `code_loading` flag, which it sets only on a stack whose top is
      exactly the shape pinned per toolchain for that read
      (`:ncc_tracer_stack.code_loading_read/4`). The beam read that follows
      is judged as a read; `prim_file:get_cwd/0` is never flagged.
    * Environment reads are build inputs, never refused: `os:getenv/1`
      (with the value the tracer captured), `os:getenv/0` and `os:env/0`
      are observed as `env_reads` for `CompileInputs`; `os:getenv/2` is
      the `os:getenv/1` read below it. Environment and config writes are
      observed (`env_writes`, `config_writes`). Init arguments, programs,
      network, crypto and native loading refuse.
    * Integrity (the trace API, `erts_internal` trace BIFs, `system_flag`,
      reading another process's stack, mailbox or dictionary, unsticking a
      module, the tracer's own API) refuses everywhere, `mix.exs` included.
      A module reloaded under the trace drops its patterns, which the
      tracer's integrity check reports for the window instead.
    * Install locations: `lib_dir`/`priv_dir` of a closure app or an
      OTP/Elixir app; nothing else.
    * Reads of a natively built dependency's `ebin` (`Context.native_ebin_app/2`)
      are observed as `native_beam_reads`, carrying the refusal they would
      otherwise be; `NccWorker.Portability` refuses each unless that
      dependency's own compile is shown clean (judge revision 15).
    * A closure dependency's own compile (its window, never its `mix.exs`)
      reading the bytes of a file (`file:read_file`, an `open` for reading,
      `file:consult/1`, `erl_prim_loader:get_file/1`) under its own source
      `priv`, reached through the link Mix made from its build `priv`
      (`Context.linked_priv_file/3`), that `Context.readable?/2` does not
      allow (a natively built dependency's `priv`), is observed as
      `own_priv_reads`, carrying the refusal it would otherwise be:
      rustler's `Mix.Tasks.Rustler.New` embedding its own templates.
      `NccWorker.Portability` refuses each unless that dependency's source
      tree is its verified tarball's after the compile and holds the file
      (judge revision 23).
    * Reads: `Context.readable?/2` of the real path, relative paths and
      `get_cwd` against the window's dependency (`Context.cwd/2`). A read
      file or directory listing in a closure dependency whose tree matched
      its tarball before the compile must still be the tarball's
      (`Context.tree_check/3`, item 5e); one that no longer is cannot be
      judged. A path such a dependency's tarball does not hold at all, read
      while its own `mix.exs` is evaluated and outside `priv`
      (`Context.absent_from_tree?/3`), is decided by that check too, not
      refused for missing from the Hex file list.
    * Writes: only under the window's own `ebin` (`Context.writable?/3`); a
      rename's source too, a copy's source must be readable. Any symlink or
      hard link refuses, even inside `ebin`: the judge resolves paths after
      the build, so a link there can stand for a read of any target. The
      package's own compile (its window, never its `mix.exs`) may also
      write into its own build `priv` when that is a directory of its own
      (`Context.own_priv/2`); such a write is observed as `priv_writes`,
      with the refusal it would be, since the judge allows it only after a
      second build (`NccWorker.Portability.PrivRepro`, judge revision 21).
      So is `File.mkdir_p/1` on Elixir 1.20 asking each directory above that
      `priv` whether it is one (`priv_probes`): `:file.make_dir/1` from the
      toolchain's `File.do_mkdir_p/1`, and `file:read_file_info/2` from the
      toolchain's `elixir_utils:read_file_type/2`, which hands its caller the
      file type alone. Anywhere else these refuse as before, and a write
      into another package's `priv` always does. A Mix alias of a
      dependency's own project, in the process Mix runs its tasks in,
      copying one file of its own source tree onto another, and the mode
      `File.cp/3` writes onto the copy, made by the toolchain's
      `File.do_cp_file/4` (never a package's own `File.copy/3`, which may
      copy part of a file), are observed as `own_tree_copies`
      (phoenix's `copy_core_components/1`), carrying the refusal they would
      otherwise be: `NccWorker.Portability` refuses each unless the copy
      changed no byte of that dependency's verified tree (judge revision
      27).
    * Foreign priv (`ForeignPriv.decide/3`, with the job's `foreign_priv`
      flag and an open gate only): kino's reviewed `Kino.JS` calls into its
      build `priv/assets/<d>` are observed as `foreign_priv`, carrying the
      refusal they would otherwise be; any other read, listing or stat
      there refuses (`compile-time read of kino's asset archives: `), any
      other write there refuses as before. The judge settles them
      (`ForeignPriv.settle/2`).
    * A user `set_cwd` refuses: it changes what every later relative path
      names.
    * A call into a natively built dependency refuses in the package's
      window and outside every window, and is observed in another
      dependency's window, where it is observed (`native_calls`) and the
      judge taints that dependency for it (R3). So is a call into a holder
      module of a relocation's second build (`root_holder`, observed as
      `holder_calls`, `NccWorker.Portability.Relocate`).
    * A host read whose first user frame is in a closure dependency's
      `mix.exs` goes to R4 (`MixExsSlice`): allowed ones are observed as
      `mix_exs_allowed`. Integrity, writes, links, `set_cwd`, native
      loading and running a program (`os:cmd`, `open_port`, and so
      `System.cmd`/`Port.open`) never go to R4: they are not observations a
      slice can follow, and refuse directly. Looking a program up
      (`os:find_executable`) is an observation and does go to R4.
    * A probe of a module the tracer loaded (whether it is loaded, or can
      be), a call into one, and listing the loaded modules are judged by
      `NccWorker.Portability.Probes`; a nested compile only marks its
      window for it. So is a probe of a module of an installed OTP or
      Elixir application off every compile's code path (`otp_app`), which
      refuses off the prober's path: Mix prunes a dependency's path to its
      closure's applications, Mix.install does not.
    * Mix state (`mix_state`, precompiled judge refinements item 2): the
      target read (`Mix.target/0,1`, `Mix.State.get`/`fetch` of `:target`,
      `:ets.lookup`/`lookup_element` of `Mix.State`'s `:target`, by the
      table's name or its id) refuses wherever it is made, a dependency's
      `mix.exs` included (a literal one there is native by the static scan
      already). Only the Mix functions that read the target for Mix's own
      work are Mix's (`ncc_tracer_stack:target_read_by_mix/2`); anything
      else, Mix's fun-calling helpers included, is the package's read.
      `Mix.Project.build_path`, `app_path` and `compile_path` are observed
      as `mix_project_paths` and refuse nothing (refusing them would refuse
      legitimate Mix compilers; `config/0` is not traced at all). Reading
      the table other ways (`:ets.match_object`, `select`, `tab2list`,
      `first`/`next`, `match`) is a known gap. Any other `mix_state`
      function could not be judged.
    * Our generated project's own `mix.exs` (owner `:wrapper`) is ignored.

  Fail closed: an event whose stack the tracer could not judge (extent
  `unjudged`), whose extent or channel this module does not know, or whose
  shape is not an event's, could not be judged (`{:unjudged, reason}`), never
  allowed. That check comes before every rule, the `:wrapper` owner's
  included: an unjudged event is never ignored, wherever it is attributed.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.{Context, ForeignPriv, MixExsSlice, Probes}

  # Shared with the tracer, which counts these path-handling reads rather
  # than writing them (`:ncc_tracer_channels.path_os_read/3`): the rule
  # below and the tracer's drop must name the same first frames.
  @path_frames :ncc_tracer_channels.path_os_frames()
  @host_channels ~w(env programs network crypto native)
  @probe_channels ~w(probe app_call loaded_modules)
  # Host reads R4 may allow when made from a dependency's mix.exs. Of the
  # `programs` channel only the lookup: running a program (`os:cmd`,
  # `open_port`, so `System.cmd` and `Port.open`) does things the trace
  # cannot follow, so it refuses directly.
  @slice_channels ~w(os_identity env network crypto install file_read)
  @slice_programs ~w(os:find_executable/1 os:find_executable/2)
  @extents ~w(frame dispatcher truncated lineage)
  @links ~w(file:make_symlink/2 file:make_link/2 prim_file:make_symlink/2 prim_file:make_link/2)
  @epp_server ~w(server init_server)
  @max_mix_exs_bytes 1024 * 1024
  @mix_paths ~w(build_path app_path compile_path)
  # Judge revision 21: the calls `File.mkdir_p/1` makes above the package's
  # own `priv`, and the writes that set no file's bytes (a directory, a
  # removal, a file's metadata).
  @mkdir_p {"Elixir.File", "do_mkdir_p", 1}
  @type_probe {"elixir_utils", "read_file_type", 2}
  # Judge revision 23: the reads that hand their caller a file's bytes and
  # nothing about the file (no size, time, owner or listing).
  @content_reads ~w(file:read_file/1 file:read_file/2 prim_file:read_file/1
                    prim_file:read_file/2 file:open/2 prim_file:open/2 file:consult/1
                    erl_prim_loader:get_file/1)
  @not_content ~w(file:make_dir/1 prim_file:make_dir/1 file:del_dir/1 file:del_dir_r/1
                  prim_file:del_dir/1 file:delete/1 prim_file:delete/1 file:write_file_info/2
                  file:write_file_info/3 prim_file:write_file_info/2 prim_file:write_file_info/3
                  file:change_mode/2 file:change_time/2 file:change_time/3)
  # Judge revision 27: the copies that set one file's bytes to another's,
  # the write `File.cp/3` then makes of the source's mode onto the copy
  # (`File.write_stat/3`), the one function that makes all three for
  # `File.cp/3` and `File.cp_r/3` (`File.do_cp_file/4`: `:file.copy/2` onto
  # `{dest, [:exclusive]}`, then `File.copy/2`'s whole-file `:file.copy/3`,
  # then the source's mode), the frame Mix's alias runner leaves when a fun
  # of the project's aliases tail-called one, and the bottom frame of the
  # process `elixir -S mix` runs its tasks in (`Kernel.CLI`'s exec fun),
  # Elixir 1.17 to 1.20.
  @copies ~w(file:copy/2 file:copy/3)
  @copy_modes ~w(file:write_file_info/3)
  @cp_file {"Elixir.File", "do_cp_file", 4}
  @run_alias {"Elixir.Mix.Task", "run_alias", 6}
  @mix_main {"Elixir.Kernel.CLI", "-exec_fun/2-fun-0-"}

  # Compile-time env reads are build inputs (compile-time inputs spec):
  # observed with what they returned, never refused. os:getenv/2 reaches
  # os:getenv/1 through a remote call, whose event is the read.
  @env_reads ~w(os:getenv/1)
  @env_all ~w(os:getenv/0 os:env/0)

  # Item 5d: keys constant within an OTP major on every supported platform
  # (BEAM; SMP and threads since OTP 21; private heaps). The client checks
  # the OTP major. Exact atom keys only: `term_bin` renders a tuple key
  # (`{allocator, ...}`) as something never in this list.
  @same_within_major ~w(machine smp_support threads heap_type)
  # Elixir's type checker sizing its pool of verification processes: the
  # frame (shared with the tracer, which sets a canary on its module) and
  # the bottom frame of the process `:proc_lib.start_link/3` starts for it.
  @checker_pool_frames :ncc_tracer_channels.checker_pool_frames()
  @proc_lib_init %{"module" => "proc_lib", "function" => "init_p_do_apply", "arity" => 3}
  # The toolchain functions whose own `:os.type/0` read keeps only the
  # family (`{major, _} = :os.type()`) and that run no package code: their
  # read is an `os_type` input without the name. Shared with the tracer,
  # which sets a pattern on each so a reload of the module fails the check;
  # pinned on the running toolchain by `NccWorker.Tracer.OsFamilyCallersTest`.
  @os_family_callers :ncc_tracer_channels.os_family_callers()

  @type decision ::
          :ignore
          | {:observe, String.t(), map()}
          | {:refuse, String.t()}
          | {:unjudged, String.t()}

  @typedoc "Per `mix.exs` real path, its `MixExsSlice.analyse/1` result."
  @type slices :: %{String.t() => {:ok, MixExsSlice.t()} | {:refuse, String.t()}}

  @doc false
  # The callers whose `:os.type/0` read is recorded as the family alone, as
  # `{module, function, arity}` text (`os_type_scope/1`).
  @spec os_family_callers() :: [{String.t(), String.t(), non_neg_integer()}]
  def os_family_callers, do: @os_family_callers

  @doc """
  Decides one event for `owner` (`Context.owner/2`, or a child VM's app).
  `slices` holds `mix_exs_slices/2`'s analyses; a `mix.exs` missing from it
  is read and analysed here.
  """
  @spec decide(term(), Context.t(), term(), slices()) :: decision()
  def decide(event, ctx, owner, slices \\ %{}) do
    case shape(event) do
      :ok -> owned(event, ctx, owner, slices)
      {:unjudged, _why} = unjudged -> unjudged
    end
  end

  @doc """
  The R4 analyses of every closure dependency's `mix.exs` that one of
  `owned_events` (`{owner, event}`) has its first user frame in, each file
  read and analysed once.
  """
  @spec mix_exs_slices(Context.t(), [{term(), map()}]) :: slices()
  def mix_exs_slices(ctx, owned_events) do
    owned_events
    |> Enum.map(fn {owner, event} -> Context.mix_exs(ctx, event, owner) end)
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
    |> Map.new(&{&1, analyse(&1)})
  end

  defp shape(%{"channel" => channel, "mfa" => mfa, "arg" => arg, "extent" => extent})
       when is_binary(channel) and is_binary(mfa) and is_map(arg) do
    cond do
      extent == "unjudged" -> unjudged("unjudged stack: #{mfa}")
      extent not in @extents -> unjudged("unknown stack extent #{inspect(extent)}: #{mfa}")
      true -> :ok
    end
  end

  defp shape(%{"mfa" => mfa}) when is_binary(mfa), do: unjudged("malformed event: #{mfa}")
  defp shape(_event), do: unjudged("malformed event")

  defp unjudged(why), do: {:unjudged, "#{Reasons.could_not_judge()} (#{why})"}

  defp owned(_event, _ctx, :wrapper, _slices), do: :ignore

  defp owned(%{"channel" => "env", "mfa" => mfa} = event, ctx, owner, slices)
       when mfa in @env_reads,
       do: {:observe, "env_reads", env_read(event, ctx, owner, slices)}

  defp owned(%{"channel" => "env", "mfa" => "os:getenv/2"}, _ctx, _owner, _slices), do: :ignore

  defp owned(%{"channel" => "env", "mfa" => mfa} = event, _ctx, _owner, _slices)
       when mfa in @env_all,
       do:
         {:observe, "env_reads", Map.merge(summary(event), %{"ts" => event["ts"], "all" => true})}

  defp owned(%{"channel" => "elixir_version"} = event, ctx, owner, slices) do
    case Context.mix_exs(ctx, event, owner) do
      path when is_binary(path) -> version_in_mix_exs(event, path, slices)
      _ -> {:observe, "elixir_version", traced_summary(event)}
    end
  end

  defp owned(%{"channel" => channel, "mfa" => mfa} = event, ctx, owner, slices) do
    case channel(channel, event, ctx, owner) do
      {:refuse, _} = refusal when channel in @slice_channels ->
        in_mix_exs(event, ctx, owner, slices, refusal)

      {:refuse, _} = refusal when channel == "programs" and mfa in @slice_programs ->
        in_mix_exs(event, ctx, owner, slices, refusal)

      other ->
        other
    end
  end

  defp channel("os_identity", event, _ctx, _owner) do
    if epp_predef?(event), do: :ignore, else: os_identity(event)
  end

  defp channel(channel, event, _ctx, _owner) when channel in @host_channels,
    do: {:refuse, host_read(event, event["arg"]["path"])}

  defp channel("integrity", event, _ctx, _owner),
    do: {:refuse, "compile-time tracing or system flag: " <> event["mfa"]}

  defp channel("cwd", event, _ctx, _owner), do: {:refuse, host_read(event, event["arg"]["path"])}

  defp channel("config", event, _ctx, _owner),
    do: {:observe, "config_reads", Map.put(traced_summary(event), "returned", event["returned"])}

  # Writes a compile makes to the environment or the application env
  # (compile-time inputs spec, section 1): observed for `CompileInputs`,
  # which tells a read of the build's own value from a read of the host's.
  # Writing changes nothing outside the compile, so it never refuses.
  defp channel("env_write", event, _ctx, _owner), do: {:observe, "env_writes", env_write(event)}

  defp channel("config_write", event, _ctx, _owner),
    do: {:observe, "config_writes", summary(event)}

  # Item 2's gap: Mix state read through a module name. The target refuses
  # wherever it is made, a dependency's `mix.exs` included: a literal
  # `Mix.target` there already makes the dependency native by the static
  # scan (`BuildCache.reads_target?/1`), so an exemption would only help the
  # reads that scan cannot see. The build paths are observed only (see the
  # moduledoc). Any other function could not be judged.
  defp channel("mix_state", %{"arg" => %{"fun" => "target"}} = event, _ctx, _owner),
    do: {:refuse, host_read(event)}

  defp channel("mix_state", %{"arg" => %{"fun" => fun}} = event, _ctx, _owner)
       when fun in @mix_paths,
       do: {:observe, "mix_project_paths", summary(event)}

  defp channel("install", event, ctx, _owner), do: install(event, ctx)
  defp channel("file_read", event, ctx, owner), do: file_read(event, ctx, owner)
  defp channel("file_write", event, ctx, owner), do: file_write(event, ctx, owner)
  defp channel("native_closure", event, ctx, owner), do: native_closure(event, ctx, owner)
  defp channel("root_holder", event, ctx, owner), do: root_holder(event, ctx, owner)

  # Marks its window (`Context.nested`); refuses nothing by itself.
  defp channel("nested_compile", _event, _ctx, _owner), do: :ignore

  defp channel(channel, event, ctx, owner) when channel in @probe_channels,
    do: Probes.decide(event, ctx, owner)

  defp channel(other, event, _ctx, _owner),
    do: unjudged("unknown channel #{other}: #{event["mfa"]}")

  # The Erlang preprocessor's predefined macros (`?MACHINE`, `?OTP_RELEASE`,
  # the OS family): read by an epp server, a process `Record.extract/2`
  # (`from_lib:`) and `-include` start from a module body, so user by
  # lineage. Only these reads, and only with no user frame on a stack seen
  # whole down to epp's own server loop (the tracer's `bottom` frame).
  defp epp_predef?(%{"extent" => "lineage", "user" => nil, "bottom" => bottom} = event) do
    match?(%{"module" => "epp", "function" => f} when f in @epp_server, bottom) and
      epp_read?(event)
  end

  defp epp_predef?(_event), do: false

  defp epp_read?(%{"mfa" => "os:type/0"}), do: true

  defp epp_read?(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => key}}),
    do: key in ["machine", "otp_release"]

  defp epp_read?(_event), do: false

  # The byte order (`System.endianness/0`, nx picking a float layout): a
  # compile input, never a refusal, whoever reads it and from wherever. Its
  # value is the machine's alone, the tracer's start line records it, and
  # `CompileInputs` turns the read into an `endian` item the client compares
  # with its own. Only the exact atom key: a tuple key renders otherwise.
  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "endian"}} = e),
    do: {:observe, "endian_reads", summary(e)}

  # OTP's own conversion of a big integer (`binary_to_integer/1` on a long
  # literal traps to erlang:big_binary_to_int/2) sizes its chunks by the
  # word size: 8 on every supported host, and not part of the result.
  defp os_identity(%{
         "mfa" => "erlang:system_info/1",
         "arg" => %{"key" => "wordsize"},
         "caller" => %{"module" => "erlang", "function" => "big_binary_to_int", "arity" => 2}
       }),
       do: :ignore

  # Item 5a: the os_type read erl_prim_loader:pathtype/1 makes while OTP
  # loads a module into the calling process, which the tracer flags only on
  # that read's pinned stack shape (`:ncc_tracer_stack.code_loading_read/4`).
  # Deliberate defence in depth: a real pathtype os_type read is already
  # accepted as path handling (its first frame is a path frame), so this
  # clause only matters if that list ever loses the frame.
  defp os_identity(%{
         "mfa" => "erlang:system_info/1",
         "arg" => %{"key" => "os_type", "code_loading" => true}
       }),
       do: :ignore

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "otp_release"}}),
    do: :ignore

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => "os_type"}} = e),
    do: path_handling(e, &os_type_read/1)

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => key}})
       when key in @same_within_major,
       do: :ignore

  # `Module.ParallelChecker.init/1` defaults `:max_concurrency` to
  # `max(:erlang.system_info(:schedulers_online), 2)` when `get/0` starts a
  # checker for a module defined outside a parallel compile: a dependency's
  # `mix.exs` with code outside a plain `defmodule`, which Mix evaluates in
  # its window, or a nested compile in a package process. The value only
  # caps how many cache and check processes run at once (Elixir 1.19 and
  # 1.20, pinned by `NccWorker.Tracer.CheckerPoolTest`). The read is ignored
  # only from that frame, the toolchain's code calling it directly, in a
  # process proc_lib started, on a whole stack with no package frame. The
  # same read from anywhere else refuses (codepagex's `Task.async_stream/3`,
  # a module body's `System.schedulers_online/0`).
  defp os_identity(
         %{
           "mfa" => "erlang:system_info/1",
           "arg" => %{"key" => "schedulers_online"},
           "extent" => "lineage",
           "user" => nil,
           "first_kind" => "toolchain",
           "caller_kind" => "toolchain",
           "first" => %{"module" => m, "function" => f, "arity" => a},
           "caller" => %{"module" => m, "function" => f, "arity" => a},
           "bottom" => %{"module" => _, "function" => _, "arity" => _} = bottom
         } = e
       ) do
    if {m, f, a} in @checker_pool_frames and
         Map.take(bottom, ~w(module function arity)) == @proc_lib_init,
       do: :ignore,
       else: {:refuse, host_read(e)}
  end

  defp os_identity(%{"mfa" => "erlang:system_info/1"} = e), do: {:refuse, host_read(e)}
  defp os_identity(%{"mfa" => "os:type/0"} = e), do: path_handling(e, &os_type_read/1)
  defp os_identity(e), do: path_handling(e, &{:refuse, host_read(&1)})

  # A path internal's own read (the tracer's `path_os_frames/0`) is ignored;
  # any other is `otherwise`'s to decide.
  defp path_handling(%{"first" => %{"module" => m, "function" => f, "arity" => a}} = e, otherwise) do
    if {m, f, a} in @path_frames, do: :ignore, else: otherwise.(e)
  end

  defp path_handling(e, otherwise), do: otherwise.(e)

  # The OS type (`:os.type/0`, `system_info(os_type)`; kino's `File.rm_rf!/1`
  # in `Kino.JS.__before_compile__/1`): a compile input, never a refusal,
  # whoever reads it and from wherever (judge revision 17). The tracer's
  # start line records the value and `CompileInputs` turns the reads into
  # one `os_type` item the client compares with its own. `scope` says what
  # of the value the read can reach (`os_type_scope/1`).
  defp os_type_read(e),
    do: {:observe, "os_type_reads", Map.put(summary(e), "scope", os_type_scope(e))}

  # `family`: the toolchain's `File.rm_rf/1` called `:os.type/0` itself, and
  # it keeps only the family (`{major, _} = :os.type()`, Elixir 1.17 to
  # 1.20), to pick how it lists and deletes. `covered`: OTP's `os:type/0`
  # reading `system_info(os_type)`, whose own `os:type/0` event (always
  # traced) says who got the value. Anything else can reach the whole tuple.
  # The caller is the frame right below the read, before any wrapper is
  # stripped, and `caller_kind` the tracer's verdict on its module's loaded
  # code: a package's own `File` is never the toolchain's.
  defp os_type_scope(%{"mfa" => "os:type/0", "caller_kind" => "toolchain"} = e) do
    if Enum.any?(@os_family_callers, &caller?(e, &1)), do: "family", else: "full"
  end

  defp os_type_scope(%{"mfa" => "erlang:system_info/1", "caller_kind" => "toolchain"} = e) do
    if caller?(e, {"os", "type", 0}), do: "covered", else: "full"
  end

  defp os_type_scope(_e), do: "full"

  defp caller?(%{"caller" => %{"module" => m, "function" => f, "arity" => a}}, {m, f, a}),
    do: true

  defp caller?(_e, _mfa), do: false

  defp install(%{"arg" => %{"what" => what, "app" => app} = arg} = e, ctx)
       when what in ["lib_dir", "priv_dir"] and is_binary(app) do
    if arg["toolchain_app"] == true or Context.dep?(ctx, app),
      do: :ignore,
      else: {:refuse, host_read(e)}
  end

  defp install(e, _ctx), do: {:refuse, host_read(e)}

  # Item 5a: the link reads erl_prim_loader:real_path/4 makes of every path
  # prefix while OTP loads a module into the calling process, flagged by the
  # tracer only on that read's pinned stack shape. Only this MFA: get_cwd is
  # never flagged, and the beam read that follows is still judged as a read.
  defp file_read(%{"mfa" => "prim_file:read_link/1", "arg" => %{"code_loading" => true}}, _, _),
    do: :ignore

  defp file_read(%{"arg" => %{"cwd" => true}} = e, ctx, owner) do
    case Context.cwd(ctx, owner) do
      nil -> {:refuse, host_read(e)}
      cwd -> readable(e, ctx, cwd, owner)
    end
  end

  defp file_read(%{"arg" => %{"path" => path}} = e, ctx, owner) when is_binary(path) do
    case ForeignPriv.decide(e, ctx, owner) do
      :pass -> readable(e, ctx, path, owner)
      decision -> foreign(decision, e, host_read(e, path))
    end
  end

  defp file_read(e, _ctx, _owner), do: {:refuse, host_read(e)}

  # Readable by `Context.readable?/2` and, for a closure dependency whose
  # tree matched its tarball before the compile, still the tarball's (item
  # 5e, `Context.tree_check/3`). A tree changed since that check is no
  # refusal (it was the tarball's when checked) but cannot be judged. A path
  # such a tree's tarball does not hold, read while that dependency's own
  # mix.exs is evaluated (`Context.absent_from_tree?/3`: a wildcard over
  # `guides/` the package left out), is decided by the same check: absent
  # when checked, absent on the user's side. A missing path under any
  # dependency's priv refuses first (`Context.missing_under_priv?/2`). A
  # relocation's holder beam read by another window is a holder call first.
  defp readable(e, ctx, path, owner) do
    real = Context.resolve(ctx, path, owner)

    case Context.holder_ebin_app(ctx, real) do
      holder when holder != nil and holder != owner -> root_holder(e, ctx, owner)
      _ -> readable_real(e, ctx, path, owner, real)
    end
  end

  defp readable_real(e, ctx, path, owner, real) do
    cond do
      Context.missing_under_priv?(ctx, real) ->
        {:refuse, host_read(e, path)}

      Context.readable?(ctx, real) or absent_in_mix_exs?(e, ctx, owner, real) ->
        tree_read(e, ctx, real)

      app = Context.native_ebin_app(ctx, real) ->
        {:observe, "native_beam_reads", native_beam_read(e, app, host_read(e, path))}

      file = own_priv_read(e, ctx, owner, real) ->
        {:observe, "own_priv_reads",
         Map.merge(summary(e), %{
           "app" => owner,
           "source" => file,
           "ts" => e["ts"],
           "refusal" => host_read(e, path)
         })}

      type_probe?(e, ctx, owner, path) ->
        {:observe, "priv_probes", Map.put(summary(e), "refusal", host_read(e, path))}

      true ->
        {:refuse, host_read(e, path)}
    end
  end

  # Judge revision 23: a dependency's own compile (its window, never its
  # `mix.exs`, never another dependency's window) reading the bytes of a
  # file in its own source `priv` through the link Mix made from its build
  # `priv` (`Context.linked_priv_file/3`, the real path): rustler's
  # `Mix.Tasks.Rustler.New` embedding its templates. Only a content read
  # (`@content_reads`), never a probe or a listing. Observed, with the
  # refusal it was before and the file relative to the source dir: the
  # judge allows it only when that dependency's whole source tree is its
  # verified tarball's after the compile and holds the file
  # (`NccWorker.Portability`). A read of another dependency's `priv`, a
  # `priv` of its own (a directory, which a compile may have written) and a
  # path that resolves out of the source `priv` keep their treatment.
  defp own_priv_read(%{"mfa" => mfa, "arg" => arg} = e, ctx, owner, real)
       when mfa in @content_reads and is_map(arg) do
    if arg["listing"] != true and Context.dep?(ctx, owner) and
         Context.mix_exs(ctx, e, owner) == nil,
       do: Context.linked_priv_file(ctx, owner, real)
  end

  defp own_priv_read(_e, _ctx, _owner, _real), do: nil

  # Judge revision 21: whether a directory above the package's own `priv`
  # is one (`Context.above_own_priv?/3`), asked by the package's own compile
  # through the toolchain's `elixir_utils:read_file_type/2` (`File.dir?/1`,
  # which `File.mkdir_p/1` calls on each of them), which hands its caller
  # the file type alone, never a size, a time or an owner. Observed, with
  # the refusal it was before: allowed only together with the second build
  # (`NccWorker.Portability`), whose build dir has none of these
  # directories, so a path the package named itself is refused there.
  defp type_probe?(%{"mfa" => "file:read_file_info/2"} = e, ctx, owner, path) do
    own_compile?(e, ctx, owner) and toolchain_caller?(e, @type_probe) and
      Context.above_own_priv?(ctx, path, owner)
  end

  defp type_probe?(_e, _ctx, _owner, _path), do: false

  # Judge revision 15: a read in a natively built dependency's `ebin` (the
  # 1.20 type checker reading a remote module's beam) is the judge's to
  # decide once it knows whether that dependency's own compile was clean
  # (`NccWorker.Portability`). The refusal it would be today travels with
  # it: anything short of a clean dependency gives exactly that.
  defp native_beam_read(e, app, refusal),
    do: Map.merge(summary(e), %{"app" => app, "ts" => e["ts"], "refusal" => refusal})

  defp tree_read(e, ctx, real) do
    case Context.tree_check(ctx, real, e["arg"]["listing"] == true) do
      :ok ->
        :ignore

      {:differs, app, detail} ->
        unjudged("dependency tree changed after the check: #{app} (#{detail})")
    end
  end

  # Only while the dependency's own mix.exs is evaluated (its first user
  # frame is there), and only in that dependency's tree.
  defp absent_in_mix_exs?(e, ctx, owner, real) do
    case Context.mix_exs(ctx, e, owner) do
      path when is_binary(path) ->
        app = Enum.find(Map.keys(ctx.deps), &(Context.dest(ctx, &1) == Path.dirname(path)))
        Context.absent_from_tree?(ctx, app, real)

      _ ->
        false
    end
  end

  defp file_write(%{"mfa" => mfa, "arg" => arg}, _ctx, _owner) when mfa in @links,
    do: {:refuse, "compile-time write outside ebin: #{mfa} #{show(arg["path"])} (a link)"}

  defp file_write(%{"arg" => arg} = e, ctx, owner) do
    case ForeignPriv.decide(e, ctx, owner) do
      :pass -> write_as_today(e, arg, ctx, owner)
      decision -> foreign(decision, e, outside_ebin(e, [arg["path"]]))
    end
  end

  # Foreign priv spec 3.2 and 3.5 (`ForeignPriv.decide/3`): a reviewed Kino.JS
  # call is observed with the refusal it would otherwise be; any other read
  # under kino's priv/assets refuses as a read of its archives, any other
  # write as the write outside ebin it always was.
  defp foreign({:accept, item}, e, refusal),
    do:
      {:observe, "foreign_priv", e |> summary() |> Map.merge(item) |> Map.put("refusal", refusal)}

  defp foreign(:refuse_read, e, _refusal),
    do:
      {:refuse,
       Reasons.foreign_priv_read() <> e["mfa"] <> path_part(e["arg"]["path"]) <> where(e)}

  defp foreign(:refuse_write, _e, refusal), do: {:refuse, refusal}

  defp write_as_today(e, arg, ctx, owner) do
    targets = [arg["path"] | if(arg["from_kind"] == "write", do: [arg["from"]], else: [])]
    own = own_compile?(e, ctx, owner)

    # Filtered, not found: a missing (`nil`) target is itself the bad one.
    case Enum.reject(targets, &Context.writable?(ctx, &1, owner)) do
      [] ->
        copy_source(e, ctx, owner)

      outside ->
        cond do
          own and mkdir_p_probe?(e, ctx, owner) ->
            {:observe, "priv_probes", Map.put(summary(e), "refusal", outside_ebin(e, outside))}

          own and Enum.all?(outside, &Context.own_priv_path(ctx, &1, owner)) ->
            own_priv_write(e, ctx, owner, outside)

          true ->
            own_tree_copy(e, ctx, owner, outside)
        end
    end
  end

  # Judge revision 27: a Mix alias of the dependency's own project copying
  # one file of its own source tree onto another (phoenix's `compile:
  # [&copy_core_components/1, "compile"]`, which copies
  # `installer/templates/phx_web/components/core_components.ex.eex` onto
  # `priv/templates/phx.gen.live/core_components.ex.eex`), and the source's
  # mode `File.cp/3` writes onto the copy after it. Only in the process Mix
  # runs the dependency's tasks in (`mix_alias?/3`), so the copy is done
  # before Mix goes on, and never in a natively built dependency
  # (`Context.own_tree_path/3`). Observed, with the refusal it was before:
  # the judge allows a copy only when the verified tarball holds both files
  # with the same bytes and the whole tree is still exactly the tarball's
  # after the compile, and the mode write only onto such a copy
  # (`NccWorker.Portability`), so no byte of the tree ever changed. Only
  # as the toolchain's `File.do_cp_file/4` makes them (`@cp_file`, the
  # frame right below the call): the trace keeps neither a copy's byte
  # count nor the modes it opens either file with, so a package's own
  # `:file.copy/3` or `File.copy/3` could cut a file short, append to it or
  # write it compressed, and a package's own `File.write_stat/3` set any
  # mode, and still look like this copy. `"path"`
  # and `"source"` (the copy's, `nil` for the mode write) are relative to
  # the dependency's source dir. Anything else refuses.
  defp own_tree_copy(%{"mfa" => mfa} = e, ctx, owner, [target])
       when mfa in @copies or mfa in @copy_modes do
    with true <- toolchain_caller?(e, @cp_file),
         true <- mix_alias?(e, ctx, owner),
         path when is_binary(path) <- Context.own_tree_path(ctx, target, owner),
         {:ok, source} <- copied_from(e, ctx, owner) do
      {:observe, "own_tree_copies",
       Map.merge(summary(e), %{
         "app" => owner,
         "path" => path,
         "source" => source,
         "ts" => e["ts"],
         "refusal" => outside_ebin(e, [target])
       })}
    else
      _ -> {:refuse, outside_ebin(e, [target])}
    end
  end

  defp own_tree_copy(e, _ctx, _owner, outside), do: {:refuse, outside_ebin(e, outside)}

  # A copy's source, in the dependency's own tree, never its destination
  # (`File.cp/3` compares the two with `Path.expand/1` only, so through
  # Mix's link from the build `priv` it copies a file onto itself, which
  # empties it), and readable as a read of it (`copy_source/3`); the mode
  # write has none.
  defp copied_from(
         %{"mfa" => mfa, "arg" => %{"from_kind" => "read", "from" => from, "path" => to}} = e,
         ctx,
         owner
       )
       when mfa in @copies do
    with source when is_binary(source) <- Context.own_tree_path(ctx, from, owner),
         true <- source != Context.own_tree_path(ctx, to, owner),
         :ignore <- copy_source(e, ctx, owner),
         do: {:ok, source}
  end

  defp copied_from(%{"mfa" => mfa}, _ctx, _owner) when mfa in @copy_modes, do: {:ok, nil}

  defp copied_from(_e, _ctx, _owner), do: nil

  # Made in the process `elixir -S mix` runs its tasks in (its stack seen
  # whole, so the bottom frame is where it started, and the very process
  # the window's sentinel fired in, `Context.driver/2`: `Kernel.CLI.run/1`
  # is public, so package code can start another process with that bottom
  # frame and run it beside the compiler's workers), by a fun of the
  # window's own project aliases Mix's alias runner called: one that
  # tail-called the call (Mix's runner the first frame, no package frame
  # left), or one whose frame is in that dependency's own `mix.exs`. Only
  # in that dependency's own window (`Context.window_of/2`), where Mix
  # runs it in that dependency's source dir: a fun of one dependency's
  # `mix.exs` (its owner) that another's alias runs copies, by a relative
  # path, in the other's tree, which `Context.own_tree_path/3` would
  # resolve in the owner's.
  defp mix_alias?(%{"bottom" => %{"module" => m, "function" => f}} = e, ctx, owner)
       when {m, f} == @mix_main,
       do:
         Context.dep?(ctx, owner) and Context.window_of(ctx, e["ts"]) == owner and
           is_binary(e["pid"]) and e["pid"] == Context.driver(ctx, owner) and
           (alias_runner?(e) or own_mix_exs?(e, ctx, owner))

  defp mix_alias?(_e, _ctx, _owner), do: false

  defp alias_runner?(%{"extent" => "dispatcher", "user" => nil, "first" => first})
       when is_map(first),
       do: {first["module"], first["function"], first["arity"]} == @run_alias

  defp alias_runner?(_e), do: false

  defp own_mix_exs?(%{"extent" => "frame"} = e, ctx, owner) do
    case Context.mix_exs(ctx, e, owner) do
      path when is_binary(path) -> Path.dirname(path) == Context.dest(ctx, owner)
      _ -> false
    end
  end

  defp own_mix_exs?(_e, _ctx, _owner), do: false

  defp outside_ebin(%{"arg" => %{"ram" => true}} = e, _outside),
    do: "compile-time write outside ebin: #{e["mfa"]} (an in-memory file)"

  defp outside_ebin(e, [bad | _]), do: "compile-time write outside ebin: #{e["mfa"]} #{show(bad)}"

  # Judge revision 21: the package's own compile writing into its own build
  # `priv` (`Context.own_priv/2`; kino's `Kino.JS.__before_compile__/1`
  # packing each module's assets there). Observed, with the refusal it was
  # before: the judge allows it only when a second build reproduces that
  # `priv` byte for byte (`NccWorker.Portability`), and refuses it anywhere
  # else. A copy's source is judged as a read first. `"path"` is the file
  # relative to `priv`, for every target the write names.
  defp own_priv_write(e, ctx, owner, outside) do
    case copy_source(e, ctx, owner) do
      :ignore ->
        paths = for t <- outside, do: Context.own_priv_path(ctx, t, owner)
        written = if e["mfa"] in @not_content, do: nil, else: own_target(e, ctx, owner)

        {:observe, "priv_writes",
         Map.merge(summary(e), %{
           "paths" => paths,
           "written" => written,
           "refusal" => outside_ebin(e, outside)
         })}

      other ->
        other
    end
  end

  # The file whose bytes the write sets: its target (a rename's or a copy's
  # destination), when that is in the package's own `priv`.
  defp own_target(%{"arg" => %{"path" => path}}, ctx, owner),
    do: Context.own_priv_path(ctx, path, owner)

  # Only the package's own compile, never its `mix.exs`, which Mix evaluates
  # outside any compile, and never a dependency's window.
  defp own_compile?(e, ctx, owner),
    do: owner == ctx.package and Context.mix_exs(ctx, e, owner) == nil

  # `File.mkdir_p/1` (Elixir 1.20) tries `:file.make_dir/1` on every
  # directory from `/` down: above the package's own `priv` each one is
  # there already, so the call creates nothing and only says it exists. Only
  # the toolchain's own `File` makes it (`caller_kind`: never a package's
  # module of that name).
  defp mkdir_p_probe?(%{"mfa" => "file:make_dir/1", "arg" => %{"path" => path}} = e, ctx, owner),
    do: toolchain_caller?(e, @mkdir_p) and Context.above_own_priv?(ctx, path, owner)

  defp mkdir_p_probe?(_e, _ctx, _owner), do: false

  defp toolchain_caller?(%{"caller_kind" => "toolchain"} = e, mfa), do: caller?(e, mfa)
  defp toolchain_caller?(_e, _mfa), do: false

  defp copy_source(%{"arg" => %{"from_kind" => "read", "from" => from}} = e, ctx, owner),
    do: file_read(%{e | "arg" => %{"path" => from}}, ctx, owner)

  defp copy_source(%{"arg" => %{"from_kind" => kind}} = e, _ctx, _owner)
       when kind not in [nil, "write"],
       do: unjudged("unknown write source #{inspect(kind)}: #{e["mfa"]}")

  defp copy_source(_event, _ctx, _owner), do: :ignore

  # Observed (`native_calls`) in another dependency's window: the judge
  # taints that dependency for it (`NccWorker.Portability`, R3).
  defp native_closure(event, ctx, owner) do
    if is_binary(owner) and owner != ctx.package,
      do: {:observe, "native_calls", summary(event)},
      else: {:refuse, "calls natively built dependency at compile time: " <> event["mfa"]}
  end

  # S4: a call into a holder module, a module whose beams hold its build's
  # deps or build path (patterned only in a relocation's second build,
  # `NccWorker.Portability.Relocate`). Observed (`holder_calls`) in another
  # dependency's window, where the judge taints that dependency for it; a
  # refusal in the package's window and outside every window.
  defp root_holder(event, ctx, owner) do
    if is_binary(owner) and owner != ctx.package,
      do: {:observe, "holder_calls", summary(event)},
      else: {:refuse, "calls a build-path holder at compile time: " <> event["mfa"]}
  end

  defp in_mix_exs(event, ctx, owner, slices, refusal) do
    with path when is_binary(path) <- Context.mix_exs(ctx, event, owner),
         line when is_integer(line) and line > 0 <- get_in(event, ["user", "line"]) do
      slice = Map.get_lazy(slices, path, fn -> analyse(path) end)
      sliced(event, path, line, slice)
    else
      _ -> refusal
    end
  end

  defp sliced(event, path, line, {:ok, analysis}) do
    case MixExsSlice.judge(analysis, line) do
      :ok -> {:observe, "mix_exs_allowed", summary(event)}
      {:refuse, why} -> sliced(event, path, line, {:refuse, why})
    end
  end

  defp sliced(event, path, line, {:refuse, why}),
    do: {:refuse, "compile-time host read in mix.exs: #{event["mfa"]} #{why} (#{path}:#{line})"}

  # R4 for an Elixir-version read in a dependency's mix.exs: ignored unless
  # it can reach a compile-relevant key (or the slice cannot tell). One that
  # can, on a line of direct literal comparisons only
  # (`MixExsSlice.direct_version_line?/3`), is observed for
  # `ElixirVersion`, marked `"series"`: its result must be the same over the
  # build's whole minor.
  defp version_in_mix_exs(event, path, slices) do
    line = get_in(event, ["user", "line"])

    {verdict, analysis} =
      if is_integer(line) and line > 0 do
        analysis = Map.get_lazy(slices, path, fn -> analyse(path) end)
        {slice_judge(analysis, line), analysis}
      else
        {{:refuse, "has no line"}, nil}
      end

    cond do
      verdict == :ok ->
        :ignore

      direct_version?(analysis, line, event["mfa"]) ->
        {:observe, "elixir_version", Map.put(traced_summary(event), "series", true)}

      true ->
        {:refuse, why} = verdict

        {:refuse,
         "compile-time Elixir patch dependence: #{event["mfa"]} #{why} (#{path}:#{line})"}
    end
  end

  defp direct_version?({:ok, analysis}, line, mfa),
    do: MixExsSlice.direct_version_line?(analysis, line, mfa)

  defp direct_version?(_analysis, _line, _mfa), do: false

  defp slice_judge({:ok, analysis}, line), do: MixExsSlice.judge(analysis, line)
  defp slice_judge({:refuse, _why} = refusal, _line), do: refusal

  defp analyse(path) do
    case read_bounded(path) do
      {:ok, source} -> MixExsSlice.analyse(source)
      {:error, reason} -> {:refuse, "mix.exs unreadable (#{inspect(reason)})"}
    end
  end

  # A closure dependency's own mix.exs, at a real path the Context resolved;
  # read only up to a bound (MixExsSlice refuses anything larger anyway).
  # sobelow_skip ["Traversal.FileModule"]
  defp read_bounded(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, @max_mix_exs_bytes)) do
      {:ok, source} when is_binary(source) -> {:ok, source}
      {:ok, :eof} -> {:ok, ""}
      {:ok, other} -> {:error, other}
      {:error, reason} -> {:error, reason}
    end
  end

  # Item 5c: the key or name the read asked for, the path, and the frame
  # that made the call when it is not the package frame `where/1` names.
  # The prefix stays exact: the portal withdraws on it.
  defp host_read(event, path \\ nil) do
    "compile-time host read: " <>
      event["mfa"] <> detail(event) <> path_part(path) <> via(event) <> where(event)
  end

  defp detail(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => key}}) when is_binary(key),
    do: " (#{key})"

  defp detail(%{"channel" => "env", "arg" => %{"name" => name}}) when is_binary(name),
    do: " (#{name})"

  # A RAM file's open (`file:open/2` with `ram`; `:erl_tar.extract({:binary,
  # bytes}, ...)`), which the tracer records without its "path", the file's
  # contents. A read refuses as every read of a path no rule allows does, a
  # write as a write outside ebin (`outside_ebin/2`), as they did while the
  # contents were taken for a path: a reviewed tool's unpack is set apart
  # before that (`NccWorker.Portability`, `@reviewed_unpacks`).
  defp detail(%{"channel" => "file_read", "arg" => %{"ram" => true}}),
    do: " (an in-memory file)"

  defp detail(_event), do: ""

  defp via(%{"first" => %{"module" => m, "function" => f, "arity" => a}, "user" => user})
       when is_binary(m) and is_binary(f) and is_integer(a) and is_map(user) do
    if user["module"] == m and user["function"] == f and user["arity"] == a,
      do: "",
      else: " via #{frame_text(m, f, a)}"
  end

  defp via(_event), do: ""

  defp frame_text("Elixir." <> name, f, a), do: "#{name}.#{f}/#{a}"
  defp frame_text(m, f, a), do: "#{m}:#{f}/#{a}"

  defp path_part(nil), do: ""
  defp path_part(path), do: " " <> show(path)

  defp show(path) when is_binary(path), do: path
  defp show(path), do: inspect(path)

  defp where(%{"user" => %{"module" => module, "function" => fun, "arity" => arity} = user})
       when is_binary(module),
       do: " in #{display(module)}.#{fun}/#{arity} (#{user["file"]}:#{user["line"]})"

  defp where(event),
    do: " (#{event["extent"]} stack, first frame #{first_module(event)})"

  defp first_module(%{"first" => %{"module" => module}}), do: module
  defp first_module(_event), do: "none"

  defp display("Elixir." <> name), do: name
  defp display(name), do: name

  defp env_read(event, ctx, owner, slices) do
    Map.merge(summary(event), %{
      "name" => event["arg"]["name"],
      "returned" => event["returned"],
      "ts" => event["ts"],
      "all" => false,
      "slice_allowed" => slice_allowed?(event, ctx, owner, slices)
    })
  end

  # R4 on a read in a dependency's mix.exs: one that cannot reach a
  # compile-relevant key is no input by itself (`CompileInputs` takes it
  # back when its file also writes the environment).
  defp slice_allowed?(event, ctx, owner, slices),
    do: match?({:observe, "mix_exs_allowed", _}, in_mix_exs(event, ctx, owner, slices, :none))

  defp env_write(event) do
    event
    |> summary()
    |> Map.merge(%{
      "name" => event["arg"]["name"],
      "value" => event["arg"]["value"],
      "ts" => event["ts"]
    })
  end

  defp summary(event) do
    user = if is_map(event["user"]), do: event["user"], else: %{}

    %{
      "mfa" => event["mfa"],
      "arg" => event["arg"],
      "module" => user["module"],
      "file" => user["file"],
      "line" => user["line"]
    }
  end

  # What R5 and the Elixir-version rule judge a read by: who made it.
  defp traced_summary(event) do
    first = if is_map(event["first"]), do: event["first"]["module"]

    event
    |> summary()
    |> Map.merge(%{
      "first" => first,
      "first_kind" => event["first_kind"],
      "extent" => event["extent"]
    })
  end
end
