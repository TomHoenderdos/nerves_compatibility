defmodule Compatibility.OptionalDeps do
  @moduledoc """
  The optional dependencies a published build is never made with, shared by
  the worker that leaves them out (`NccWorker.Project.optional_deps_to_add/1`)
  and the portal that checks a build has the rest
  (`Portal.Catalog.Coverage`). One list on purpose: a name the worker skips
  but the portal still expects would count every build of that package as
  missing its optional dependencies.

  The worker adds a package's unresolved optional dependencies so its
  published files match an application that has them in its lock. Not every
  optional dependency is one an application has. A client matches an entry
  only when every dependency in its `build.deps` that the client also locks
  agrees, and the entry carries the whole closure of what was added, so an
  optional dependency most applications do not lock makes the entry miss for
  all of them. These are those:

    * dev and code-generation tooling packages declare optional so their
      installers and tasks work in an app that has it: `igniter`,
      `sourceror`, `rewrite` (mdns_lite declares `igniter`, which would drag
      its whole closure into the key), `ex_doc`, `credo`, `dialyxir`,
      `stream_data`, `excoveralls`, `mix_test_watch`, `benchee`.
    * alternatives an application picks one of: `picosat_elixir` and
      `simple_sat` (crux declares both), where adding both builds a tree no
      application has.

  A module attribute rather than config: it describes what a real
  application's lock looks like, not a deployment choice, and the worker's
  `optional_deps.skipped` lists what it set aside.
  """

  @never_added ~w(
    igniter sourceror rewrite ex_doc credo dialyxir stream_data excoveralls
    mix_test_watch benchee picosat_elixir simple_sat
  )

  @doc "Names, as application or Hex package name, never added to a build."
  @spec never_added() :: [String.t()]
  def never_added, do: @never_added
end
