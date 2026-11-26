defmodule NccWorker.Portability.DefinedModules do
  @moduledoc """
  The modules a package's compile defined that its ebin does not hold (S10
  fix round 1, the client review's B2 and B3): a client deciding a `probe`
  compile input needs every module a dependency outside the build's closure
  can put in the user's VM, and the ebin is not all of it. A compile can
  define modules in memory that a later dependency's compile in the same VM
  finds: a `.exs` file that the package's `mix.exs` or a module body loads
  (`Code.require_file/2`), `Code.compile_string/2`, `Module.create/3`, a beam
  loaded from outside an ebin.

  The tracer lists every module loaded at the end of the Mix VM's compile
  that no ebin dir holds, with the source its compile names (the end line's
  `in_memory`, `:ncc_tracer`). `of/2` attributes each to the application
  whose dir (its source dir or its build dir) holds that source:

    * the package's: listed;
    * another closure application's, or the project's own (its `mix.exs`,
      outside the deps and build dirs): that one's, not listed;
    * any other source (none, `nofile`, a path outside the project): no
      list at all (`nil`), as such a module may be the package's.

  Elixir's own transient modules, `elixir_compiler_<n>` (the module body or
  file it evaluated, numbered in the order this VM evaluated them, from
  Elixir's `bin/mix` on), are left out: every VM has its own, and none is a
  package's. A list over the tracer's cap, or no list on the end line, is
  `nil` too.
  The portal serves the list beside the build's ebin
  (`build.defined_modules`); a client takes the two together as the
  package's exact module list only for a build that matches its project,
  where its own compile of the package is this one.
  """

  alias Compatibility.CompileInputs
  alias NccWorker.Portability.Context

  @max 4000

  @doc "The package's in-memory modules, sorted, or `nil` when they cannot be told (see the moduledoc)."
  @spec of(Context.t(), map() | nil) :: [String.t()] | nil
  def of(%Context{} = ctx, %{"in_memory" => items, "in_memory_over" => false})
      when is_list(items) and length(items) <= @max do
    if Context.dep?(ctx, ctx.package), do: attribute_all(ctx, items)
  end

  def of(_ctx, _ending), do: nil

  defp attribute_all(ctx, items) do
    own = dirs(ctx, ctx.package)

    others =
      for app <- Context.closure_of(ctx, ctx.package),
          app != ctx.package,
          d <- dirs(ctx, app),
          do: d

    result =
      items
      |> Enum.reject(&transient?/1)
      |> Enum.reduce_while([], fn item, acc ->
        case attribute(item, own, others, ctx) do
          {:package, module} -> {:cont, [module | acc]}
          :other -> {:cont, acc}
          :unknown -> {:halt, :unknown}
        end
      end)

    if result == :unknown, do: nil, else: result |> Enum.uniq() |> Enum.sort()
  end

  defp transient?(%{"module" => "elixir_compiler_" <> n}), do: n != "" and n =~ ~r/\A\d+\z/
  defp transient?(_item), do: false

  defp attribute(%{"module" => module, "source" => source}, own, others, ctx)
       when is_binary(module) and is_binary(source) do
    real = Context.realpath(source)

    cond do
      not CompileInputs.module_name?(module) or real == nil -> :unknown
      Enum.any?(own, &Context.under?(real, &1)) -> {:package, module}
      Enum.any?(others, &Context.under?(real, &1)) -> :other
      project_own?(real, ctx) -> :other
      true -> :unknown
    end
  end

  defp attribute(_item, _own, _others, _ctx), do: :unknown

  # An application's source dir and build dir, resolved.
  defp dirs(ctx, app) do
    dep = ctx.deps[app]

    [dep && dep.dest, dep && dep.build]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&Context.realpath/1)
    |> Enum.filter(&is_binary/1)
  end

  # The project's own files (its `mix.exs`, its config): a regular file
  # under the project dir, outside its deps and build dirs. Not a name that
  # is no file (a `nofile` source, made from the cwd).
  # sobelow_skip ["Traversal.FileModule"]
  defp project_own?(real, %Context{project_dir: project} = ctx) when is_binary(project) do
    deps = Context.deps_path(ctx)
    build = Context.realpath(Path.join(project, "_build"))

    Context.under?(real, project) and not (is_binary(deps) and Context.under?(real, deps)) and
      not (is_binary(build) and Context.under?(real, build)) and File.regular?(real)
  end

  defp project_own?(_real, _ctx), do: false
end
