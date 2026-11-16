defmodule Portal.Catalog.ToolchainEarlierBuildsTest do
  @moduledoc """
  A rebuild of a toolchain build identity with another dependency lock keeps
  the build it replaced (`Portal.Catalog.ToolchainBuild.EarlierBuilds`): a
  project still locked at the older dependency keeps its hit.
  """

  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.ToolchainBuild
  alias Portal.Catalog.ToolchainBuild.EarlierBuilds

  defp name, do: "earlier_#{System.unique_integer([:positive])}"

  defp lock(certifi), do: %{"certifi" => %{"version" => certifi, "checksum" => "c-#{certifi}"}}

  defp builds(name) do
    case Catalog.precompiled_manifest_v2(name) do
      nil -> []
      %{"versions" => versions} -> versions |> Map.values() |> Enum.flat_map(& &1["builds"])
    end
  end

  defp served_locks(name),
    do:
      name
      |> builds()
      |> Enum.map(&get_in(&1, ["build", "deps", "certifi", "version"]))
      |> Enum.sort()

  defp memberships(id) do
    %{rows: rows} =
      Repo.query!(
        "SELECT sha256 FROM catalog_artifact_memberships WHERE toolchain_build_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    rows |> List.flatten() |> MapSet.new()
  end

  defp shas(%{"ebin" => ebin}), do: Enum.map(ebin, & &1["sha256"])

  test "a rebuild with another lock keeps serving the build it replaced" do
    name = name()
    old = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    new = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))

    assert new.id == old.id
    assert new.deps_lock == lock("2.19.0")
    assert [%{"deps_lock" => kept}] = new.earlier_builds
    assert kept == lock("2.18.0")

    assert served_locks(name) == ["2.18.0", "2.19.0"]

    assert MapSet.equal?(
             memberships(new.id),
             MapSet.new(shas(old.file_manifest) ++ shas(new.file_manifest))
           )
  end

  test "a rebuild with the same lock keeps no earlier build" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    new = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    assert new.earlier_builds in [nil, []]
    assert served_locks(name) == ["2.18.0"]
    assert MapSet.equal?(memberships(new.id), MapSet.new(shas(new.file_manifest)))
  end

  test "at most #{EarlierBuilds.max()} earlier builds are kept, newest first" do
    name = name()
    versions = for minor <- 15..19, do: "2.#{minor}.0"
    for version <- versions, do: ingest_toolchain_build(name, "0.4.0", deps_lock: lock(version))

    row = row(name)
    kept = Enum.map(row.earlier_builds, &get_in(&1, ["deps_lock", "certifi", "version"]))
    assert kept == ["2.18.0", "2.17.0", "2.16.0"]
    assert served_locks(name) == ["2.16.0", "2.17.0", "2.18.0", "2.19.0"]
  end

  test "a rebuild back to an earlier lock drops that lock from the earlier builds" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    back = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))

    assert [%{"deps_lock" => kept}] = back.earlier_builds
    assert kept == lock("2.19.0")
    assert served_locks(name) == ["2.18.0", "2.19.0"]
  end

  # A refusal or a skip is a verdict on the package's build, not on a lock.
  test "a rebuild that does not pass drops the earlier builds with its own" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    skipped = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.20.0"), status: "skipped")

    assert skipped.earlier_builds == []
    assert memberships(skipped.id) == MapSet.new()
    assert served_locks(name) == []
  end

  test "a revoked row serves none of its earlier builds" do
    name = name()
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    passing = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))
    assert served_locks(name) == ["2.18.0", "2.19.0"]

    passing |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    assert served_locks(name) == []
  end

  test "an earlier build whose file the row no longer owns is left out whole" do
    name = name()
    old = ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.18.0"))
    ingest_toolchain_build(name, "0.4.0", deps_lock: lock("2.19.0"))

    # What a release that does not know the column leaves behind: its ingest
    # replaces the row's memberships with its own build's files alone.
    Repo.query!(
      "DELETE FROM catalog_artifact_memberships WHERE toolchain_build_id = $1 AND sha256 = ANY($2)",
      [Ecto.UUID.dump!(old.id), shas(old.file_manifest)]
    )

    assert served_locks(name) == ["2.19.0"]
  end

  describe "push/3" do
    defp passing(certifi, overrides \\ []) do
      struct!(
        %ToolchainBuild{
          status: :pass,
          deps_lock: lock(certifi),
          file_manifest: %{"ebin" => []},
          finished_at: ~U[2026-11-01 00:00:00.000000Z]
        },
        overrides
      )
    end

    test "puts the replaced build first and drops any of the new lock" do
      replaced =
        passing("2.18.0",
          earlier_builds: [%{"deps_lock" => lock("2.19.0")}, %{"deps_lock" => lock("2.17.0")}]
        )

      assert [%{"deps_lock" => first}, %{"deps_lock" => second}] =
               EarlierBuilds.push(replaced, replaced.earlier_builds, passing("2.19.0"))

      assert first == lock("2.18.0")
      assert second == lock("2.17.0")
    end

    test "keeps the list as it was when the replaced row serves nothing" do
      earlier = [%{"deps_lock" => lock("2.17.0")}]

      for replaced <- [
            passing("2.18.0", status: :skipped, file_manifest: nil),
            passing("2.18.0", revoked_at: ~U[2026-11-01 00:00:00.000000Z]),
            nil
          ] do
        assert EarlierBuilds.push(replaced, earlier, passing("2.19.0")) == earlier
      end
    end

    test "keeps nothing beside a rebuild that does not pass" do
      assert EarlierBuilds.push(passing("2.18.0"), [], passing("2.19.0", status: :skipped)) == []
    end

    # A revocation selects rows by verdict, and hides a row's earlier builds
    # with it: an entry it would select must sit beside a row it selects too.
    test "keeps only the builds of the new row's verdict class" do
      rule2 = passing("2.18.0", portability_rule: 2, rule1_reason: "reads os:type/0")

      assert EarlierBuilds.push(rule2, [], passing("2.19.0", portability_rule: 1)) == []
      assert EarlierBuilds.push(rule2, [], passing("2.19.0", portability_rule: 2)) == []

      assert [%{"deps_lock" => kept}] =
               EarlierBuilds.push(
                 rule2,
                 [],
                 passing("2.19.0", portability_rule: 2, rule1_reason: "reads os:type/0")
               )

      assert kept == lock("2.18.0")

      assert [_] =
               EarlierBuilds.push(passing("2.18.0"), [], passing("2.19.0", portability_rule: 1))
    end
  end

  defp row(name) do
    ToolchainBuild
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read_one!(domain: Catalog)
  end
end
