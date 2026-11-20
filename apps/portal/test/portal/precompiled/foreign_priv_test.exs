defmodule Portal.Precompiled.ForeignPrivTest do
  use Portal.DataCase, async: true

  alias Portal.Catalog.{ForeignPrivMark, ToolchainBuild}
  alias Portal.Catalog.ToolchainBuild.EarlierBuilds
  alias Portal.Precompiled.ForeignPriv

  @entry %{
    "app" => "kino",
    "path" => "priv/assets/Kino_VegaLite/uxwh53kfq2wszgf23hqwgkuiza.tar.gz",
    "sha256" => String.duplicate("a", 64),
    "size" => 3,
    "mode" => 33_188,
    "module" => "Elixir.Kino.VegaLite",
    "assets_path" => "lib/assets/vega_lite/build"
  }

  test "counted/1: the list while its mark is the row's run, else nothing" do
    assert ForeignPriv.counted(%{foreign_priv: [@entry], run_id: "r1", foreign_priv_run_id: "r1"}) ==
             [@entry]

    assert ForeignPriv.counted(%{foreign_priv: [@entry], run_id: "r2", foreign_priv_run_id: "r1"}) ==
             []

    assert ForeignPriv.counted(%{foreign_priv: [@entry], run_id: nil, foreign_priv_run_id: nil}) ==
             []

    assert ForeignPriv.counted(%{foreign_priv: [], run_id: "r1", foreign_priv_run_id: "r1"}) == []
    assert ForeignPriv.counted(%{run_id: "r1"}) == []
    assert ForeignPriv.target?("kino")
    refute ForeignPriv.target?("kino_vega_lite")
  end

  test "the mark names the write's run only when it sets a list" do
    mark = fn attrs ->
      ToolchainBuild
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(attrs)
      |> ForeignPrivMark.change([], %{})
      |> Ash.Changeset.get_attribute(:foreign_priv_run_id)
    end

    assert mark.(%{foreign_priv: [@entry], run_id: "r1"}) == "r1"
    assert mark.(%{foreign_priv: [], run_id: "r1"}) == nil
    assert mark.(%{foreign_priv: nil, run_id: "r1"}) == nil
  end

  test "an earlier build's snapshot keeps the foreign fields, and its shas count only while marked" do
    row =
      struct(ToolchainBuild, %{
        status: :pass,
        revoked_at: nil,
        deps_lock: %{"kino" => %{"version" => "0.19.1", "checksum" => "c"}},
        file_manifest: %{"ebin" => [], "priv" => []},
        run_id: "r1",
        foreign_priv: [@entry],
        foreign_priv_rule: "kino_js_v1",
        foreign_priv_run_id: "r1",
        finished_at: ~U[2026-11-20 10:00:00.000000Z]
      })

    entry = EarlierBuilds.entry(row)
    assert entry["foreign_priv"] == [@entry]
    assert entry["foreign_priv_rule"] == "kino_js_v1"
    assert entry["foreign_priv_run_id"] == "r1"
    assert @entry["sha256"] in EarlierBuilds.shas([entry])
    refute @entry["sha256"] in EarlierBuilds.shas([%{entry | "foreign_priv_run_id" => "old"}])
  end
end
