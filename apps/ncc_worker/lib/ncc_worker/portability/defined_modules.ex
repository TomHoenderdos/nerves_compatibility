defmodule NccWorker.Portability.DefinedModules do
  @moduledoc """
  The modules a package's compile defined or loaded that its ebin does not
  hold (S10 fix round 1, the client review's B2 and B3): a client deciding a
  `probe` compile input needs every module a dependency outside the build's
  closure can put in the user's VM, and the ebin is not all of it. A compile
  can define modules in memory that a later dependency's compile in the same
  VM finds: a `.exs` file that the package's `mix.exs` or a module body
  loads (`Code.require_file/2`), `Code.compile_string/2`, `Module.create/3`,
  a beam loaded from outside a build ebin.

  The tracer lists every module loaded at the end of the Mix VM's compile
  that no project build ebin, consolidated dir, OTP install, Elixir install
  or Mix archive holds, with the source its compile names (the end line's
  `in_memory`, `:ncc_tracer`; review U10: an `ebin` anywhere else, such as
  a vendored prebuilt, is listed too). `of/2` lists every one of them
  (S10 re-review R3: whatever file it came from, the package's own,
  another closure app's or the project's; a module only this package's
  compile loaded from another app's file is in no other list), except
  Elixir's own transient `elixir_compiler_<n>` modules (the module body or
  file it evaluated, numbered in the order this VM evaluated them, from
  Elixir's `bin/mix` on: every VM has its own, and none is a package's).
  Listing more than the package defines is conservative: a client only
  misses more. A list over the tracer's cap, a name no module has, or no
  list on the end line is `nil`.

  The portal serves the list beside the build's ebin
  (`build.defined_modules`); a client takes the two together as the
  package's exact module list only for a build that matches its project,
  where its own compile of the package is this one.
  """

  alias Compatibility.CompileInputs
  alias NccWorker.Portability.Context

  @max 4000

  @doc "The modules the compile defined or loaded outside a build ebin, sorted, or `nil` (see the moduledoc)."
  @spec of(Context.t(), map() | nil) :: [String.t()] | nil
  def of(%Context{} = ctx, %{"in_memory" => items, "in_memory_over" => false})
      when is_list(items) and length(items) <= @max do
    if Context.dep?(ctx, ctx.package), do: listed(items)
  end

  def of(_ctx, _ending), do: nil

  defp listed(items) do
    modules = items |> Enum.map(&Map.get(&1, "module")) |> Enum.reject(&transient?/1)

    if Enum.all?(modules, &CompileInputs.module_name?/1),
      do: modules |> Enum.uniq() |> Enum.sort()
  end

  defp transient?("elixir_compiler_" <> n), do: n != "" and n =~ ~r/\A\d+\z/
  defp transient?(_module), do: false
end
