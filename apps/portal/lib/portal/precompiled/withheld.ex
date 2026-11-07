defmodule Portal.Precompiled.Withheld do
  @moduledoc """
  Packages whose presence in a build's dependency closure keeps that build
  from being served: the one rule every precompiled selector applies
  (`Portal.Catalog.precompiled_manifest/1`, `precompiled_manifest_v2/1`,
  `precompiled_manifests/1`, `packages_with_precompiled_files/0` and
  `published_sha256?/1`), so the manifests, the batch and the file route
  agree on what is published.

  A build is withheld when it has no recorded lock at all and so an unknown
  closure, or when the package itself is on the list or its recorded
  dependency lock (`deps_lock`; for a system result the result's own lock,
  else the lock of the run that built it) names a package on the list, unless
  it records its compile-time config reads (`records_config_reads?/1`). The same
  selectors also leave out a system result whose files were withdrawn
  (`Portal.Catalog.SystemResult`'s `unpublished_at`), in the same predicate.

  Why: some packages change what their dependents compile to through
  application config the user's project sets and our builds do not. Every
  new Phoenix 1.8 app sets `config :phoenix_live_view, root_tag_attribute:
  "phx-r"`, which `Phoenix.LiveView.TagEngine` reads at compile time and
  which changes the markup of every `~H` root tag, and LiveView's colocated
  hooks, JS and CSS write asset files at compile time that installing BEAMs
  never provides. A build whose closure has `phoenix_live_view` therefore
  differs from what the user's own compile produces, and such a build is not
  served unless it records the compile-time config reads its compile made
  (see `withheld?/4`).

  Configured with `config :portal, #{inspect(__MODULE__)}, packages: [...]`.
  Without that key, or with anything but a list of strings, the default
  (`#{inspect(["phoenix_live_view"])}`) applies, so a misconfiguration
  withholds rather than publishes. An empty list withholds nothing.
  """

  @default ["phoenix_live_view"]

  @doc "The withheld package names, sorted."
  @spec packages() :: [String.t()]
  def packages do
    case Application.get_env(:portal, __MODULE__, [])[:packages] do
      list when is_list(list) ->
        if Enum.all?(list, &is_binary/1), do: Enum.sort(list), else: @default

      _ ->
        @default
    end
  end

  @doc """
  Whether a build of `package_name` whose dependency lock is `deps_lock` is
  withheld. `deps_lock` is the `name => %{"version", "checksum"}` map a build
  records; `build` is the toolchain build or system result itself (anything
  with its `compile_env_rule` and `compile_env`), or `nil`.

  A build that records its compile-time config reads
  (`records_config_reads?/1`) is not withheld for its closure: its
  `compile_env` lists the config the closure read while compiling, so a
  client whose config differs does not match it and compiles the package
  itself, and the compile-time trace that made it refuses compile-time file
  writes such as LiveView's colocated assets. That lifts only the closure
  check, never the one below.

  A build with no lock (`nil`: format 1's `"deps": null`, from before builds
  recorded one, or a lock ingest rejected) has an unknown closure, so it is
  withheld whenever the list is not empty, whatever it records. The portal
  stores no other record of a build's closure: the package's declared
  dependencies live only in the Hex registry, which a render must not depend
  on (a registry outage would be pinned into the batch memo), and they name
  only direct dependencies, so they could never clear a build whose closure
  reaches a withheld package transitively.
  """
  @spec withheld?(String.t(), map() | nil, [String.t()], map() | nil) :: boolean()
  def withheld?(package_name, deps_lock, packages \\ packages(), build \\ nil)

  def withheld?(_package_name, _deps_lock, [], _build), do: false
  def withheld?(_package_name, deps_lock, _packages, _build) when not is_map(deps_lock), do: true

  def withheld?(package_name, deps_lock, packages, build) do
    not records_config_reads?(build) and
      (package_name in packages or Enum.any?(packages, &Map.has_key?(deps_lock, &1)))
  end

  @doc """
  Whether `build` records its compile-time config reads (R5): rule 1
  (`compile_env_rule`) next to a `compile_env` list. Any other rule, or a
  rule without the list, does not count: a rule this portal does not know
  says nothing it can check. A system result counts only as `pure_elixir`,
  the one run result whose build traces its compile; firmware results never
  record their config reads.
  """
  @spec records_config_reads?(map() | nil) :: boolean()
  def records_config_reads?(%{system_pkg: system_pkg}) when system_pkg != "pure_elixir",
    do: false

  def records_config_reads?(%{compile_env_rule: 1, compile_env: env}) when is_list(env), do: true
  def records_config_reads?(_build), do: false
end
