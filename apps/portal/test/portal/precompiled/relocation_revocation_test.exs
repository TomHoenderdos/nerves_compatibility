defmodule Portal.Precompiled.RelocationRevocationTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Precompiled.RelocationRevocation

  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 3]

  defp record(name), do: Portal.Test.RelocationFixtures.record(name)

  setup do
    {:ok, _} = Portal.Settings.save(%{relocated_enabled: true})
    a = "rel_a_#{System.unique_integer([:positive])}"
    b = "rel_b_#{System.unique_integer([:positive])}"
    ra = ingest_toolchain_build(a, "1.0.0", compile_env_rule: 1, relocation: record(a))
    rb = ingest_toolchain_build(b, "1.0.0", compile_env_rule: 1, relocation: record(b))
    plain = ingest_toolchain_build("jason", "1.4.4", compile_env_rule: 1)
    %{a: a, b: b, ra: ra, rb: rb, plain: plain}
  end

  defp listed?(name),
    do:
      get_in(Catalog.precompiled_manifest_v2(name) || %{}, ["versions", "1.0.0", "relocated"]) !=
        nil

  test "a dry run is the default, counts, and writes nothing", %{a: a, b: b} do
    assert {:dry_run, rows} = RelocationRevocation.revoke(package: a)
    assert [%{package: ^a, version: "1.0.0"}] = rows
    assert {:dry_run, all} = RelocationRevocation.revoke()

    assert Enum.map(all, & &1.package) |> Enum.filter(&(&1 in [a, b])) |> Enum.sort() ==
             Enum.sort([a, b])

    assert listed?(a)
  end

  # The umbrella re-review's Q1: a dependent that passed because a
  # dependency was held is gated as a relocated build, so the same lever
  # takes it back.
  test "a dependent's relocated pass is selected and revoked too", _ctx do
    d = "rel_dep_#{System.unique_integer([:positive])}"

    ingest_toolchain_build(d, "1.0.0",
      compile_env_rule: 1,
      relocation: Portal.Test.RelocationFixtures.dependent_record()
    )

    assert listed?(d)
    assert {:dry_run, [%{package: ^d}]} = RelocationRevocation.revoke(package: d)

    assert {:revoked, 1, [%{package: ^d}], _at} =
             RelocationRevocation.revoke(package: d, dry_run: false)

    refute listed?(d)
  end

  test "an act needs a filter", _ctx do
    assert {:error, :filter_required} = RelocationRevocation.revoke(dry_run: false)
  end

  test "revoking a package takes its relocated builds out; undo puts them back", %{
    a: a,
    b: b,
    plain: plain
  } do
    assert {:revoked, 1, [%{package: ^a}], at} =
             RelocationRevocation.revoke(package: a, dry_run: false)

    refute listed?(a)
    assert listed?(b)

    assert Ash.get!(Portal.Catalog.ToolchainBuild, plain.id, domain: Portal.Catalog).revoked_at ==
             nil

    assert RelocationRevocation.undo(at) == 1
    assert listed?(a)
  end

  test "everything revokes every relocated build and no other", %{a: a, b: b, plain: plain} do
    assert {:revoked, n, _rows, _at} =
             RelocationRevocation.revoke(everything: true, dry_run: false)

    assert n >= 2
    refute listed?(a)
    refute listed?(b)

    assert Ash.get!(Portal.Catalog.ToolchainBuild, plain.id, domain: Portal.Catalog).revoked_at ==
             nil
  end

  # The umbrella review's S1: a row whose own build is plain and whose
  # earlier build (another lock) is relocated is selected too; revoking the
  # row hides its earlier builds.
  test "a relocated earlier build is selected and revoked with its row", %{a: a} do
    lock = %{"decimal" => %{"version" => "2.1.2", "checksum" => "def"}}

    _plain =
      ingest_toolchain_build(a, "1.0.0",
        compile_env_rule: 1,
        deps_lock: lock,
        finished_at: "2026-10-25T10:00:00Z"
      )

    assert listed?(a)
    assert {:dry_run, [%{package: ^a}]} = RelocationRevocation.revoke(package: a)
    assert {:revoked, 1, _, _} = RelocationRevocation.revoke(package: a, dry_run: false)
    refute listed?(a)
  end
end
