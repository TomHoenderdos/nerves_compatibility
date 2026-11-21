defmodule Portal.Precompiled.RelocatedTest do
  use Portal.DataCase, async: true

  alias Portal.Catalog.{RelocationMark, ToolchainBuild}
  alias Portal.Catalog.ToolchainBuild.EarlierBuilds
  alias Portal.Precompiled.Relocated

  @record %{
    "deps" => "/work/proj/deps",
    "build" => "/work/proj/_build/host",
    "files" => [
      %{
        "path" => "ebin/Elixir.Fine.beam",
        "occurrences" => [
          %{
            "chunk" => "LitT",
            "index" => 0,
            "term" => [],
            "kind" => "binary",
            "parts" => ["", "deps", "/fine/c_include"]
          }
        ]
      }
    ]
  }

  test "counted/1: the record while its mark is the row's run, else nil" do
    assert Relocated.counted(%{relocation: @record, run_id: "r1", relocation_run_id: "r1"}) ==
             @record

    assert Relocated.counted(%{relocation: @record, run_id: "r2", relocation_run_id: "r1"}) == nil
    assert Relocated.counted(%{relocation: @record, run_id: nil, relocation_run_id: nil}) == nil
    assert Relocated.counted(%{relocation: nil, run_id: "r1", relocation_run_id: "r1"}) == nil
    assert Relocated.counted(%{run_id: "r1"}) == nil
  end

  test "the mark names the write's run only when it sets a record" do
    mark = fn attrs ->
      ToolchainBuild
      |> Ash.Changeset.new()
      |> Ash.Changeset.force_change_attributes(attrs)
      |> RelocationMark.change([], %{})
      |> Ash.Changeset.get_attribute(:relocation_run_id)
    end

    assert mark.(%{relocation: @record, run_id: "r1"}) == "r1"
    assert mark.(%{relocation: nil, run_id: "r1"}) == nil
  end

  test "an earlier build's snapshot keeps the relocation and its mark" do
    row =
      struct(ToolchainBuild, %{
        status: :pass,
        revoked_at: nil,
        deps_lock: %{},
        file_manifest: %{"ebin" => [], "priv" => []},
        run_id: "r1",
        relocation: @record,
        relocation_run_id: "r1",
        finished_at: ~U[2026-11-21 10:00:00.000000Z]
      })

    entry = EarlierBuilds.entry(row)
    assert entry["relocation"] == @record
    assert entry["relocation_run_id"] == "r1"
  end

  test "relocated builds are served only once the setting is saved on" do
    refute Portal.Settings.get().relocated_enabled
    refute Relocated.enabled?()
    {:ok, _} = Portal.Settings.save(%{relocated_enabled: true})
    assert Relocated.enabled?()
  end
end
