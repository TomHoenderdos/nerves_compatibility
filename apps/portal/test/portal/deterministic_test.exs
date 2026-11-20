defmodule Portal.DeterministicTest do
  # Deterministic siblings: ingested beside their toolchain build after the
  # host's own checks (`Portal.Deterministic.Ingest`), and published under a
  # version's `deterministic` key, with their files, only while the
  # `deterministic_builds_enabled` setting is on and their build is served.
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog
  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, DeterministicBuild, Ingestion, ToolchainBuild}
  alias Portal.BatchHooks

  alias Portal.Precompiled.{
    Batches,
    DeterministicRevocation,
    Manifests,
    ToolchainRevocation,
    Withheld
  }

  alias Portal.Test.ForeignPrivFixtures

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp on!, do: {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})
  defp off!, do: {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: false})

  defp unique,
    do:
      "dtpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(3))}"

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # An Erlang module holding `?FILE`, compiled without and with the option:
  # a real sibling pair, whose `CInf`, `Dbgi`, `Line`, `LitT` and `Attr` differ.
  defp beams(name, body \\ "f() -> ?FILE.\n") do
    path = Path.join(tmp("dt-src"), "#{name}.erl")
    File.write!(path, "-module(#{name}).\n-export([f/0]).\n" <> body)
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  defp entry(path, bytes),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => 33_188}

  defp manifest(name, beam), do: %{"ebin" => [entry("ebin/#{name}.beam", beam)], "priv" => []}

  defp result(name, normal, sibling) do
    build = %{
      "status" => "pass",
      "reason" => nil,
      "elixir" => "1.20.5",
      "otp" => "28",
      "deps_lock" => %{},
      "package_checksum" => String.duplicate("a", 64),
      "declared" => [],
      "manager" => "rebar3",
      "compile_env" => [],
      "compile_env_rule" => 1,
      "compile_inputs" => [],
      "built_priv" => [],
      "portability_rule" => 2,
      "rule1_reason" => "calls a shell",
      "judge_revision" => 29,
      "file_manifest" => manifest(name, normal)
    }

    sibling_build =
      build
      |> Map.drop(["rule1_reason"])
      |> Map.merge(%{
        "erl_compiler_options" => ["deterministic"],
        "file_manifest" => manifest(name, sibling)
      })

    %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-17T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "toolchain_build" => build,
      "deterministic_build" => sibling_build
    }
  end

  defp files(blobs) do
    dir = tmp("dt-files")
    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  defp opts(name, files_dir) do
    %{
      package: name,
      version: "1.0.0",
      run_id: "dt-#{System.unique_integer([:positive])}",
      image_digest: "sha256:dt",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.20/28",
      builder_version: Portal.Toolchains.builder_version()
    }
  end

  # A passing build with its sibling, ingested: `%{name, tb, normal, sibling}`.
  defp ingested do
    name = unique()
    {normal, sibling} = beams(name)
    result = result(name, normal, sibling)
    {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files([normal, sibling])))
    %{name: name, tb: tb, normal: normal, sibling: sibling}
  end

  defp sibling_of(tb) do
    DeterministicBuild
    |> Ash.Query.filter(toolchain_build_id == ^tb.id)
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
    test "a sibling that holds is stored beside its build, with its own files" do
      %{tb: tb, sibling: sibling} = ingested()

      assert %DeterministicBuild{status: :pass, erl_compiler_options: ["deterministic"]} =
               row = sibling_of(tb)

      assert row.run_id == tb.run_id
      assert row.judge_revision == 29
      assert ebin_sha(row.file_manifest) == sha(sibling)

      shas =
        ArtifactMembership
        |> Ash.Query.filter(deterministic_build_id == ^row.id)
        |> Ash.read!(domain: Catalog)
        |> Enum.map(& &1.sha256)

      assert shas == [sha(sibling)]
      assert File.exists?(Portal.ArtifactStore.blob_path(sha(sibling)))
    end

    test "a sibling that does not hold is left out and its build is stored" do
      name = unique()
      {normal, sibling} = beams(name)
      {_, other_code} = beams(name, "f() -> other.\n")
      base = result(name, normal, sibling)

      cases = [
        {"never compiled with the option",
         put_in(base, ["deterministic_build", "file_manifest"], manifest(name, normal)),
         [normal]},
        {"other code",
         put_in(base, ["deterministic_build", "file_manifest"], manifest(name, other_code)),
         [normal, other_code]},
        {"other inputs",
         put_in(base, ["deterministic_build", "compile_inputs"], [%{"kind" => "env_all"}]),
         [normal, sibling]},
        {"other options",
         put_in(base, ["deterministic_build", "erl_compiler_options"], ["debug_info"]),
         [normal, sibling]},
        {"an older revision", put_in(base, ["deterministic_build", "judge_revision"], 28),
         [normal, sibling]},
        {"skipped", put_in(base, ["deterministic_build", "status"], "skipped"),
         [normal, sibling]},
        {"a blob missing", base, [normal]},
        {"other files",
         put_in(base, ["deterministic_build", "file_manifest", "priv"], [entry("priv/x", "x")]),
         [normal, sibling, "x"]}
      ]

      for {label, result, blobs} <- cases do
        assert {:ok, %ToolchainBuild{status: :pass} = tb} =
                 Ingestion.ingest_toolchain(result, opts(name, files(blobs))),
               label

        assert sibling_of(tb) == nil, label
      end
    end

    test "a rebuild replaces its build's sibling, and one without a sibling removes it" do
      %{name: name, tb: tb, normal: normal, sibling: sibling} = ingested()
      first = sibling_of(tb)
      result = result(name, normal, sibling)

      {:ok, again} = Ingestion.ingest_toolchain(result, opts(name, files([normal, sibling])))
      assert again.id == tb.id
      assert %DeterministicBuild{} = second = sibling_of(again)
      refute second.id == first.id
      assert second.run_id == again.run_id

      {:ok, without} =
        Ingestion.ingest_toolchain(
          Map.delete(result, "deterministic_build"),
          opts(name, files([normal]))
        )

      assert without.id == tb.id
      assert sibling_of(without) == nil
    end

    # Foreign priv spec 3.8 row 4 and 4.2: a foreign build's sibling is kept
    # only with the build's foreign paths, each archive passing the content
    # proof and holding the build's members; its archives are its own (its
    # compile stamped other tar times), stored with their blobs.
    test "a foreign build's sibling with the same members is stored with its own archive blobs" do
      {sibling, beams} = ForeignPrivFixtures.sibling(ForeignPrivFixtures.entries("otp29"))
      result = Map.put(ForeignPrivFixtures.writer_result(), "deterministic_build", sibling)
      opts = ForeignPrivFixtures.ingest_opts(ForeignPrivFixtures.files_dir!(beams))
      assert {:ok, row} = Ingestion.ingest_toolchain(result, opts)
      assert %DeterministicBuild{status: :pass} = d = sibling_of(row)
      assert d.foreign_priv_rule == "kino_js_v1"
      assert d.foreign_priv_run_id == d.run_id

      shas = ForeignPrivFixtures.entries("otp29") |> Enum.map(& &1["sha256"]) |> Enum.sort()
      assert d.foreign_priv |> Enum.map(& &1["sha256"]) |> Enum.sort() == shas
      refute shas == ForeignPrivFixtures.entries() |> Enum.map(& &1["sha256"]) |> Enum.sort()

      owned =
        ArtifactMembership
        |> Ash.Query.filter(deterministic_build_id == ^d.id)
        |> Ash.read!(domain: Catalog)
        |> Enum.map(& &1.sha256)

      assert Enum.all?(shas, &(&1 in owned))
    end

    test "a foreign build's sibling whose archive members differ is left out, the build stored" do
      [vl, chart] = ForeignPrivFixtures.entries("otp29")

      {:ok, [{name, bytes}]} =
        :erl_tar.extract({:binary, archive_bytes(vl)}, [:memory, :compressed])

      changed = tar_gz([{name, bytes <> " "}])

      changed_vl = %{
        vl
        | "sha256" => ForeignPrivFixtures.sha(changed),
          "size" => byte_size(changed)
      }

      {sibling, beams} = ForeignPrivFixtures.sibling([changed_vl, chart])
      result = Map.put(ForeignPrivFixtures.writer_result(), "deterministic_build", sibling)
      opts = ForeignPrivFixtures.ingest_opts(ForeignPrivFixtures.files_dir!([changed | beams]))

      log =
        capture_log(fn ->
          assert {:ok, row} = Ingestion.ingest_toolchain(result, opts)
          assert row.status == :pass
          assert sibling_of(row) == nil
        end)

      # Its own content proof refuses it first; the members comparison
      # behind it can only differ with the same name, an md5 collision.
      assert log =~
               "left out: foreign priv refused on the host: foreign priv file priv/assets/Kino_VegaLite/"

      assert log =~ "archive members differ"
    end

    test "a foreign build's sibling with other foreign paths is left out" do
      {sibling, beams} =
        ForeignPrivFixtures.sibling(ForeignPrivFixtures.entries("otp29") |> Enum.take(1))

      result = Map.put(ForeignPrivFixtures.writer_result(), "deterministic_build", sibling)
      opts = ForeignPrivFixtures.ingest_opts(ForeignPrivFixtures.files_dir!(beams))

      log =
        capture_log(fn ->
          assert {:ok, row} = Ingestion.ingest_toolchain(result, opts)
          assert sibling_of(row) == nil
        end)

      assert log =~ "left out: its foreign_priv differs"
    end
  end

  defp archive_bytes(%{"path" => "priv/assets/" <> rel}) do
    [d, file] = String.split(rel, "/")
    File.read!(Path.join([ForeignPrivFixtures.dir(), "otp29", d, file]))
  end

  defp tar_gz(members) do
    path = Path.join(System.tmp_dir!(), "dt-#{System.unique_integer([:positive])}.tar.gz")
    files = for {name, bytes} <- members, do: {name, bytes}
    :ok = :erl_tar.create(String.to_charlist(path), files, [:compressed])
    bytes = File.read!(path)
    File.rm!(path)
    bytes
  end

  describe "publishing" do
    setup do
      ingested()
    end

    test "with the setting off no manifest lists the sibling and its files are not served",
         ctx do
      version = version(ctx.name)
      refute Map.has_key?(version, "deterministic")
      assert [%{"build" => build} = listed] = version["builds"]
      refute Map.has_key?(build, "erl_compiler_options")
      assert ebin_sha(listed) == sha(ctx.normal)
      refute Catalog.published_sha256?(sha(ctx.sibling))
      assert Catalog.published_sha256?(sha(ctx.normal))
    end

    test "with it on the sibling is listed under deterministic alone, with its own files", ctx do
      off = Catalog.precompiled_manifest_v2(ctx.name)
      on!()
      manifest = Catalog.precompiled_manifest_v2(ctx.name)
      version = manifest["versions"]["1.0.0"]

      assert Map.delete(version, "deterministic") == off["versions"]["1.0.0"]
      assert %{"builds" => [%{"build" => build} = sibling]} = version["deterministic"]
      assert build["erl_compiler_options"] == ["deterministic"]
      assert ebin_sha(sibling) == sha(ctx.sibling)
      assert sibling["target"] == "pure_elixir"

      [%{"build" => normal}] = version["builds"]
      assert Map.delete(build, "erl_compiler_options") == normal

      PortalWeb.ApiSpecAssertions.assert_api_schema(manifest, "ManifestV2")
      assert Catalog.published_sha256?(sha(ctx.sibling))
    end

    test "a package's fingerprint changes with its sibling's publication only", ctx do
      %{name: other} = plain = ingested_without_sibling()
      before = Catalog.precompiled_fingerprints()
      on!()
      now = Catalog.precompiled_fingerprints()

      assert now[other] == before[other]
      refute now[ctx.name] == before[ctx.name]

      assert Catalog.precompiled_manifest_v2(plain.name)["versions"]["1.0.0"] |> Map.keys() == [
               "builds"
             ]
    end

    # A batch remembers a package's manifests only when its fingerprint
    # read before the renders equals the one read after; the setting turned
    # on and off again between the two must still read as a change.
    test "the setting turned on and off again changes the fingerprint of its packages only",
         ctx do
      %{name: other} = ingested_without_sibling()
      before = Catalog.precompiled_fingerprints()

      on!()
      off!()

      now = Catalog.precompiled_fingerprints()
      refute now[ctx.name] == before[ctx.name]
      assert now[other] == before[other]
    end

    # The settings' other columns decide no manifest. `remote_auto_on` is
    # written from the enqueue path, so a fingerprint that read it would
    # render a package with siblings again in every batch.
    test "a setting that decides no manifest leaves every fingerprint as it was", ctx do
      on!()
      before = Catalog.precompiled_fingerprints()
      assert Map.has_key?(before, ctx.name)

      {:ok, _} = Portal.Settings.set_remote_auto_on(true)
      {:ok, _} = Portal.Settings.save(%{argus_enabled: false, world_variants_enabled: true})
      {:ok, _} = Portal.Settings.set_remote_auto_on(false)

      assert Catalog.precompiled_fingerprints() == before
    end

    @tag :tmp_dir
    test "the setting turned on during a batch and off again leaves no stale manifest",
         %{name: name, tmp_dir: dir} do
      BatchHooks.signing_key!(dir)
      on!()
      reads = BatchHooks.settings_reads(name)
      off!()

      hook = BatchHooks.flip_during_render(&on!/0, &off!/0, reads)
      {:ok, _b1} = Batches.build_and_sign()
      assert BatchHooks.flipped?(hook)

      {:ok, b2} = Batches.build_and_sign()
      {:ok, bytes} = Manifests.read(Batches.manifests_v2(b2)[name])
      assert {:ok, ^bytes} = Manifests.render_v2(name)
      refute bytes =~ "erl_compiler_options"
    end

    test "the sibling lever withdraws the sibling alone; undo puts it back", ctx do
      on!()

      assert {:revoked, 1, [%{package: package}], at} =
               DeterministicRevocation.revoke(package: ctx.name, dry_run: false)

      assert package == ctx.name
      refute Map.has_key?(version(ctx.name), "deterministic")
      assert [_] = version(ctx.name)["builds"]
      refute Catalog.published_sha256?(sha(ctx.sibling))
      assert sibling_of(ctx.tb).revoked_reason == DeterministicRevocation.reason()

      assert {:ok, 1} = DeterministicRevocation.undo(at)
      assert Map.has_key?(version(ctx.name), "deterministic")
      assert {:error, :filter_required} = DeterministicRevocation.revoke(dry_run: false)
    end
  end

  describe "every lever that withdraws a toolchain build withdraws its sibling" do
    setup do
      on!()
      ingested()
    end

    defp withdrawn?(ctx) do
      version = version(ctx.name)

      not (is_map(version) and Map.has_key?(version, "deterministic")) and
        not Catalog.published_sha256?(sha(ctx.sibling))
    end

    test "rule 2 revocation (`ToolchainRevocation`), and its undo", ctx do
      refute withdrawn?(ctx)

      assert {:revoked, _, _, at} =
               ToolchainRevocation.revoke(package: ctx.name, judge_revision: 29, dry_run: false)

      assert withdrawn?(ctx)
      ToolchainRevocation.undo(at)
      refute withdrawn?(ctx)
    end

    test "a withheld package (`Withheld`)", ctx do
      # A build that records its config reads is never withheld by its closure.
      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET compile_env_rule = NULL WHERE id = $1",
        [Ecto.UUID.dump!(ctx.tb.id)]
      )

      refute withdrawn?(ctx)
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

    test "a revoked toolchain build, by any action", ctx do
      ctx.tb |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
      assert withdrawn?(ctx)
    end

    test "the setting turned off", ctx do
      {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: false})
      assert withdrawn?(ctx)
    end
  end

  defp ingested_without_sibling do
    name = unique()
    {normal, _sibling} = beams(name)
    result = name |> result(normal, normal) |> Map.delete("deterministic_build")
    {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files([normal])))
    %{name: name, tb: tb}
  end
end
