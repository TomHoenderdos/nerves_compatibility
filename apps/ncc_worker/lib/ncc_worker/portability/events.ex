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
  dependence: `, compile options that may differ between patches), any
  other is ignored. Everything else is allowed by a narrow rule or refused:

    * OS identity: `system_info(otp_release)` is allowed, and `os:type/0`,
      `os:version/0` or `system_info(os_type)` when the first frame after
      the wrappers is one of the path internals that read it themselves
      (`:ncc_tracer_channels.path_os_frames/0`: `Path.major_os_type/0`,
      `:filename.split/1` and the like, and `:erl_prim_loader`'s unexported
      `pathtype/1`, `normalize/2` and `real_path/4`; never a function that runs a fun it
      was given, so a package callback tail-calling the read is refused).
      `machine`, `smp_support`, `threads` and `heap_type` are allowed
      (constant within an OTP major); every other key refuses, and the
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
    * Reads: `Context.readable?/2` of the real path, relative paths and
      `get_cwd` against the window's dependency (`Context.cwd/2`). A read
      file or directory listing in a closure dependency whose tree matched
      its tarball before the compile must still be the tarball's
      (`Context.tree_check/3`, item 5e); one that no longer is cannot be
      judged.
    * Writes: only under the window's own `ebin` (`Context.writable?/3`); a
      rename's source too, a copy's source must be readable. Any symlink or
      hard link refuses, even inside `ebin`: the judge resolves paths after
      the build, so a link there can stand for a read of any target.
    * A user `set_cwd` refuses: it changes what every later relative path
      names.
    * A call into a natively built dependency refuses in the package's
      window and outside every window, and is observed in another
      dependency's window, where it is recorded only (`native_calls`): the
      judge does not refuse on it, since R3 native taint refuses only calls
      made in the package's own window.
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
      window for it.
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
  alias NccWorker.Portability.{Context, MixExsSlice, Probes}

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

  @type decision ::
          :ignore
          | {:observe, String.t(), map()}
          | {:refuse, String.t()}
          | {:unjudged, String.t()}

  @typedoc "Per `mix.exs` real path, its `MixExsSlice.analyse/1` result."
  @type slices :: %{String.t() => {:ok, MixExsSlice.t()} | {:refuse, String.t()}}

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
    do: {:observe, "config_reads", traced_summary(event)}

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
    do: path_handling(e)

  defp os_identity(%{"mfa" => "erlang:system_info/1", "arg" => %{"key" => key}})
       when key in @same_within_major,
       do: :ignore

  defp os_identity(%{"mfa" => "erlang:system_info/1"} = e), do: {:refuse, host_read(e)}
  defp os_identity(e), do: path_handling(e)

  defp path_handling(%{"first" => %{"module" => m, "function" => f, "arity" => a}} = e) do
    if {m, f, a} in @path_frames, do: :ignore, else: {:refuse, host_read(e)}
  end

  defp path_handling(e), do: {:refuse, host_read(e)}

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

  defp file_read(%{"arg" => %{"path" => path}} = e, ctx, owner) when is_binary(path),
    do: readable(e, ctx, path, owner)

  defp file_read(e, _ctx, _owner), do: {:refuse, host_read(e)}

  # Readable by `Context.readable?/2` and, for a closure dependency whose
  # tree matched its tarball before the compile, still the tarball's (item
  # 5e, `Context.tree_check/3`). A tree changed since that check is no
  # refusal (it was the tarball's when checked) but cannot be judged.
  defp readable(e, ctx, path, owner) do
    real = Context.resolve(ctx, path, owner)

    if Context.readable?(ctx, real) do
      case Context.tree_check(ctx, real, e["arg"]["listing"] == true) do
        :ok ->
          :ignore

        {:differs, app, detail} ->
          unjudged("dependency tree changed after the check: #{app} (#{detail})")
      end
    else
      {:refuse, host_read(e, path)}
    end
  end

  defp file_write(%{"mfa" => mfa, "arg" => arg}, _ctx, _owner) when mfa in @links,
    do: {:refuse, "compile-time write outside ebin: #{mfa} #{show(arg["path"])} (a link)"}

  defp file_write(%{"arg" => arg} = e, ctx, owner) do
    targets = [arg["path"] | if(arg["from_kind"] == "write", do: [arg["from"]], else: [])]

    # Filtered, not found: a missing (`nil`) target is itself the bad one.
    case Enum.reject(targets, &Context.writable?(ctx, &1, owner)) do
      [] -> copy_source(e, ctx, owner)
      [bad | _] -> {:refuse, "compile-time write outside ebin: #{e["mfa"]} #{show(bad)}"}
    end
  end

  defp copy_source(%{"arg" => %{"from_kind" => "read", "from" => from}} = e, ctx, owner),
    do: file_read(%{e | "arg" => %{"path" => from}}, ctx, owner)

  defp copy_source(%{"arg" => %{"from_kind" => kind}} = e, _ctx, _owner)
       when kind not in [nil, "write"],
       do: unjudged("unknown write source #{inspect(kind)}: #{e["mfa"]}")

  defp copy_source(_event, _ctx, _owner), do: :ignore

  # Recorded only (`native_calls`) in another dependency's window: the
  # judge never refuses on these observations.
  defp native_closure(event, ctx, owner) do
    if is_binary(owner) and owner != ctx.package,
      do: {:observe, "native_calls", summary(event)},
      else: {:refuse, "calls natively built dependency at compile time: " <> event["mfa"]}
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
  # it can reach a compile-relevant key (or the slice cannot tell).
  defp version_in_mix_exs(event, path, slices) do
    line = get_in(event, ["user", "line"])

    verdict =
      if is_integer(line) and line > 0 do
        slices |> Map.get_lazy(path, fn -> analyse(path) end) |> slice_judge(line)
      else
        {:refuse, "has no line"}
      end

    case verdict do
      :ok ->
        :ignore

      {:refuse, why} ->
        {:refuse,
         "compile-time Elixir patch dependence: #{event["mfa"]} #{why} (#{path}:#{line})"}
    end
  end

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
