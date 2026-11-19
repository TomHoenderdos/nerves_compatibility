defmodule Portal.Deterministic do
  @moduledoc """
  Deterministic siblings (design addendum to option (a)): a toolchain
  build's package compiled again in the same run with
  `ERL_COMPILER_OPTIONS=deterministic` (`NccWorker.Deterministic`), stored as
  `Portal.Catalog.DeterministicBuild` and published under a version's
  `deterministic` key in the format-2 manifest, which only a client whose
  project sets exactly that option reads, in place of the version's other
  lists.

  Everything here is behind the `deterministic_builds_enabled` setting
  (`Portal.Settings`, off by default): with it off no toolchain run is asked
  for a sibling (`Portal.Workers.ToolchainBuild`), no manifest lists one
  (`served/1`), and `Portal.Catalog`'s SQL selectors (the files route, the
  batch fingerprints) leave them out by the same predicate. Rows ingested
  while it was on stay stored.

  A sibling is served only beside its toolchain build, while that build is
  served (a pass, not revoked, not withheld, a named config variant only
  beside its served default: every lever that withdraws a toolchain build)
  and of the run the sibling was built in, and only while the sibling
  itself passed and is not revoked
  (`Portal.Precompiled.DeterministicRevocation`). Every file its manifest
  lists must be a stored membership of it.
  """

  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, DeterministicBuild, PinnedBuild, ToolchainBuild}
  alias Portal.Repo

  @doc "Whether siblings are asked for and published."
  @spec enabled?() :: boolean()
  def enabled?, do: Portal.Settings.get().deterministic_builds_enabled == true

  @doc """
  The siblings to publish beside `toolchain_builds`, the served toolchain
  builds of one package (`Portal.Catalog`'s, earlier builds' virtual rows
  included): none while the setting is off; else each passing, unrevoked
  sibling whose toolchain build is among them with the sibling's own run.
  """
  @spec served([map()]) :: [DeterministicBuild.t()]
  def served(toolchain_builds) do
    if toolchain_builds != [] and enabled?() do
      runs = MapSet.new(toolchain_builds, &{&1.id, &1.run_id})
      ids = toolchain_builds |> Enum.map(& &1.id) |> Enum.uniq()

      DeterministicBuild
      |> Ash.Query.filter(toolchain_build_id in ^ids and status == :pass and is_nil(revoked_at))
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.filter(&MapSet.member?(runs, {&1.toolchain_build_id, &1.run_id}))
    else
      []
    end
  end

  @doc """
  The siblings to publish beside `pinned_builds`, the served pinned builds
  of one package (`Portal.Catalog`): none while the setting is off; else
  each passing, unrevoked sibling of one of them with its run.
  """
  @spec served_pinned([PinnedBuild.t()]) :: [DeterministicBuild.t()]
  def served_pinned(pinned_builds) do
    if pinned_builds != [] and enabled?() do
      runs = MapSet.new(pinned_builds, &{&1.id, &1.run_id})
      ids = Enum.map(pinned_builds, & &1.id)

      DeterministicBuild
      |> Ash.Query.filter(pinned_build_id in ^ids and status == :pass and is_nil(revoked_at))
      |> Ash.read!(domain: Portal.Catalog)
      |> Enum.filter(&MapSet.member?(runs, {&1.pinned_build_id, &1.run_id}))
    else
      []
    end
  end

  @doc "The stored file shas of each sibling, by sibling id."
  @spec membership_shas([Ecto.UUID.t()]) :: %{Ecto.UUID.t() => MapSet.t()}
  def membership_shas([]), do: %{}

  def membership_shas(ids) do
    ArtifactMembership
    |> Ash.Query.filter(deterministic_build_id in ^ids)
    |> Ash.Query.select([:deterministic_build_id, :sha256])
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.group_by(& &1.deterministic_build_id, & &1.sha256)
    |> Map.new(fn {id, shas} -> {id, MapSet.new(shas)} end)
  end

  @doc """
  In the transaction that wrote `toolchain_build`
  (`Portal.Catalog.Ingestion`): removes its sibling, memberships with it, and
  stores `sibling` (`Portal.Deterministic.Ingest.candidate/3`'s, its files'
  blobs registered already) when the build passed. `nil` stores none, so a
  rebuild that brought no sibling leaves its build without one.
  """
  @spec replace(ToolchainBuild.t() | PinnedBuild.t(), map() | nil) :: :ok | {:error, term()}
  def replace(%ToolchainBuild{} = toolchain_build, sibling),
    do: replace(toolchain_build, :toolchain_build_id, sibling)

  # A pinned build's sibling, the same way (`Portal.Catalog.Ingestion`).
  def replace(%PinnedBuild{} = pinned_build, sibling),
    do: replace(pinned_build, :pinned_build_id, sibling)

  # `owner` is the column the sibling's build is named by.
  defp replace(build, owner, sibling) do
    Repo.query!(delete_sql(owner), [Ecto.UUID.dump!(build.id)])

    case {build.status, sibling} do
      {:pass, %{} = sibling} -> insert(build, owner, sibling)
      _ -> :ok
    end
  end

  defp delete_sql(:toolchain_build_id),
    do: "DELETE FROM catalog_deterministic_builds WHERE toolchain_build_id = $1"

  defp delete_sql(:pinned_build_id),
    do: "DELETE FROM catalog_deterministic_builds WHERE pinned_build_id = $1"

  defp insert(build, owner, sibling) do
    attrs = %{
      owner => build.id,
      package_id: build.package_id,
      version: build.version,
      run_id: build.run_id,
      status: :pass,
      erl_compiler_options: Compatibility.DeterministicBeams.options(),
      judge_revision: sibling["judge_revision"],
      file_manifest: sibling["file_manifest"],
      compile_observations: sibling["compile_observations"],
      finished_at: build.finished_at
    }

    with {:ok, row} <-
           DeterministicBuild
           |> Ash.Changeset.for_create(:create, attrs)
           |> Ash.create(domain: Portal.Catalog) do
      memberships(row, sibling["shas"])
    end
  end

  defp memberships(_row, []), do: :ok

  defp memberships(row, shas) do
    shas
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.map(&%{sha256: &1, deterministic_build_id: row.id})
    |> Ash.bulk_create(ArtifactMembership, :upsert_deterministic,
      domain: Portal.Catalog,
      upsert?: true,
      upsert_identity: :unique_deterministic_build_sha256,
      upsert_fields: [:sha256],
      return_errors?: true,
      stop_on_error?: true,
      transaction: false
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{errors: errors} -> {:error, {:deterministic_memberships, errors}}
    end
  end
end
