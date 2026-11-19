defmodule Portal.FirmwareDeterministicTest do
  # A firmware target's deterministic sibling (`NccWorker.FirmwareDeterministic`):
  # ingested with its system result, or with its pinned firmware build, after
  # the host's own checks (`Portal.Deterministic.Ingest.firmware_candidate/3`),
  # and published under a version's `deterministic` key only, beside its
  # build and only while that build is served.
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  require Ash.Query

  import Portal.PinnedFixtures, only: [pins: 1, firmware_result: 3, firmware_opts: 3]

  alias Portal.{ArtifactStore, Catalog, Repo}
  alias Portal.Catalog.{ArtifactMembership, DeterministicBuild, Ingestion, SystemResult}
  alias Portal.Precompiled.{DeterministicRevocation, FirmwareRefusal, Withheld}

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)
  @lock %{"decimal" => %{"version" => "2.3.0", "checksum" => @b}}
  @nif <<0x7F, "ELF", " a target nif">>
  @r2_pass %{"status" => "pass", "reason" => nil, "observations" => []}

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp on!, do: {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})

  defp unique,
    do:
      "fdpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3))}"

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # An Erlang module holding `?FILE`, compiled without and with the option:
  # a real sibling pair.
  defp beams(module, body \\ "f() -> ?FILE.\n") do
    path = Path.join(tmp("fd-src"), "#{module}.erl")
    File.write!(path, "-module(#{module}).\n-export([f/0]).\n" <> body)
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  defp entry(path, bytes),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => 33_188}

  defp manifest(module, beam, nif \\ @nif),
    do: %{"ebin" => [entry("ebin/#{module}.beam", beam)], "priv" => [entry("priv/nif.so", nif)]}

  defp sibling(module, beam, nif \\ @nif) do
    %{
      "status" => "pass",
      "reason" => nil,
      "erl_compiler_options" => ["deterministic"],
      "judge_revision" => 29,
      "file_manifest" => manifest(module, beam, nif),
      "build_root" => @r2_pass
    }
  end

  # A firmware run whose rpi4 target passed with its sibling; x86_64 is a
  # second passing target without one.
  defp run_result(name, module, normal, sibling, opts \\ []) do
    rpi4 = %{
      "status" => "pass",
      "duration_sec" => 90.0,
      "firmware_size_bytes" => 1_000,
      "log_tail" => "built",
      "system_version" => "2.2.2",
      "compile_env" => [],
      "error" => nil,
      "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(module, normal)}},
      "build_root" => @r2_pass,
      "deterministic_build" => sibling
    }

    x86 = %{
      rpi4
      | "system_version" => "1.30.0",
        "deterministic_build" => nil
    }

    %{
      "run_id" => "fd-#{System.unique_integer([:positive])}",
      "scope" => Keyword.get(opts, :scope, "full"),
      "finished_at" => Keyword.get(opts, :finished_at, "2026-11-19T12:00:00Z"),
      "package" => %{"name" => name, "version" => "1.0.0"},
      "image" => %{"name" => "ncc-worker:local", "digest" => "sha256:fd"},
      "toolchain" => %{"elixir" => "1.20.5", "erlang" => "29", "mix" => "1.20.5"},
      "deps_lock" => @lock,
      "package_checksum" => @a,
      "declared" => [],
      "systems" =>
        Keyword.get(opts, :systems, %{
          "host" => %{"status" => "pass", "duration_sec" => 5.0, "log_tail" => "ok"},
          "nerves_system_rpi4" => rpi4,
          "nerves_system_x86_64" => x86
        })
    }
  end

  defp files(blobs) do
    dir = tmp("fd-files")
    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  defp ingest!(name, result, blobs) do
    result = Map.put(result, "run_id", "fd-#{System.unique_integer([:positive])}")

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: name,
        version: "1.0.0",
        run_id: result["run_id"],
        image_digest: "sha256:fd",
        files_dir: files(blobs),
        scan_request_id: nil,
        log: "log"
      })

    run
  end

  # A run with a passing rpi4 sibling, ingested.
  defp ingested do
    name = unique()
    module = "fdm#{System.unique_integer([:positive])}"
    {normal, det} = beams(module)

    run =
      ingest!(name, run_result(name, module, normal, sibling(module, det)), [normal, det, @nif])

    %{name: name, module: module, normal: normal, det: det, run: run}
  end

  defp results(run_id, system_pkg) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run_id and system_pkg == ^system_pkg)
    |> Ash.read!(domain: Catalog)
  end

  defp sibling_of(%SystemResult{id: id}) do
    DeterministicBuild
    |> Ash.Query.filter(system_result_id == ^id)
    |> Ash.read_one!(domain: Catalog)
  end

  defp version(name) do
    case Catalog.precompiled_manifest_v2(name) do
      %{"versions" => %{"1.0.0" => version}} -> version
      other -> other
    end
  end

  defp ebin_sha(%{"ebin" => [%{"sha256" => sha}]}), do: sha

  describe "ingest" do
    test "a passing target's sibling is stored with its system result, with its own files" do
      %{run: run, det: det} = ingested()

      assert [rpi4] = results(run.id, "nerves_system_rpi4")

      assert %DeterministicBuild{status: :pass, erl_compiler_options: ["deterministic"]} =
               row = sibling_of(rpi4)

      assert row.run_id == rpi4.run_id
      assert row.package_id == run.package_id
      assert row.version == "1.0.0"
      assert row.toolchain_build_id == nil and row.pinned_build_id == nil
      assert ebin_sha(row.file_manifest) == sha(det)
      assert row.compile_observations == %{"build_root" => @r2_pass}

      shas =
        ArtifactMembership
        |> Ash.Query.filter(deterministic_build_id == ^row.id)
        |> Ash.read!(domain: Catalog)
        |> Enum.map(& &1.sha256)
        |> Enum.sort()

      assert shas == Enum.sort([sha(det), sha(@nif)])
      assert File.exists?(ArtifactStore.blob_path(sha(det)))

      # The other target carried none, and nothing about the build changed.
      assert [x86] = results(run.id, "nerves_system_x86_64")
      assert sibling_of(x86) == nil
      assert rpi4.status == :pass
    end

    # Review focus 1 and 3: a sibling of another closure, or of other bytes
    # than the option explains, is left out; the build is stored either way.
    test "a sibling that does not hold is left out and its target stored" do
      name = unique()
      module = "fdm#{System.unique_integer([:positive])}"
      {normal, det} = beams(module)
      # The same chunks, other code.
      {_, other} = beams(module, "f() -> {?FILE, self()}.\n")
      good = sibling(module, det)
      blobs = [normal, det, @nif]

      cases = [
        {"never compiled with the option", sibling(module, normal), blobs,
         "not compiled with the option"},
        {"other code", sibling(module, other), [other | blobs], "Code"},
        {"other priv", sibling(module, det, "another nif"), ["another nif" | blobs],
         "its priv differs"},
        {"another R2", Map.put(good, "build_root", %{"status" => "skipped"}), blobs,
         "its own R2 did not pass"},
        {"no R2", Map.delete(good, "build_root"), blobs, "its own R2 did not pass"},
        {"other options", Map.put(good, "erl_compiler_options", ["debug_info"]), blobs,
         "names other compiler options"},
        {"an older revision", Map.put(good, "judge_revision", 28), blobs,
         "names no compiler options or judge revision"},
        {"skipped", %{good | "status" => "skipped", "reason" => "timeout"}, blobs,
         "did not pass: timeout"},
        {"a blob missing", good, [normal, @nif], "its ebin blobs cannot be read back"}
      ]

      for {label, sibling, blobs, why} <- cases do
        log =
          capture_log(fn ->
            run = ingest!(name, run_result(name, module, normal, sibling), blobs)
            assert [rpi4] = results(run.id, "nerves_system_rpi4"), label
            assert rpi4.status == :pass, label
            assert sibling_of(rpi4) == nil, label
          end)

        assert log =~ "on nerves_system_rpi4 left out", label
        assert log =~ why, label
      end
    end

    test "a target built against its own lock, or beside its build without, gets none" do
      name = unique()
      module = "fdm#{System.unique_integer([:positive])}"
      {normal, det} = beams(module)
      base = run_result(name, module, normal, sibling(module, det))

      without = %{
        "variant" => "without",
        "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(module, normal)}},
        "compile_env" => [],
        "deps_lock" => @lock
      }

      for change <- [
            &put_in(&1, ["systems", "nerves_system_rpi4", "deps_lock"], Map.put(@lock, "x", %{})),
            &put_in(&1, ["systems", "nerves_system_rpi4", "published_variants"], [without])
          ] do
        log =
          capture_log(fn ->
            run = ingest!(name, change.(base), [normal, det, @nif])
            assert [rpi4] = results(run.id, "nerves_system_rpi4")
            assert sibling_of(rpi4) == nil
          end)

        assert log =~ "its build was made against another closure than the run's"
      end
    end

    test "only a Nerves system's sibling is read" do
      name = unique()
      module = "fdm#{System.unique_integer([:positive])}"
      {normal, det} = beams(module)
      base = run_result(name, module, normal, sibling(module, det))
      pure = Map.put(base["systems"]["nerves_system_rpi4"], "system_version", nil)

      result =
        Map.put(base, "systems", %{
          "host" => base["systems"]["host"],
          "pure_elixir" => pure
        })

      run = ingest!(name, result, [normal, det, @nif])
      assert [row] = results(run.id, "pure_elixir")
      assert sibling_of(row) == nil
    end
  end

  describe "publishing" do
    setup do
      ingested()
    end

    test "with the setting off no manifest lists the sibling and its files are not served",
         ctx do
      version = version(ctx.name)
      refute Map.has_key?(version, "deterministic")
      refute Catalog.published_sha256?(sha(ctx.det))
      assert Catalog.published_sha256?(sha(ctx.normal))
    end

    # Review focus 4 and 5: the sibling is its own build's entry, at that
    # build's target, release, lock and run, under `deterministic` alone.
    test "with it on the sibling is its target's entry under deterministic alone", ctx do
      off = Catalog.precompiled_manifest_v2(ctx.name)
      on!()
      manifest = Catalog.precompiled_manifest_v2(ctx.name)
      version = manifest["versions"]["1.0.0"]

      assert Map.delete(version, "deterministic") == off["versions"]["1.0.0"]
      assert %{"builds" => [sibling]} = version["deterministic"]
      assert sibling["target"] == "nerves_system_rpi4"
      assert sibling["build"]["erl_compiler_options"] == ["deterministic"]
      assert ebin_sha(sibling) == sha(ctx.det)

      [normal] = Enum.filter(version["builds"], &(&1["target"] == "nerves_system_rpi4"))
      assert [%{"path" => "priv/nif.so"}] = sibling["priv"]
      assert sibling["priv"] == normal["priv"]
      assert Map.delete(sibling["build"], "erl_compiler_options") == normal["build"]
      assert normal["build"]["system_version"] == "2.2.2"

      # No list but `deterministic` names the sibling's files or the option.
      for {key, list} <- version, key != "deterministic", entry <- list do
        refute Map.has_key?(entry["build"], "erl_compiler_options")
        refute ebin_sha(entry) == sha(ctx.det)
      end

      PortalWeb.ApiSpecAssertions.assert_api_schema(manifest, "ManifestV2")
      assert Catalog.published_sha256?(sha(ctx.det))
    end

    test "the sibling lever lists it as a firmware sibling and withdraws it alone", ctx do
      on!()

      assert {:dry_run, [row]} = DeterministicRevocation.revoke(package: ctx.name)
      assert row.toolchain == "nerves_system_rpi4"
      assert row.variant == "firmware"
      assert row.config_variant == "default"

      assert {:revoked, 1, _, at} =
               DeterministicRevocation.revoke(package: ctx.name, dry_run: false)

      refute Map.has_key?(version(ctx.name), "deterministic")
      refute Catalog.published_sha256?(sha(ctx.det))
      assert Catalog.published_sha256?(sha(ctx.normal))

      assert {:ok, 1} = DeterministicRevocation.undo(at)
      assert Map.has_key?(version(ctx.name), "deterministic")
    end
  end

  # Review focus 2: never beside a build that is not served.
  describe "every lever that withdraws a firmware result withdraws its sibling" do
    setup do
      on!()
      ingested()
    end

    defp withdrawn?(ctx) do
      version = version(ctx.name)

      not (is_map(version) and Map.has_key?(version, "deterministic")) and
        not Catalog.published_sha256?(sha(ctx.det))
    end

    defp rpi4(ctx), do: ctx.run.id |> results("nerves_system_rpi4") |> hd()

    test "a withdrawn result (`unpublished_at`)", ctx do
      refute withdrawn?(ctx)

      Repo.query!(
        "UPDATE catalog_system_results SET unpublished_at = now(), unpublished_reason = 'x' " <>
          "WHERE id = $1",
        [Ecto.UUID.dump!(rpi4(ctx).id)]
      )

      assert withdrawn?(ctx)
    end

    test "a newer run's refusal of the target (`FirmwareRefusal`)", ctx do
      refute withdrawn?(ctx)

      result =
        run_result(ctx.name, ctx.module, ctx.normal, nil, finished_at: "2026-11-20T12:00:00Z")

      refused =
        update_in(result, ["systems", "nerves_system_rpi4"], fn sys ->
          sys
          |> Map.put("build_root", %{"status" => "skipped", "reason" => "bakes the build path"})
          |> update_in(["beam_scan", "footprint"], &Map.delete(&1, "file_manifest"))
        end)

      ingest!(ctx.name, refused, [ctx.normal, @nif])
      assert FirmwareRefusal.withdraw_superseded() >= 0
      assert withdrawn?(ctx)
    end

    test "a revoked run", ctx do
      ctx.run |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
      assert withdrawn?(ctx)
    end

    test "a withheld package (`Withheld`)", ctx do
      old = Application.get_env(:portal, Withheld)
      Application.put_env(:portal, Withheld, packages: [ctx.name])

      try do
        assert withdrawn?(ctx)
      after
        if old,
          do: Application.put_env(:portal, Withheld, old),
          else: Application.delete_env(:portal, Withheld)
      end

      refute withdrawn?(ctx)
    end

    test "the setting turned off", ctx do
      {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: false})
      assert withdrawn?(ctx)
    end

    test "its own build no longer listed (a blob this host lacks)", ctx do
      File.rm!(ArtifactStore.blob_path(sha(ctx.normal)))
      refute Map.has_key?(version(ctx.name) || %{}, "deterministic")
    end
  end

  # Review focus 4: a carried copy of a row is a row of its own, with no
  # sibling; the sibling stays its own row's.
  test "a partial run's carried copy of the target carries no sibling" do
    on!()
    ctx = ingested()

    x86_only =
      ctx.name
      |> run_result(ctx.module, ctx.normal, nil,
        scope: "targets",
        finished_at: "2026-11-20T12:00:00Z"
      )
      |> update_in(["systems"], &Map.drop(&1, ["nerves_system_rpi4"]))

    second = ingest!(ctx.name, x86_only, [ctx.normal, @nif])

    assert [copy] = results(second.id, "nerves_system_rpi4")
    assert copy.carried_from_run_id == ctx.run.id
    assert sibling_of(copy) == nil

    assert %{"builds" => [sibling]} = version(ctx.name)["deterministic"]
    assert sibling["build"]["system_version"] == "2.2.2"
    assert ebin_sha(sibling) == sha(ctx.det)
  end

  describe "a pinned firmware build" do
    defp pinned_firmware(opts) do
      name = unique()
      pins = pins(name)
      module = "m0"
      {normal, det} = beams(module, "f() -> {?FILE, #{inspect(name)}}.\n")

      result =
        name
        |> firmware_result(pins,
          beams: [normal],
          system_version: Keyword.get(opts, :system_version, "2.1.2")
        )
        |> put_in(
          ["systems", "nerves_system_rpi4", "deterministic_build"],
          Map.put(sibling(module, det), "file_manifest", %{
            "ebin" => [entry("ebin/m0.beam", det)],
            "priv" => []
          })
        )

      job = firmware_opts(name, pins, files([normal, det]))
      {:ok, row} = Ingestion.ingest_pinned(result, job)
      %{name: name, row: row, normal: normal, det: det}
    end

    defp pinned_sibling(row) do
      DeterministicBuild
      |> Ash.Query.filter(pinned_build_id == ^row.id)
      |> Ash.read_one!(domain: Catalog)
    end

    test "its target's sibling is stored with it and listed under deterministic's builds_closure" do
      on!()
      %{name: name, row: row, det: det} = pinned_firmware([])

      assert row.status == :pass
      assert %DeterministicBuild{status: :pass} = sibling = pinned_sibling(row)
      assert sibling.run_id == row.run_id
      assert ebin_sha(sibling.file_manifest) == sha(det)

      version = version(name)
      assert %{"builds" => [], "builds_closure" => [listed]} = version["deterministic"]
      assert listed["target"] == "nerves_system_rpi4"
      assert listed["build"]["system_version"] == "2.1.2"
      assert listed["build"]["erl_compiler_options"] == ["deterministic"]
      assert ebin_sha(listed) == sha(det)
      assert Catalog.published_sha256?(sha(det))
    end

    # Review focus 4: never at a release its build was not made on.
    test "a target built on another release stores no sibling" do
      %{row: row} = pinned_firmware(system_version: "2.2.0")
      assert row.status == :skipped
      assert pinned_sibling(row) == nil
    end
  end
end
