defmodule Portal.Catalog.FirmwareVariantsTest do
  # A firmware target that kept its optional dependencies also publishes its
  # first build, the one without them (`NccWorker.OptionalDepsTargets`,
  # `published_variants`): stored on the target's own row, never as a row of
  # its own, and listed in format 2 beside the build with them.
  use Portal.DataCase, async: false

  require Ash.Query

  import PortalWeb.ApiSpecAssertions

  alias Portal.{ArtifactStore, Catalog, Repo}
  alias Portal.Catalog.{Ingestion, SystemResult}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  @run_lock %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @with_lock Map.put(@run_lock, "tzdata", %{"version" => "1.1.0", "checksum" => "tz"})

  # A small integer, as base64url ETF (`Compatibility.RecordedValue`).
  @value Base.url_encode64(:erlang.term_to_binary(1), padding: false)
  @compile_env [%{"app" => "jason", "path" => ["a"], "value" => @value}]

  @with_bytes "precompiled-beam"
  @without_bytes "precompiled-beam-without"

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp manifest(bytes),
    do: %{
      "ebin" => [%{"path" => "ebin/jason.beam", "sha256" => sha256(bytes), "mode" => 33_188}],
      "priv" => []
    }

  defp variant(overrides \\ %{}) do
    Map.merge(
      %{
        "variant" => "without",
        "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(@without_bytes)}},
        "compile_env" => @compile_env,
        "deps_lock" => @run_lock
      },
      overrides
    )
  end

  # The fixture run as a kept target leaves it: rpi4's own keys describe the
  # build with the optional dependency, and it publishes the first build
  # beside it.
  defp kept_run(variants) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", @run_lock)
    |> Map.put("package_checksum", "outer")
    |> update_in(["systems", "nerves_system_rpi4"], fn rpi4 ->
      rpi4
      |> Map.put("compile_env", [])
      |> Map.put("deps_lock", @with_lock)
      |> put_variants(variants)
    end)
  end

  defp put_variants(system, nil), do: system
  defp put_variants(system, variants), do: Map.put(system, "published_variants", variants)

  # Both blobs in the run's files dir, unless `blobs` names fewer.
  defp ingest!(result, blobs \\ [@with_bytes, @without_bytes]) do
    dir = Path.join(System.tmp_dir!(), "fw-variants-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for bytes <- [@with_bytes, @without_bytes] do
      _ = File.rm(ArtifactStore.blob_path(sha256(bytes)))
    end

    for bytes <- blobs, do: File.write!(Path.join(dir, sha256(bytes)), bytes)

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: "jason",
        version: "1.4.1",
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "log"
      })

    run
  end

  # The rpi4 builds of one list of version 1.4.1 ("builds" by default).
  defp rpi4_builds(list \\ "builds") do
    %{"versions" => %{"1.4.1" => version}} = Catalog.precompiled_manifest_v2("jason")
    version |> Map.get(list, []) |> Enum.filter(&(&1["target"] == "nerves_system_rpi4"))
  end

  # Every list but builds_closure, the way a device reads a version
  # (`Precompiled.Device.Rules`: builds ++ builds_with_inputs) and every
  # client before 0.7.0 reads it.
  defp device_visible do
    %{"versions" => versions} = Catalog.precompiled_manifest_v2("jason")

    Enum.flat_map(versions, fn {_version, v} ->
      v["builds"] ++ Map.get(v, "builds_with_inputs", [])
    end)
  end

  defp shas(builds), do: for(b <- builds, e <- b["ebin"] ++ b["priv"], do: e["sha256"])

  defp rows(system_pkg) do
    SystemResult
    |> Ash.Query.filter(system_pkg == ^system_pkg)
    |> Ash.read!(domain: Catalog)
  end

  describe "ingest" do
    test "the first build is stored on the target's own row, not as a row of its own" do
      ingest!(kept_run([variant()]))

      assert [row] = rows("nerves_system_rpi4")
      assert row.deps_lock == @with_lock

      assert row.published_variants == [
               %{
                 "variant" => "without",
                 "file_manifest" => manifest(@without_bytes),
                 "compile_env" => @compile_env,
                 "deps_lock" => @run_lock
               }
             ]

      # Both builds' blobs are the target's, deduped by sha256.
      %{rows: shas} =
        Repo.query!(
          "SELECT sha256 FROM catalog_artifact_memberships WHERE system_result_id = $1 ORDER BY 1",
          [Ecto.UUID.dump!(row.id)]
        )

      assert List.flatten(shas) == Enum.sort([sha256(@with_bytes), sha256(@without_bytes)])
      assert ArtifactStore.present?(sha256(@without_bytes))
    end

    test "stats count the target once" do
      Catalog.Cache.flush()
      ingest!(kept_run(nil))
      Catalog.Cache.flush()
      before = Catalog.stats_json()

      ingest!(kept_run([variant()]) |> Map.put("run_id", "fixture-jason-again"))
      Catalog.Cache.flush()
      after_variant = Catalog.stats_json()

      # One more run, so one more result per system: the variant adds none.
      assert after_variant.counts["total"] == before.counts["total"] + 3

      assert after_variant.by_system["nerves_system_rpi4@1.24.0"]["pass"] ==
               before.by_system["nerves_system_rpi4@1.24.0"]["pass"] + 1
    end

    test "a variant without a well-formed lock or compile_env, or of an unknown kind, is dropped" do
      ingest!(
        kept_run([
          variant(%{"deps_lock" => %{"decimal" => %{"version" => 1}}}),
          variant(%{"compile_env" => "nope"}),
          variant(%{"variant" => "sideways"})
        ])
      )

      assert [%{published_variants: nil}] = rows("nerves_system_rpi4")
    end

    test "a variant on a target that did not pass is dropped" do
      kept_run(nil)
      |> put_in(["systems", "nerves_system_x86_64", "published_variants"], [variant()])
      |> ingest!()

      assert [%{published_variants: nil}] = rows("nerves_system_x86_64")
    end

    test "a carried target keeps its variant" do
      ingest!(kept_run([variant()]))

      kept_run(nil)
      |> Map.merge(%{
        "run_id" => "fixture-jason-targets",
        "scope" => "targets",
        "finished_at" => "2030-01-01T00:00:00Z"
      })
      |> Map.update!("systems", &Map.take(&1, ["nerves_system_x86_64"]))
      |> ingest!()

      assert [_original, _carried] = rows = rows("nerves_system_rpi4")
      assert Enum.all?(rows, &match?([%{"variant" => "without"}], &1.published_variants))
    end
  end

  describe "manifest_v2" do
    test "lists the build with the optional dependency and the one without, each its own" do
      ingest!(kept_run([variant()]))

      assert [with_build] = rpi4_builds()
      assert [without_build] = rpi4_builds("builds_closure")

      assert with_build["ebin"] == [
               %{"path" => "ebin/jason.beam", "sha256" => sha256(@with_bytes), "mode" => 33_188}
             ]

      assert with_build["build"]["deps"] == @with_lock
      assert with_build["build"]["compile_env"] == []

      assert without_build["ebin"] == [
               %{
                 "path" => "ebin/jason.beam",
                 "sha256" => sha256(@without_bytes),
                 "mode" => 33_188
               }
             ]

      assert without_build["build"]["deps"] == @run_lock

      assert without_build["build"]["compile_env"] == @compile_env

      # Everything else is the target's, and the variant's name is not in it.
      assert Map.drop(without_build["build"], ["deps", "compile_env"]) ==
               Map.drop(with_build["build"], ["deps", "compile_env"])

      refute Map.has_key?(without_build["build"], "variant")

      assert_api_schema(Catalog.precompiled_manifest_v2("jason"), "ManifestV2")
    end

    test "an old-shape result renders one build per target, as before" do
      ingest!(kept_run(nil))

      assert [%{"build" => %{"deps" => @with_lock}}] = rpi4_builds()
      assert [%{published_variants: nil}] = rows("nerves_system_rpi4")

      refute Map.has_key?(
               Catalog.precompiled_manifest_v2("jason")["versions"]["1.4.1"],
               "builds_closure"
             )
    end

    # A target's compile_inputs were recorded against its own build
    # (`NccWorker.FirmwareInputs`); the build without is another compile.
    test "a variant never carries the target's own compile_inputs" do
      inputs = [%{"kind" => "mix_target", "value" => "rpi4"}]

      [variant()]
      |> kept_run()
      |> put_in(["systems", "nerves_system_rpi4", "compile_inputs"], inputs)
      |> ingest!()

      assert [%{"build" => %{"compile_inputs" => ^inputs}}] = rpi4_builds("builds_with_inputs")
      assert [without] = rpi4_builds("builds_closure")
      refute Map.has_key?(without["build"], "compile_inputs")
    end

    # A device ranks an installed build first and only ranks by rule 8, so
    # a device that has the optional dependency could take the build
    # without it. Only clients that check the whole env closure read
    # builds_closure.
    test "the build without is only in builds_closure, which no device reads" do
      ingest!(kept_run([variant()]))

      assert [%{"build" => %{"deps" => @run_lock}}] = rpi4_builds("builds_closure")
      assert rpi4_builds("builds_with_inputs") == []
      refute sha256(@without_bytes) in shas(device_visible())
      assert sha256(@with_bytes) in shas(device_visible())
    end

    # Its own lock was dropped at ingest: falling back to the run's would
    # publish the build with the optional dependency under the lock of the
    # build without it.
    test "a kept target whose own lock is unusable publishes only the build without" do
      kept_run([variant()])
      |> put_in(["systems", "nerves_system_rpi4", "deps_lock"], %{"x" => %{"version" => 1}})
      |> ingest!()

      assert [%{deps_lock: nil}] = rows("nerves_system_rpi4")
      assert rpi4_builds() == []
      refute sha256(@with_bytes) in shas(device_visible())
      assert [%{"build" => %{"deps" => @run_lock}}] = rpi4_builds("builds_closure")

      v1 = Catalog.precompiled_manifest("jason")
      refute get_in(v1 || %{}, [:versions, "1.4.1", "nerves_system_rpi4"])
    end

    test "format 1 publishes only the build with the optional dependency" do
      ingest!(kept_run([variant()]))

      v1 = Catalog.precompiled_manifest("jason")

      assert %{"ebin" => [%{"sha256" => sha}], "build" => %{"deps" => @with_lock}} =
               v1.versions["1.4.1"]["nerves_system_rpi4"]

      assert sha == sha256(@with_bytes)
      refute Jason.encode!(v1) =~ sha256(@without_bytes)
    end

    test "a variant whose blob the run did not deliver is left out; the target's own build stays" do
      ingest!(kept_run([variant()]), [@with_bytes])

      assert [%{"build" => %{"deps" => @with_lock}}] = rpi4_builds()
      assert rpi4_builds("builds_closure") == []
    end

    test "a variant missing a file it lists is left out whole" do
      two_files = %{
        manifest(@without_bytes)
        | "ebin" =>
            manifest(@without_bytes)["ebin"] ++
              [%{"path" => "ebin/extra.beam", "sha256" => sha256("never sent"), "mode" => 33_188}]
      }

      [variant(%{"beam_scan" => %{"footprint" => %{"file_manifest" => two_files}}})]
      |> kept_run()
      |> ingest!()

      assert [%{"build" => %{"deps" => @with_lock}}] = rpi4_builds()
    end

    test "a variant with other priv files than the target's leaves out the target's ABI facts" do
      with_priv = %{
        manifest(@without_bytes)
        | "priv" => [%{"path" => "priv/x.so", "sha256" => sha256(@with_bytes), "mode" => 33_261}]
      }

      [variant(%{"beam_scan" => %{"footprint" => %{"file_manifest" => with_priv}}})]
      |> kept_run()
      |> ingest!()

      Repo.query!(
        "UPDATE catalog_system_results SET native = false, portable = true " <>
          "WHERE system_pkg = 'nerves_system_rpi4'"
      )

      assert [with_build] = rpi4_builds()
      assert [without_build] = rpi4_builds("builds_closure")

      assert with_build["build"]["native"] == false
      refute Map.has_key?(without_build["build"], "native")
      refute Map.has_key?(without_build["build"], "portable")
    end
  end
end
