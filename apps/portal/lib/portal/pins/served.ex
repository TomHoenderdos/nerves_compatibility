defmodule Portal.Pins.Served do
  @moduledoc """
  Which pinned builds (`Portal.Catalog.PinnedBuild`) a manifest lists
  (lock-driven builds spec, section 3).

  A pinned build is served when it passed, is neither revoked (every
  revocation lever, `Portal.Catalog.revoke_run/1` included) nor withdrawn
  (`unpublished_at`), is the default config variant of a target this release
  builds (`Portal.Workers.PinnedBuild.targets/0`), was built locally or by a
  builder that is enrolled and publishing, and is not withheld
  (`Portal.Precompiled.Withheld`, on its own `deps_lock`, as any build). The
  files route, the package list and the batch fingerprints apply the same
  predicate in SQL (`Portal.Catalog`'s `@served_pinned_clause`).

  A manifest lists at most 8 of them per (package, version, target,
  system version), most distinct reporters first, then newest (`cap/1`);
  the rest stay stored and unlisted.
  """

  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, PinnedBuild}
  alias Portal.Precompiled.Withheld

  @cap 8

  @doc "The most pinned closures one (package, version, target, system version) lists."
  @spec cap() :: pos_integer()
  def cap, do: @cap

  @doc "The served pinned builds of a package, by id and name, capped (`cap/1`)."
  @spec served(Ecto.UUID.t(), String.t(), [String.t()]) :: [PinnedBuild.t()]
  def served(package_id, package_name, withheld \\ Withheld.packages()) do
    targets = Portal.Workers.PinnedBuild.targets()

    PinnedBuild
    |> Ash.Query.filter(
      package_id == ^package_id and status == :pass and is_nil(revoked_at) and
        is_nil(unpublished_at) and config_variant == "default" and target in ^targets
    )
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.reject(&withheld?(&1, package_name, withheld))
    |> only_publishing()
    |> cap()
  end

  defp only_publishing(builds) do
    if Enum.all?(builds, &is_nil(&1.builder_id)) do
      builds
    else
      builders = publishing_builders()
      Enum.filter(builds, &publishing?(&1, builders))
    end
  end

  @doc """
  At most `cap/0` builds per (version, target, system version): the most
  distinct reporters first, then the newest, then by run id, so the pick and
  the manifest's bytes do not depend on read order.
  """
  @spec cap([PinnedBuild.t()]) :: [PinnedBuild.t()]
  def cap(builds) do
    builds
    |> Enum.group_by(&{&1.version, &1.target, &1.system_version})
    |> Enum.flat_map(fn {_key, group} ->
      group |> Enum.sort_by(&rank/1, :desc) |> Enum.take(@cap)
    end)
  end

  defp rank(build) do
    at = if build.finished_at, do: DateTime.to_unix(build.finished_at, :microsecond), else: -1
    {build.reporters || 0, at, build.run_id || ""}
  end

  defp withheld?(build, package_name, withheld) do
    Withheld.withheld?(package_name, build.deps_lock, withheld, %{
      compile_env_rule: build.compile_env_rule,
      compile_env: build.compile_env,
      run_id: build.run_id,
      compile_env_run_id: build.run_id
    })
  end

  defp publishing?(%{builder_id: nil}, _builders), do: true
  defp publishing?(%{builder_id: id}, builders), do: MapSet.member?(builders, id)

  defp publishing_builders do
    %{rows: rows} =
      Portal.Repo.query!(
        "SELECT id FROM builders WHERE publishing AND status = 'enrolled'",
        []
      )

    MapSet.new(rows, fn [id] -> Ecto.UUID.load!(id) end)
  end

  @doc "The stored file shas of each pinned build, by build id."
  @spec membership_shas([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => MapSet.t()}
  def membership_shas([]), do: %{}

  def membership_shas(ids) do
    ArtifactMembership
    |> Ash.Query.filter(pinned_build_id in ^ids)
    |> Ash.Query.select([:pinned_build_id, :sha256])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.pinned_build_id, & &1.sha256)
    |> Map.new(fn {id, shas} -> {id, MapSet.new(shas)} end)
  end
end
