defmodule Portal.Precompiled.RelocationRevocationTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Precompiled.RelocationRevocation

  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 3]

  defp record(name) do
    %{
      "deps" => "/work/proj/deps",
      "build" => "/work/proj/_build/host",
      "files" => [
        %{
          "path" => "ebin/#{name}.beam",
          "occurrences" => [
            %{
              "chunk" => "LitT",
              "index" => 0,
              "term" => [],
              "kind" => "binary",
              "parts" => ["", "deps", "/#{name}/c_include"]
            }
          ]
        }
      ]
    }
  end

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
end
