defmodule NccWorker.Portability.Probes do
  @moduledoc """
  Compile-time probes of modules the tracer itself loaded. The tracer loads
  every module it sets a pattern on (`httpc`, `ssl`, `dbg`, `trace`, ...),
  every module its own code calls (`json`, ...) and has its own modules on
  the code path, all before anything compiles. A package's compile-time
  code that asks about one of them can get another answer under the trace
  than in an untraced compile, and the beam differs. The tracer reports
  those modules (`preloaded` on its start line, a child VM's own on each
  probe as `app`) and traces probes of exactly those
  (`:ncc_tracer_channels.probe_mfas/0`).

  Only one kind of answer is the same either way:

    * `code:ensure_loaded/1`, `code:which/1` and `code:get_object_code/1`
      ask whether the module can be loaded, where from and with what code.
      Untraced, Mix's pruned code path answers that; under the trace the
      module is loaded already. The answers agree when the module's
      application is on the prober's code path: `kernel`, `stdlib`,
      `elixir`, every closure dependency of the window's owner, and every
      application their `.app` files list under `applications` or
      `included_applications`, transitively (an installed OTP or Elixir
      application's own list is read in this VM, which runs the same
      install). `kernel`, `stdlib` and `elixir` are on every path, so such a
      probe of theirs is the same outside a window too (a `mix.exs`'s
      `Code.ensure_loaded?(:json)`).
    * `code:is_loaded/1`, `code:module_status/1`, `erlang:module_loaded/1`
      and `erlang:function_exported/3` ask whether it is loaded now: `true`
      under the trace, `false` untraced until something loads it, listed or
      not. Never the same answer, with one exception.
    * `erlang:function_exported/3` of a module that the same process
      ensure-loaded earlier for the same owner, the package's own or a
      closure dependency's, when that `code:ensure_loaded/1` was the
      same answer by the rule above (the module's application is on the
      owner's path, never the tracer's). Untraced, that ensure_loaded loaded
      the module, so by the time the process asks, the module is loaded
      either way and the answer is its exports either way: the
      `Code.ensure_loaded?(:json) and function_exported?(:json, f, a)` of
      published packages. Only the same process (`pid`) and a strictly
      earlier time (`ts`): another process's load is not ordered before the
      probe. Neither VM's clock nor pids mean anything in another's, so
      `ensured` holds the ensure_loaded probes of the VM being decided only
      (`NccWorker.Portability.decide_all`). Not the other loaded-now probes:
      no published package needs them. A package that deletes the module
      between the two calls (`erlang:delete_module/1`, which the trace does
      not watch) could make the tracer's own next use reload it; that is a
      deliberate attack on the trace, which the spec leaves out of scope.

  The tracer's own modules (application `ncc_tracer`) do not exist in an
  untraced compile and are on no path. The few modules Mix itself loads in
  every compile before it evaluates a dependency's `mix.exs` (`crypto`,
  `gen_tcp`: `:ncc_tracer.loaded_by_mix/0`) answer every probe the same
  either way; the tracer leaves them out of the Mix VM's `preloaded`.

  A loaded-now check the code server makes inside one of the probe
  functions (`caller` is `code` and that function) is someone else's: the
  probe it serves is traced and judged itself.

  A probe or call whose first frame past the wrappers and the loaders is
  Elixir's type checker (`checker` from the tracer: `Module.ParallelChecker`
  or a `Module.Types` module, the toolchain's) is the checker looking up a
  module for the code it checks. What it finds reaches its warnings only,
  so it is dropped, with frames below it cut off or not (the checker's
  stacks are deep). Unless package code started a nested compile or a
  capture of diagnostics in the same window (`Context.nested`: `Code`'s
  compile, require, load and eval functions, `Code.with_diagnostics`,
  `Kernel.ParallelCompiler`, `Module.create/3`, `:elixir_compiler`'s
  `string`, `quoted` and `file`, any call into `Module.ParallelChecker`; the
  last two only when package code, not the compiler, made the call; or such
  a call whose stack could not be told apart): then its warnings can reach the package, and
  every checker probe in that window is judged, except the checker's
  `function_exported/3` of a module whose application is on the owner's
  path: the checker calls it only on a module it loaded, and untraced that
  module loads the same; and the `module_loaded/1` that `cache_module/2`
  asks before any load, of an Erlang module (no checker chunk) on the
  owner's path, whose two branches cache the same entries for it (both
  pinned per toolchain by `CheckerLookupsTest`). Any other `module_loaded/1`
  counts. One window's mark never
  counts in another. Every other probe of such a module is judged.

  Two more things the trace changes are judged here:

    * a call into a module the tracer loaded whose application is not on
      every path (`kernel`, `stdlib`, `elixir`, `compiler`, `logger`;
      channel `app_call`): untraced, a caller that does not list the
      application (on its path as above) gets `undef` or another answer.
      Allowed when it does, and, whatever the window, when the frame that
      made the call runs installed OTP code (the tracer's `caller_app`: the
      application whose `code:lib_dir()` ebin the frame's module was loaded
      from) whose own `.app` lists the application under `applications`:
      OTP's public_key decoding a certificate through `asn1rt_nif` during
      an HTTPS download runs the same untraced, since asn1 is on the path
      wherever public_key is. Only that direct listing, never another OTP
      application's call;
    * listing the loaded modules (`code:all_loaded/0`, `erlang:loaded/0`,
      `code:module_status/0`, `code:modified_modules/0`; channel
      `loaded_modules`): the list holds every module the tracer loaded.
      Never judged.

  A probe of a module the tracer did not load, of an installed OTP or
  Elixir application off the paths every compile has (the tracer names it
  `otp_app`, `:ncc_tracer.installed_modules/2`), is no question of the
  trace: untraced, the answer is the same. It is one of the code path. Mix
  compiles a dependency on a path pruned to the applications its closure
  lists (`Mix.Tasks.Compile.All`, `prune_code_paths`), Mix.install does
  not (`prune_code_paths: false`, which every dependency inherits), so a
  probe of an application off the owner's path answers `false` here and
  `true` there, and the two compile different code: vega_lite 0.1.11's
  `VegaLite.WxViewer` is a stub that raises in a Mix project and a
  `:wx_object` viewer under Mix.install. Every probe function above, the
  loaded-now ones included (under Mix.install another compile may have
  loaded the module), refuses:
  `compile-time probe of an OTP application outside the closure: <app> via
  <function>`. On the owner's path (as above) it is no concern. A
  dependency's `mix.exs` runs on whatever path Mix left (the whole install
  while Mix loads the dependencies, the previous dependency's pruned path
  when `compile.all` asks its `application/0`, so easel 0.3.4's
  `Code.ensure_compiled(:wx)` there depends on the compile order), so a
  probe from one refuses whatever its application lists (` in mix.exs`).
  A firmware target's trace is judged the same: `mix firmware` prunes as
  the builder does, but pruning decides only what can be newly found, and
  a module or application an earlier compile in the same VM loaded stays
  visible to every later one (Mix loads every closure application of each
  dependency it compiles, and nothing unloads code). A probe the code server makes inside another, the
  type checker's outside a window with a nested compile (as above), and
  the lookup `@behaviour m` makes in a module body, whose answer Elixir's
  `Module.preprocess_attribute/2` drops (the tracer's `attribute`), are no
  concern: inky_host_dev 1.0.0's `@behaviour :wx_object` without wx
  listed compiles the same beams pruned or not.

  The same holds for what the application controller knows of an
  application (channel `app_probe`: `application_controller`'s
  `load_application/1`, `get_key/2`, `get_all_key/1`, `is_running/1`,
  `start_application/2` and `start_application_request/2`, reached by
  `Application.load/1`, `spec/1,2`, `ensure_loaded/1`, `ensure_all_started/1`
  and `start/1`; and `code:where_is_file/1` of an `<app>.app`): Mix's
  AppLoader loads every closure application of a dependency before it
  compiles it and nothing unloads one, so for an application off the
  owner's path the answer is whatever earlier compiles loaded, and under
  Mix.install whatever the install holds. Such a probe is no concern for an
  application on every path, one loaded before the tracer started (the
  tracer's `loaded_before`: Hex starts ssl and inets, and as with a module
  loaded then, it is loaded either way) or on the owner's path (the
  package's own included); from a dependency's `mix.exs` it refuses whatever it lists, and
  otherwise it refuses, an installed OTP or Elixir application's (`otp_app`)
  with the OTP reason above, any other's with `compile-time probe of a
  dependency outside the closure: <app> via <function>`.
  `code:where_is_file/1` of a `<module>.beam` is a path probe of that module,
  and `application_controller:get_application_module/1` (which application
  holds a module) one too.

  A probe the package itself made (the tracer's `by_package`: past the
  wrappers, `Code`'s and `Kernel`'s probe functions, the code server's and
  the error handlers' frames and the toolchain's higher-order glue, the
  first frame is package code) of a module that no installed OTP or Elixir
  application holds and the tracer did not load is judged against the
  modules the owner's closure builds (`Context` `modules`, from each
  dependency's `ebin`). Under Mix.install every installed dependency's
  `ebin` is on the code path, and in a Mix project a module an earlier
  dependency's compile-time code loaded stays loaded, so a probe of a module
  outside the closure answers differently there than on the builder (jose
  1.11.12's `Code.ensure_loaded?(Poison)`, which compiles `JOSE.Poison` only
  where poison is visible): it refuses as `compile-time probe of a
  dependency outside the closure: <module> via <function>`, also when a
  closure dependency declares the module's package as an optional
  dependency that this build lacks. From a dependency's `mix.exs` such a
  probe refuses whatever the closure holds. The toolchain's own lookups of
  such a module (the expander resolving an import, a struct or a require,
  the behaviour check) reach only the compile's errors and warnings and are
  no concern.

  A probe of a module the owner's path holds (an installed application's on
  it, or a closure dependency's) answers the same pruned or not when it
  asks whether the module can be found (the path probes); whether it is
  loaded now depends on what other compile-time code in the same VM called
  into it, which the user's project decides. The package's own loaded-now
  probe of such a module therefore refuses as `compile-time probe of
  whether a module is loaded: <module> via <function>`, unless the same
  process ensure-loaded it earlier (`ensured`).

  An event this module cannot read could not be judged.
  """

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.AppFile
  alias NccWorker.Portability.Context

  @base ~w(kernel stdlib elixir)
  @tracer_app "ncc_tracer"
  @path_probes ~w(code:ensure_loaded/1 code:which/1 code:get_object_code/1 code:where_is_file/1
                  application_controller:get_application_module/1)
  @probe_functions ~w(ensure_loaded is_loaded which module_status get_object_code)
  @always ~w(kernel stdlib elixir compiler logger)
  # On the path of every compile Mix makes of an Elixir project's
  # dependency, whatever it lists: Mix.AppLoader's extra applications
  # (`:ex_unit`, `:iex`, `:mix`, `:elixir`), what they list, and erts; and
  # logger, as `@always` takes it. The tracer names no module of theirs
  # (`otp_app`).
  @every_path ~w(kernel stdlib compiler erts elixir mix iex ex_unit logger)
  # Elixir's modules whose functions probe for the package.
  @elixir_wrappers ~w(Code Kernel Application)
  # The stacks the tracer judged (`NccWorker.Portability.Events`).
  @extents ~w(frame dispatcher truncated lineage)

  @doc """
  `:ignore`, `{:unjudged, why}` for a probe whose answer may differ
  under the trace, or `{:refuse, why}` for one whose answer differs
  between Mix's pruned code path and Mix.install's, for `owner`
  (`Context.owner/2`, or a child VM's app).
  """
  @spec decide(map(), Context.t(), term()) ::
          :ignore | {:unjudged, String.t()} | {:refuse, String.t()}
  def decide(%{"channel" => "loaded_modules", "mfa" => mfa}, _ctx, _owner) when is_binary(mfa),
    do: {:unjudged, "compile-time list of the loaded modules: " <> mfa}

  def decide(%{"arg" => %{"checker" => true}} = event, %Context{} = ctx, owner) do
    case Map.fetch(ctx.nested, owner) do
      :error ->
        :ignore

      {:ok, nested} ->
        if loaded_lookup_on_path?(event, ctx, owner),
          do: :ignore,
          else: in_nested(event, ctx, owner, nested)
    end
  end

  def decide(
        %{"channel" => "app_call", "mfa" => mfa, "arg" => %{"module" => m, "app" => app}} =
          event,
        %Context{} = ctx,
        owner
      )
      when is_binary(mfa) and is_binary(m) and is_binary(app) do
    if app in @always or app_call_same?(event, app, ctx, owner),
      do: :ignore,
      else: {:unjudged, "compile-time call into a module the trace loaded: #{mfa} (#{app})"}
  end

  def decide(
        %{"channel" => "probe", "arg" => %{"module" => module} = arg} = event,
        %Context{} = ctx,
        owner
      )
      when is_binary(module) do
    case app(arg, module, ctx) do
      nil -> outside(event, arg, ctx, owner)
      app -> decide(event, module, app, ctx, owner)
    end
  end

  def decide(%{"channel" => "app_probe", "arg" => %{"app" => app} = arg} = event, ctx, owner)
      when is_binary(app) do
    cond do
      app in @every_path or arg["loaded_before"] == true ->
        :ignore

      is_binary(Context.mix_exs(ctx, event, owner)) ->
        {:refuse, app_probe(app, arg, event) <> " in mix.exs"}

      Context.dep?(ctx, owner) and app in path_of(ctx, owner) ->
        :ignore

      declared?(ctx.declared.apps, app, ctx, owner) ->
        :ignore

      true ->
        {:refuse, app_probe(app, arg, event)}
    end
  end

  def decide(event, _ctx, _owner),
    do: {:unjudged, "unreadable probe event: #{inspect(event["mfa"])}"}

  @doc """
  Whether an event is one `NccWorker.Portability.Declared` may decide: a
  package's probe of a module the trace did not load and no installed
  application holds, or an application probe.
  """
  @spec declared_relevant?(map()) :: boolean()
  def declared_relevant?(%{"channel" => "app_probe"}), do: true

  def declared_relevant?(%{"channel" => "probe", "arg" => %{"by_package" => true} = arg}),
    do: arg["otp_app"] in [nil, false] and arg["app"] in [nil, false]

  def declared_relevant?(_event), do: false

  @doc """
  The `code:ensure_loaded/1` probes among one VM's `{owner, event}` pairs,
  by `{owner, pid, module}`, each with the earliest time it was made. Only
  a probe on a stack the tracer judged, not the type checker's, with a pid
  and a time.
  """
  @spec ensured([{term(), map()}]) :: %{{term(), String.t(), String.t()} => integer()}
  def ensured(owned_events) do
    for {owner, event} <- owned_events, key = ensure_key(owner, event), key != nil, reduce: %{} do
      acc -> Map.update(acc, key, event["ts"], &min(&1, event["ts"]))
    end
  end

  defp ensure_key(owner, %{
         "channel" => "probe",
         "mfa" => "code:ensure_loaded/1",
         "arg" => %{"module" => module} = arg,
         "pid" => pid,
         "ts" => ts,
         "extent" => extent
       })
       when is_binary(module) and is_binary(pid) and is_integer(ts) and extent in @extents do
    if arg["checker"] in [nil, false], do: {owner, pid, module}
  end

  defp ensure_key(_owner, _event), do: nil

  defp decide(event, module, app, ctx, owner) do
    cond do
      nested?(event) -> :ignore
      event["mfa"] in @path_probes -> on_path(module, app, ctx, owner)
      ensured_before?(event, module, app, ctx, owner) -> :ignore
      true -> {:unjudged, "#{why(module, app)} by #{event["mfa"]}"}
    end
  end

  # function_exported/3 after the same process's own same-answer
  # ensure_loaded of the module, for the same owner (moduledoc).
  defp ensured_before?(
         %{"mfa" => "erlang:function_exported/3", "pid" => pid, "ts" => ts},
         module,
         app,
         ctx,
         owner
       )
       when is_binary(pid) and is_integer(ts) do
    case Map.fetch(ctx.ensured, {owner, pid, module}) do
      {:ok, first} when first < ts ->
        Context.dep?(ctx, owner) and on_path(module, app, ctx, owner) == :ignore

      _ ->
        false
    end
  end

  defp ensured_before?(_event, _module, _app, _ctx, _owner), do: false

  # A child VM's probe names its own VM's application for the module.
  defp app(%{"app" => app}, _module, _ctx) when is_binary(app), do: app
  defp app(_arg, module, ctx), do: Map.get(ctx.preloaded, module)

  defp nested?(%{"caller" => %{"module" => "code", "function" => function}}),
    do: function in @probe_functions

  defp nested?(_event), do: false

  defp on_path(module, app, ctx, owner) do
    cond do
      app == @tracer_app -> {:unjudged, why(module, app)}
      app in @base -> :ignore
      Context.dep?(ctx, owner) and app in path_of(ctx, owner) -> :ignore
      true -> {:unjudged, why(module, app)}
    end
  end

  defp in_nested(event, ctx, owner, nested) do
    case decide(put_in(event, ["arg", "checker"], false), ctx, owner) do
      {kind, why} -> {kind, "#{why}, in a window with a nested compile (#{nested})"}
      :ignore -> :ignore
    end
  end

  # A module the tracer did not load (moduledoc): one of an installed OTP or
  # Elixir application (`otp_app`), whoever probed it, or any other the
  # package probed (`by_package`). The trace answers as Mix's pruned path
  # does, Mix.install as the whole install does.
  defp outside(event, arg, ctx, owner) do
    cond do
      nested?(event) or attribute_lookup?(event) -> :ignore
      is_binary(arg["otp_app"]) -> installed_probe(event, arg["otp_app"], ctx, owner)
      arg["by_package"] == true -> dependency_probe(event, arg["module"], ctx, owner)
      true -> :ignore
    end
  end

  defp installed_probe(event, app, ctx, owner) do
    cond do
      app in @every_path ->
        :ignore

      is_binary(Context.mix_exs(ctx, event, owner)) ->
        {:refuse, otp_probe(app, event) <> " in mix.exs"}

      not (Context.dep?(ctx, owner) and app in path_of(ctx, owner)) ->
        {:refuse, otp_probe(app, event)}

      true ->
        found_or_ensured(event, ctx, owner)
    end
  end

  defp dependency_probe(event, module, ctx, owner) do
    cond do
      is_binary(Context.mix_exs(ctx, event, owner)) ->
        {:refuse, dependency(module, event) <> " in mix.exs"}

      Context.dep?(ctx, owner) and Map.get(ctx.modules, module) in Context.closure_of(ctx, owner) ->
        found_or_ensured(event, ctx, owner)

      declared?(ctx.declared.modules, module, ctx, owner) ->
        :ignore

      true ->
        {:refuse, dependency(module, event)}
    end
  end

  # A module or application of a dependency a member of the owner's closure
  # declares and the build lacks (`Context` `declared`).
  defp declared?(index, key, ctx, owner) do
    case Map.fetch(index, key) do
      {:ok, members} ->
        Context.dep?(ctx, owner) and
          Enum.any?(members, &(&1 in Context.closure_of(ctx, owner)))

      :error ->
        false
    end
  end

  # A module the owner's path holds: whether it can be found, and where,
  # is the same either way; whether it is loaded now is not (other
  # compile-time code in the same VM may have called into it, which the
  # user's project decides), unless the same process ensure-loaded it
  # earlier (`ensured`).
  # Only the package's own probe (`by_package`): a toolchain function's
  # check of a module it is about to use (EEx's of its engine) is judged as
  # before.
  defp found_or_ensured(event, ctx, owner) do
    if event["mfa"] in @path_probes or event["arg"]["by_package"] != true or
         ensured?(event, ctx, owner),
       do: :ignore,
       else: {:refuse, Reasons.loaded_probe() <> "#{event["arg"]["module"]} via #{via(event)}"}
  end

  defp ensured?(%{"pid" => pid, "ts" => ts, "arg" => %{"module" => module}}, ctx, owner)
       when is_binary(pid) and is_integer(ts) do
    case Map.fetch(ctx.ensured, {owner, pid, module}) do
      {:ok, first} -> first < ts
      :error -> false
    end
  end

  defp ensured?(_event, _ctx, _owner), do: false

  defp dependency(module, event),
    do: Reasons.dependency_probe() <> "#{module} via #{via(event)}"

  # `@behaviour m`'s own lookup, whose answer Elixir drops (the tracer's
  # `attribute`, `:ncc_tracer_stack.attribute_lookup/2`).
  defp attribute_lookup?(%{"mfa" => "code:ensure_loaded/1", "arg" => %{"attribute" => true}}),
    do: true

  defp attribute_lookup?(_event), do: false

  defp otp_probe(app, event), do: Reasons.otp_probe() <> "#{app} via #{via(event)}"

  # An installed OTP or Elixir application's (`otp_app`), or any other's.
  defp app_probe(app, %{"otp_app" => app}, event), do: otp_probe(app, event)
  defp app_probe(app, _arg, event), do: Reasons.dependency_probe() <> "#{app} via #{via(event)}"

  # The Elixir function the package called (`Code.ensure_loaded?/1`), when
  # the probe's caller is one; else the probe itself.
  defp via(%{"caller" => %{"module" => "Elixir." <> m, "function" => f, "arity" => a}})
       when m in @elixir_wrappers and is_binary(f) and is_integer(a),
       do: "#{m}.#{f}/#{a}"

  defp via(event), do: event["mfa"]

  # The checker calls function_exported/3 only on a module it loaded
  # (pinned by CheckerLookupsTest); untraced, a module on the owner's path
  # loads the same, so the answer is the same. Not module_loaded/1, which it
  # asks before loading anything.
  defp loaded_lookup_on_path?(%{"mfa" => "erlang:function_exported/3"} = event, ctx, owner) do
    app = app(event["arg"], event["arg"]["module"], ctx)

    is_binary(app) and app != @tracer_app and Context.dep?(ctx, owner) and
      app in path_of(ctx, owner)
  end

  # cache_module/2 asks module_loaded/1 before loading, but for an Erlang
  # module (no checker chunk) whose object code is on the path, both of its
  # branches cache the same entries (pinned by CheckerLookupsTest). Only
  # that call site, the toolchain's.
  defp loaded_lookup_on_path?(
         %{
           "mfa" => "erlang:module_loaded/1",
           "first_kind" => "toolchain",
           "first" => %{"module" => "Elixir.Module.ParallelChecker", "function" => fun}
         } = event,
         ctx,
         owner
       )
       when is_binary(fun) do
    module = event["arg"]["module"]
    app = app(event["arg"], module, ctx)

    cache_module?(fun) and erlang_module?(module) and is_binary(app) and app != @tracer_app and
      Context.dep?(ctx, owner) and app in path_of(ctx, owner)
  end

  defp loaded_lookup_on_path?(_event, _ctx, _owner), do: false

  defp cache_module?(fun),
    do: fun == "cache_module" or String.starts_with?(fun, "-cache_module/2-")

  # Not an Elixir module, and this install's object code of it has no
  # checker chunk (the worker runs the toolchain the build ran).
  defp erlang_module?("Elixir." <> _), do: false

  defp erlang_module?(module) when is_binary(module) do
    with {_, binary, _} <- module |> String.to_existing_atom() |> :code.get_object_code(),
         {:error, :beam_lib, {:missing_chunk, _, _}} <- :beam_lib.chunks(binary, [~c"ExCk"]) do
      true
    else
      _ -> false
    end
  rescue
    _ -> false
  end

  defp why(module, app), do: "compile-time probe of a module the trace loaded: #{module} (#{app})"

  # A call into `app` (not the tracer's) answers the same untraced: the
  # owner lists `app` (on its path), or installed OTP code that lists it
  # made the call.
  defp app_call_same?(_event, @tracer_app, _ctx, _owner), do: false

  defp app_call_same?(event, app, ctx, owner) do
    (Context.dep?(ctx, owner) and app in path_of(ctx, owner)) or
      otp_caller_lists?(caller_app(event), app)
  end

  defp caller_app(%{"arg" => %{"caller_app" => caller}}) when is_binary(caller), do: caller
  defp caller_app(_event), do: nil

  # The caller is installed OTP code (the tracer names its application only
  # when the frame's module was loaded from `code:lib_dir()`), and that
  # application's own `.app`, read in this VM (the same install), lists
  # `app` under `applications`: not included applications, and not
  # transitively.
  defp otp_caller_lists?(nil, _app), do: false

  defp otp_caller_lists?(caller, app) do
    atom = String.to_existing_atom(caller)

    if otp_installed?(atom) do
      _ = :application.load(atom)
      app in Enum.map(Application.spec(atom, :applications) || [], &Atom.to_string/1)
    else
      false
    end
  rescue
    _ -> false
  end

  defp otp_installed?(atom) do
    case :code.lib_dir(atom) do
      dir when is_list(dir) -> String.starts_with?(List.to_string(dir), "#{:code.lib_dir()}/")
      _ -> false
    end
  end

  defp path_of(ctx, owner) do
    closure = Context.closure_of(ctx, owner)
    listed = Enum.flat_map(closure, &listed(ctx, &1))
    expand(@base ++ listed, ctx, MapSet.new(closure))
  end

  # A closure dependency's applications, from its built `.app`.
  defp listed(ctx, dep) do
    with %{build: build} when is_binary(build) <- Map.get(ctx.deps, dep),
         {:ok, apps} <- AppFile.read_listed_applications(Path.join([build, "ebin", "#{dep}.app"])) do
      apps
    else
      _ -> []
    end
  end

  defp expand([], _ctx, seen), do: MapSet.to_list(seen)

  defp expand([app | rest], ctx, seen) do
    cond do
      MapSet.member?(seen, app) -> expand(rest, ctx, seen)
      Context.dep?(ctx, app) -> expand(listed(ctx, app) ++ rest, ctx, MapSet.put(seen, app))
      true -> expand(installed(app) ++ rest, ctx, MapSet.put(seen, app))
    end
  end

  # An OTP or Elixir application's own list, read in this VM. A name no
  # loaded code knows, or one not installed under OTP's or Elixir's root
  # (this VM's own dependencies are not the build's), lists nothing.
  defp installed(app) do
    atom = String.to_existing_atom(app)

    if installed?(atom) do
      _ = :application.load(atom)

      for key <- [:applications, :included_applications],
          a <- Application.spec(atom, key) || [],
          do: Atom.to_string(a)
    else
      []
    end
  rescue
    _ -> []
  end

  defp installed?(atom) do
    case :code.lib_dir(atom) do
      dir when is_list(dir) ->
        dir = List.to_string(dir)
        Enum.any?(install_roots(), &String.starts_with?(dir, &1 <> "/"))

      _ ->
        false
    end
  end

  defp install_roots do
    elixir =
      case :code.lib_dir(:elixir) do
        dir when is_list(dir) -> [dir |> List.to_string() |> Path.dirname()]
        _ -> []
      end

    [List.to_string(:code.root_dir()) | elixir]
  end
end
