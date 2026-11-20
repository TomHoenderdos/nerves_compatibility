defmodule NccWorker.Gleam do
  @moduledoc """
  The Gleam packages of a toolchain run's closure, which Mix cannot build.

  A Gleam release on Hex carries its `gleam.toml` and the Erlang it
  generated, but no file Mix picks a build tool by (`mix.exs`, `rebar`,
  `rebar.config`, `rebar.config.script`, `rebar.lock`, `Makefile`,
  `Makefile.win`), and Hex locks it with no manager Mix has (`[:gleam]`,
  or `[]` for some). Mix's `deps.compile` then stops with `Could not compile
  :<app>, no "mix.exs", "rebar.config" or "Makefile"`, as it does in a
  user's own project unless that project gives the dependency a `:manager`
  (which a precompiled client takes as a miss) or builds it with
  `mix_gleam`. Such a closure is not a Mix build, so it is skipped with the
  full run's reason for a Gleam package, never compiled and never a failure.

  A locked dependency is a Gleam one when its lock entry names none of
  `:mix`, `:rebar3` and `:make`, none of those build files is in its
  `deps/` dir, and its entry names `:gleam` or its dir holds `gleam.toml`.
  One Mix can build (a manager it has, or a build file) is compiled as any
  other.
  """

  alias NccWorker.DepsLock

  @build_files ~w(mix.exs rebar rebar.config rebar.config.script rebar.lock Makefile Makefile.win)
  @mix_managers [:mix, :rebar3, :make]

  @doc """
  Why the closure of `package` (its app, the lock key) in `project_dir` is
  not a Mix build: `"Package uses gleam build tool"` when the package is a
  Gleam one, `"dependency uses gleam build tool: <apps>"` when only
  dependencies are; nil otherwise, or when the lock cannot be read.
  """
  @spec skip_reason(String.t(), String.t()) :: String.t() | nil
  def skip_reason(project_dir, package) do
    case DepsLock.lock(project_dir) do
      {:ok, lock} ->
        gleam = for {app, entry} <- lock, gleam?(project_dir, app, entry), do: app

        cond do
          package in gleam -> "Package uses gleam build tool"
          gleam != [] -> "dependency uses gleam build tool: " <> Enum.join(Enum.sort(gleam), ", ")
          true -> nil
        end

      _ ->
        nil
    end
  end

  defp gleam?(project_dir, app, {:hex, _pkg, _version, _inner, managers, _deps, _repo, _outer})
       when is_list(managers) do
    dir = Path.join([project_dir, "deps", app])

    not Enum.any?(@mix_managers, &(&1 in managers)) and
      not Enum.any?(@build_files, &file?(dir, &1)) and
      (:gleam in managers or file?(dir, "gleam.toml"))
  end

  defp gleam?(_project_dir, _app, _entry), do: false

  # A file of a dependency Mix fetched into the run's own project.
  # sobelow_skip ["Traversal.FileModule"]
  defp file?(dir, name), do: File.regular?(Path.join(dir, name))
end
