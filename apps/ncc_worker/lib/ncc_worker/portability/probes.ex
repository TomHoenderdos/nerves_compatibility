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
      not. Never the same answer.

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
  compile, require and eval functions, `Code.with_diagnostics`,
  `Kernel.ParallelCompiler`, `Module.create/3`, or such a call whose stack
  could not be told apart): then its warnings can reach the package, and
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
      Allowed when it does;
    * listing the loaded modules (`code:all_loaded/0`, `erlang:loaded/0`,
      `code:module_status/0`, `code:modified_modules/0`; channel
      `loaded_modules`): the list holds every module the tracer loaded.
      Never judged.

  An event this module cannot read could not be judged.
  """

  alias NccWorker.AppFile
  alias NccWorker.Portability.Context

  @base ~w(kernel stdlib elixir)
  @tracer_app "ncc_tracer"
  @path_probes ~w(code:ensure_loaded/1 code:which/1 code:get_object_code/1)
  @probe_functions ~w(ensure_loaded is_loaded which module_status get_object_code)
  @always ~w(kernel stdlib elixir compiler logger)

  @doc """
  `:ignore`, or `{:unjudged, why}` for a probe whose answer may differ
  under the trace, for `owner` (`Context.owner/2`, or a child VM's app).
  """
  @spec decide(map(), Context.t(), term()) :: :ignore | {:unjudged, String.t()}
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
        %{"channel" => "app_call", "mfa" => mfa, "arg" => %{"module" => m, "app" => app}},
        %Context{} = ctx,
        owner
      )
      when is_binary(mfa) and is_binary(m) and is_binary(app) do
    cond do
      app in @always -> :ignore
      app != @tracer_app and Context.dep?(ctx, owner) and app in path_of(ctx, owner) -> :ignore
      true -> {:unjudged, "compile-time call into a module the trace loaded: #{mfa} (#{app})"}
    end
  end

  def decide(
        %{"channel" => "probe", "arg" => %{"module" => module} = arg} = event,
        %Context{} = ctx,
        owner
      )
      when is_binary(module) do
    case app(arg, module, ctx) do
      nil -> :ignore
      app -> decide(event, module, app, ctx, owner)
    end
  end

  def decide(event, _ctx, _owner),
    do: {:unjudged, "unreadable probe event: #{inspect(event["mfa"])}"}

  defp decide(event, module, app, ctx, owner) do
    cond do
      nested?(event) -> :ignore
      event["mfa"] in @path_probes -> on_path(module, app, ctx, owner)
      true -> {:unjudged, "#{why(module, app)} by #{event["mfa"]}"}
    end
  end

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
      {:unjudged, why} -> {:unjudged, "#{why}, in a window with a nested compile (#{nested})"}
      :ignore -> :ignore
    end
  end

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
