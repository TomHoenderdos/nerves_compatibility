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
  A named config variant of a toolchain build is served only beside its
  served default (`config_variant_served?/2`).

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
  Whether a toolchain build's config variant lets it be served
  (precompiled portability spec, R7): a `"default"` build always; a named
  variant only when it records its config reads (`records_config_reads?/1`,
  whatever the withheld list) and its `default` sibling (same version,
  toolchain, builder version and optional-deps variant) is a pass that is not
  revoked, in `served`: the package's toolchain builds that every other rule
  serves (passing, unrevoked and not `withheld?/4`). A refusal, a revocation
  or a withholding of the default applies to every config variant of it.
  """
  @spec config_variant_served?(map(), [map()]) :: boolean()
  def config_variant_served?(%{config_variant: "default"}, _served), do: true

  def config_variant_served?(build, served) do
    records_config_reads?(build) and Enum.any?(served, &default_of?(&1, build))
  end

  defp default_of?(d, build) do
    d.config_variant == "default" and d.status == :pass and is_nil(d.revoked_at) and
      {d.version, d.toolchain, d.builder_version, d.variant} ==
        {build.version, build.toolchain, build.builder_version, build.variant}
  end

  @doc """
  Whether `build` records its compile-time config reads (R5): rule 1
  (`compile_env_rule`) next to a `compile_env` list. Any other rule, or a
  rule without the list, does not count: a rule this portal does not know
  says nothing it can check. A system result counts only as `pure_elixir`,
  the one run result whose build traces its compile; firmware results never
  record their config reads. A toolchain build's mark counts only while the
  run that wrote it (`compile_env_run_id`) is the row's own `run_id`: a
  release that does not know that column rebuilds the row with its own
  `run_id` and `compile_env` and leaves the mark, which then vouches for
  nothing. A build with no `run_id` never counts.
  """
  @spec records_config_reads?(map() | nil) :: boolean()
  def records_config_reads?(%{system_pkg: "pure_elixir", compile_env_rule: 1, compile_env: env})
      when is_list(env),
      do: true

  def records_config_reads?(%{system_pkg: _system_pkg}), do: false

  def records_config_reads?(%{
        compile_env_rule: 1,
        compile_env: env,
        run_id: run_id,
        compile_env_run_id: run_id
      })
      when is_list(env) and is_binary(run_id),
      do: true

  def records_config_reads?(_build), do: false
end
