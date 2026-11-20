defmodule Portal.Precompiled.ForeignPrivRevocationTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Precompiled.ForeignPrivRevocation, as: R
  alias Portal.Test.ForeignPrivFixtures, as: F

  setup do
    {:ok, _} = Portal.Settings.save(%{foreign_priv_enabled: true})
    {:ok, writer} = F.ingest!()
    %{writer: writer, sha: hd(writer.foreign_priv)["sha256"]}
  end

  test "a dry run counts and writes nothing", %{sha: sha} do
    assert {:dry_run,
            [
              %{
                package: "kino_vega_lite",
                version: "0.1.13",
                rule: "kino_js_v1",
                table: "catalog_toolchain_builds",
                config_variant: "default"
              }
            ]} = R.revoke(rule: "kino_js_v1")

    assert Catalog.published_sha256?(sha)
  end

  test "acting needs a filter; it revokes, unserves and is undone by its timestamp", %{sha: sha} do
    assert {:error, :filter_required} = R.revoke(dry_run: false)
    js_sha = Compatibility.ForeignPriv.rule("kino_js_v1").js_sha256
    assert {:revoked, 1, [_], at} = R.revoke(js_sha256: js_sha, dry_run: false)
    refute Catalog.published_sha256?(sha)

    refute get_in(Catalog.precompiled_manifest_v2("kino_vega_lite") || %{}, [
             "versions",
             "0.1.13",
             "foreign_priv"
           ])

    assert R.undo(at) == 1
    assert Catalog.published_sha256?(sha)
  end

  test "package and version filters, and everything" do
    assert {:dry_run, []} = R.revoke(package: "kino_db")
    assert {:dry_run, [_]} = R.revoke(package: "kino_vega_lite", version: "0.1.13")
    assert {:dry_run, [_]} = R.revoke(everything: true)
  end

  test "a foreign build's sibling is revoked with it, and a stale mark is no candidate" do
    {sibling, beams} = F.sibling()
    result = Map.put(F.writer_result(), "deterministic_build", sibling)
    {:ok, row} = Catalog.Ingestion.ingest_toolchain(result, F.ingest_opts(F.files_dir!(beams)))
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})

    assert {:dry_run, rows} = R.revoke(package: "kino_vega_lite")
    tables = rows |> Enum.map(& &1.table) |> Enum.sort()
    assert tables == ["catalog_deterministic_builds", "catalog_toolchain_builds"]

    [%{"sha256" => sibling_sha} | _] = F.entries("otp29")
    assert Catalog.published_sha256?(sibling_sha)
    assert {:revoked, 2, _, at} = R.revoke(package: "kino_vega_lite", dry_run: false)
    refute Catalog.published_sha256?(sibling_sha)
    assert R.undo(at) == 2

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run' WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    assert {:dry_run, [%{table: "catalog_deterministic_builds"}]} = R.revoke(everything: true)
  end
end
