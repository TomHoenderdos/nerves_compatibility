defmodule Portal.Catalog.FirmwareWorldTest do
  # A firmware target's world build (`NccWorker.WorldTargets`,
  # `published_variants` "world_nerves"): kept at ingest only from a run that
  # echoes the world its job asked for and whose closure differs from both
  # other builds', and served only in builds_closure.
  use Portal.DataCase, async: false

  require Ash.Query

  import PortalWeb.ApiSpecAssertions

  alias Portal.{ArtifactStore, Catalog}
  alias Portal.Catalog.{Ingestion, SystemResult}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  @run_lock %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
  @with_lock Map.put(@run_lock, "tzdata", %{"version" => "1.1.0", "checksum" => "tz"})
  @world_lock Map.put(@run_lock, "muontrap", %{"version" => "2.0.1", "checksum" => "mt"})

  @with_bytes "precompiled-beam"
  @without_bytes "precompiled-beam-without"
  @world_bytes "precompiled-beam-world"

  defp sha256(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp manifest(bytes),
    do: %{
      "ebin" => [%{"path" => "ebin/jason.beam", "sha256" => sha256(bytes), "mode" => 33_188}],
      "priv" => []
    }

  defp variant(name, bytes, lock) do
    %{
      "variant" => name,
      "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(bytes)}},
      "compile_env" => [],
      "deps_lock" => lock
    }
  end

  defp without, do: variant("without", @without_bytes, @run_lock)
  defp world(lock \\ @world_lock), do: variant("world_nerves", @world_bytes, lock)

  # rpi4 passes. `own_lock` nil is a target with no `with` pass (the
  # jason class): its own build is the first build, under the run lock.
  defp run(variants, opts \\ []) do
    own_lock = Keyword.get(opts, :own_lock, @with_lock)

    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", @run_lock)
    |> Map.put("package_checksum", "outer")
    |> Map.put("firmware_world", Keyword.get(opts, :echo, "world:nerves"))
    |> update_in(["systems", "nerves_system_rpi4"], fn rpi4 ->
      rpi4
      |> Map.put("compile_env", [])
      |> then(&if own_lock, do: Map.put(&1, "deps_lock", own_lock), else: &1)
      |> Map.put("published_variants", variants)
    end)
  end

  defp ingest!(result, job_world \\ "nerves") do
    dir = Path.join(System.tmp_dir!(), "fw-world-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    for bytes <- [@with_bytes, @without_bytes, @world_bytes] do
      _ = File.rm(ArtifactStore.blob_path(sha256(bytes)))
      File.write!(Path.join(dir, sha256(bytes)), bytes)
    end

    opts = %{
      package: "jason",
      version: "1.4.1",
      run_id: result["run_id"],
      image_digest: "sha256:precompiled",
      files_dir: dir,
      scan_request_id: nil,
      log: "log"
    }

    opts = if job_world, do: Map.put(opts, :firmware_world, job_world), else: opts
    {:ok, run} = Ingestion.ingest(result, opts)
    run
  end

  defp rpi4_row do
    [row] =
      SystemResult
      |> Ash.Query.filter(system_pkg == "nerves_system_rpi4")
      |> Ash.read!(domain: Catalog)

    row
  end

  defp kinds(row), do: Enum.map(row.published_variants || [], & &1["variant"])

  defp rpi4_builds(list) do
    %{"versions" => %{"1.4.1" => version}} = Catalog.precompiled_manifest_v2("jason")
    version |> Map.get(list, []) |> Enum.filter(&(&1["target"] == "nerves_system_rpi4"))
  end

  describe "ingest" do
    test "a world build with its own closure is kept beside the build without" do
      ingest!(run([without(), world()]))

      assert kinds(rpi4_row()) == ["without", "world_nerves"]
      [_, stored] = rpi4_row().published_variants
      assert stored["deps_lock"] == @world_lock
      assert stored["file_manifest"] == manifest(@world_bytes)
    end

    test "dropped when the run does not echo the world" do
      result = run([without(), world()]) |> Map.delete("firmware_world")
      ingest!(result)
      assert kinds(rpi4_row()) == ["without"]
    end

    test "dropped when the echo names another world" do
      ingest!(run([without(), world()], echo: "world:other"))
      assert kinds(rpi4_row()) == ["without"]
    end

    test "dropped when the job did not ask for the world" do
      ingest!(run([without(), world()]), nil)
      assert kinds(rpi4_row()) == ["without"]
    end

    test "dropped when its closure is the build with's" do
      ingest!(run([without(), world(@with_lock)]))
      assert kinds(rpi4_row()) == ["without"]
    end

    test "dropped when its closure is the build without's (the run lock)" do
      ingest!(run([world(@run_lock)], own_lock: nil))
      assert rpi4_row().published_variants == nil
    end

    test "dropped when its closure is the without variant's" do
      odd = Map.put(@run_lock, "x", %{"version" => "1", "checksum" => "x"})
      ingest!(run([variant("without", @without_bytes, odd), world(odd)]))
      assert kinds(rpi4_row()) == ["without"]
    end

    test "a malformed world build is dropped whole" do
      ingest!(run([without(), world(%{"muontrap" => %{"version" => 2}})]))
      assert kinds(rpi4_row()) == ["without"]

      ingest!(
        run([without(), Map.put(world(), "compile_env", "nope")])
        |> Map.put("run_id", "fixture-jason-2")
      )

      assert Enum.all?(
               SystemResult
               |> Ash.Query.filter(system_pkg == "nerves_system_rpi4")
               |> Ash.read!(domain: Catalog),
               &(kinds(&1) == ["without"])
             )
    end
  end

  describe "manifest_v2" do
    test "three builds of one target: with in builds, without and world in builds_closure" do
      ingest!(run([without(), world()]))

      assert [%{"build" => %{"deps" => @with_lock}}] = rpi4_builds("builds")
      closure = rpi4_builds("builds_closure")

      assert Enum.map(closure, & &1["build"]["deps"]) |> Enum.sort() ==
               Enum.sort([@run_lock, @world_lock])

      refute Enum.any?(closure, &Map.has_key?(&1["build"], "variant"))

      assert_api_schema(Catalog.precompiled_manifest_v2("jason"), "ManifestV2")

      v1 = Catalog.precompiled_manifest("jason")
      assert v1.versions["1.4.1"]["nerves_system_rpi4"]["build"]["deps"] == @with_lock
      refute Jason.encode!(v1) =~ sha256(@world_bytes)
    end

    # The jason class: no with pass, so no own lock and no without variant.
    # The world build alone must not take the target's own build away.
    test "a target with only a world build keeps its own build in builds" do
      ingest!(run([world()], own_lock: nil))

      assert rpi4_row().deps_lock == nil
      assert kinds(rpi4_row()) == ["world_nerves"]
      assert [%{"build" => %{"deps" => @run_lock}}] = rpi4_builds("builds")
      assert [%{"build" => %{"deps" => @world_lock}}] = rpi4_builds("builds_closure")

      v1 = Catalog.precompiled_manifest("jason")
      assert v1.versions["1.4.1"]["nerves_system_rpi4"]["build"]["deps"] == @run_lock
      refute Jason.encode!(v1) =~ sha256(@world_bytes)
    end
  end
end
