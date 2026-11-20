defmodule Portal.Catalog.IngestionForeignPrivTest do
  # Foreign priv spec 4.2: the container's word is checked on the host. The
  # entries' shape first, then kino's tarball (signed, in the lock, a reviewed
  # js.ex), the writer's tarball, and each blob's content proof
  # (`Compatibility.KinoAssets`). A refusal stores `fail` with no files; Hex
  # down retries.
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog
  require Ash.Query

  alias Portal.Catalog.{ArtifactMembership, ToolchainBuild}
  alias Portal.Precompiled.ForeignPriv
  alias Portal.Test.ForeignPrivFixtures, as: F

  defp memberships(row) do
    ArtifactMembership
    |> Ash.Query.filter(toolchain_build_id == ^row.id)
    |> Ash.read!(domain: Portal.Catalog)
    |> Enum.map(& &1.sha256)
  end

  defp assert_refused(outcome, why) do
    assert {:ok, row} = outcome
    assert row.status == :fail
    assert "foreign priv refused on the host: " <> rest = row.reason
    assert rest =~ why, rest
    assert row.foreign_priv == nil and row.foreign_priv_rule == nil
    assert memberships(row) == []
  end

  test "a good result passes with its foreign entries, marked, and its archive blobs owned" do
    assert {:ok, row} = F.ingest!()
    assert row.status == :pass
    assert row.foreign_priv_rule == "kino_js_v1"
    assert row.foreign_priv_run_id == row.run_id
    assert Enum.sort_by(row.foreign_priv, & &1["path"]) == Enum.sort_by(F.entries(), & &1["path"])
    assert ForeignPriv.counted(row) == row.foreign_priv
    for %{"sha256" => sha} <- F.entries(), do: assert(sha in memberships(row))
  end

  test "each malformed shape is a fail with no files, logged as a security event" do
    [vl, chart] = F.entries()
    h = String.duplicate("a", 26)

    cases = [
      {%{"foreign_priv" => [%{vl | "app" => "kino_db"}, chart]},
       "foreign priv entry for another app"},
      {%{"foreign_priv" => [%{vl | "path" => "priv/assets/Kino_VegaLite/x.tar.gz"}, chart]},
       "malformed foreign priv path"},
      {%{"foreign_priv" => [%{vl | "mode" => 33_261}, chart]}, "malformed foreign priv entry"},
      {%{"foreign_priv" => [vl, %{vl | "sha256" => String.duplicate("b", 64)}]},
       "two entries for priv/assets/Kino_VegaLite"},
      {%{"foreign_priv" => [%{vl | "module" => "Elixir.Kino.Other"}, chart]},
       "is not the directory of Elixir.Kino.Other"},
      {%{
         "foreign_priv" => [
           %{vl | "path" => "priv/assets/Kino_Gone/#{h}.tar.gz", "module" => "Elixir.Kino.Gone"},
           chart
         ]
       }, "Elixir.Kino.Gone has no beam in the build"},
      {%{"foreign_priv_rule" => "kino_js_v9"}, "unknown foreign priv rule"},
      {%{"foreign_priv" => [], "foreign_priv_rule" => "kino_js_v1"},
       "a foreign priv rule without entries"},
      {%{"foreign_priv" => List.duplicate(vl, 65)}, "more than 64 foreign priv files"}
    ]

    for {over, why} <- cases do
      log = capture_log(fn -> assert_refused(F.ingest!(over), why) end)

      assert log =~
               "security: toolchain build kino_vega_lite 0.1.13 foreign priv refused at ingest",
             why
    end
  end

  test "kino must be in the lock, signed, and its js.ex reviewed" do
    assert_refused(F.ingest!(%{"deps_lock" => %{}}), "without kino in its lock")

    other_js = F.kino_tarball("defmodule Kino.JS do end\n")
    hex = Map.put(F.default_hex(), {"kino", "0.19.1"}, {:ok, other_js})
    lock = %{"kino" => %{"version" => "0.19.1", "checksum" => F.sha(other_js)}}

    assert_refused(
      F.ingest!(%{"deps_lock" => lock}, hex),
      "kino 0.19.1's js.ex is not reviewed for kino_js_v1"
    )

    stale = %{"kino" => %{"version" => "0.19.1", "checksum" => String.duplicate("0", 64)}}

    assert_refused(
      F.ingest!(%{"deps_lock" => stale}),
      "locked a package checksum that is not the Hex registry's"
    )
  end

  test "a blob that is not its sha, or whose archive is not the package's, refuses" do
    [vl, chart] = F.entries()

    assert_refused(
      F.ingest!(%{"foreign_priv" => [%{vl | "sha256" => F.sha("not stored")}, chart]}),
      "foreign priv file"
    )

    # The sibling OTP's archive of ChartCell under Kino_VegaLite's name and module.
    other = F.entries("otp28") |> Enum.at(1)

    swapped = %{
      other
      | "path" => String.replace(other["path"], "KinoVegaLite_ChartCell", "Kino_VegaLite"),
        "module" => "Elixir.Kino.VegaLite",
        "assets_path" => vl["assets_path"]
    }

    assert_refused(F.ingest!(%{"foreign_priv" => [swapped, chart]}), "Kino_VegaLite")
  end

  test "Hex down for kino retries and writes nothing" do
    hex = Map.put(F.default_hex(), {"kino", "0.19.1"}, {:error, :timeout})
    assert {:error, {:foreign_priv_unchecked, _}} = F.ingest!(%{}, hex)

    assert [] =
             ToolchainBuild
             |> Ash.Query.filter(version == "0.1.13")
             |> Ash.read!(domain: Portal.Catalog)
  end

  # B1's mark: a release that does not know the columns rewrites run_id on a
  # rebuild and leaves the list, which then counts for nothing.
  # Spec 3.8: a pinned toolchain build is in, through the same ingest.
  test "a pinned toolchain build stores its proved foreign entries, and a refusal clears them" do
    kino = %{
      "name" => "kino",
      "hex" => "kino",
      "version" => "0.19.1",
      "checksum" => F.sha(F.kino_tarball())
    }

    checksum = F.sha(F.writer_tarball())

    hash =
      Compatibility.Pins.hash(%{
        package: "kino_vega_lite",
        version: "0.1.13",
        package_checksum: checksum,
        deps: [kino]
      })

    pins = %{"hash" => hash, "package_checksum" => checksum, "deps" => [kino]}

    pinned = fn over ->
      result =
        over
        |> Map.put("deps_lock", Compatibility.Pins.to_lock([kino]))
        |> F.writer_result()
        |> Map.merge(%{
          "requested_optional_deps" => "pinned",
          "pins" => %{"hash" => hash, "status" => "reproduced"},
          "optional_deps" => %{
            "added" => [],
            "dropped" => [],
            "skipped" => [],
            "reason" => "pinned"
          }
        })

      opts =
        F.files_dir!()
        |> F.ingest_opts()
        |> Map.delete(:variant)
        |> Map.merge(%{
          pin_hash: hash,
          pins: pins,
          target: "pure_elixir",
          builder_version: Portal.Toolchains.builder_version()
        })

      Portal.Catalog.Ingestion.ingest_pinned(result, opts)
    end

    assert {:ok, row} = pinned.(%{})
    assert row.status == :pass
    assert row.foreign_priv_rule == "kino_js_v1"
    assert row.foreign_priv_run_id == row.run_id
    assert ForeignPriv.counted(row) == row.foreign_priv
    assert length(row.foreign_priv) == 2

    [vl, chart] = F.entries()

    capture_log(fn ->
      assert {:ok, refused} = pinned.(%{"foreign_priv" => [%{vl | "mode" => 33_261}, chart]})
      assert refused.status == :fail
      assert refused.foreign_priv == nil
      assert refused.foreign_priv_run_id == nil
    end)
  end

  test "the stale foreign_priv_run_id mark is ignored" do
    assert {:ok, row} = F.ingest!()

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run' WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    row = Ash.get!(ToolchainBuild, row.id, domain: Portal.Catalog)
    assert row.foreign_priv != nil
    assert ForeignPriv.counted(row) == []
  end
end
