defmodule Portal.HostNativeTest do
  # Host-native builds (board #85): queued, ingested and published only
  # while the `host_native_enabled` setting is on, each file verified again
  # on the host (`Portal.HostNative.Ingest`).
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, HostNativeBuild}
  alias Portal.HostNative
  alias Portal.HostNative.Ingest
  alias Portal.{BatchHooks, PrecompiledFixtures}
  alias Portal.Precompiled.{Batches, Manifests}

  @elf Path.expand("../../../compatibility/test/fixtures/elf", __DIR__)
  @triple "aarch64-linux-gnu"
  @archive "libfx-v1.0.0-nif-2.17-aarch64-unknown-linux-gnu.so.tar.gz"

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp unique, do: "hnpkg_#{System.unique_integer([:positive])}"
  defp nif, do: File.read!(Path.join(@elf, "nif_aarch64.so"))
  defp on!, do: {:ok, _} = Portal.Settings.save(%{host_native_enabled: true})
  defp off!, do: {:ok, _} = Portal.Settings.save(%{host_native_enabled: false})

  defp tmp(name) do
    dir = Path.join(System.tmp_dir!(), "#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp tar(entries, opts) do
    path = Path.join(tmp("hn-tar"), "t")
    :ok = :erl_tar.create(String.to_charlist(path), entries, opts)
    File.read!(path)
  end

  defp archive, do: tar([{~c"libfx.so", nif()}], [:compressed])

  # The package's Hex tarball: `files` at the root of its contents.
  defp hex_tarball(files) do
    contents =
      tar(for({p, b} <- Map.put(files, "lib/fx.ex", "x"), do: {to_charlist(p), b}), [:compressed])

    tar([{~c"VERSION", "3"}, {~c"CHECKSUM", "0"}, {~c"contents.tar.gz", contents}], [])
  end

  defp entry(path, bytes, mode),
    do: %{"path" => path, "sha256" => sha(bytes), "size" => byte_size(bytes), "mode" => mode}

  defp result(name, tarball, origins) do
    %{
      "scope" => "host_native",
      "finished_at" => "2026-11-16T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{},
      "host_native_build" => %{
        "status" => "pass",
        "triple" => @triple,
        "libc" => "glibc",
        "elixir" => "1.20.5",
        "otp" => "29",
        "otp_full" => "29.0.1",
        "nif_version" => "2.18",
        "deps_lock" => %{},
        "package_checksum" => sha(tarball),
        "compile_env" => [],
        "compile_env_rule" => 1,
        "compile_inputs" => [],
        "judge_revision" => 19,
        "manager" => "mix",
        "origins" => origins,
        "file_manifest" => %{
          "ebin" => [entry("ebin/fx.app", "{application,fx,[]}.", 33_188)],
          "priv" => [entry("priv/native/libfx.so", nif(), 33_261)]
        }
      }
    }
  end

  defp files_dir(blobs) do
    dir = tmp("hn-files")
    Enum.each(blobs, &File.write!(Path.join(dir, sha(&1)), &1))
    dir
  end

  defp opts(name, files_dir, tarball, extra \\ %{}) do
    Map.merge(
      %{
        run_id: "hn-#{System.unique_integer([:positive])}",
        image_digest: "sha256:hn",
        files_dir: files_dir,
        package: name,
        version: "1.0.0",
        toolchain: "1.20/29",
        triple: @triple,
        builder_version: 1,
        hex_tarball: fn _name, _version -> {:ok, tarball} end,
        hex_outer_checksum: fn _name, _version -> {:ok, sha(tarball)} end
      },
      extra
    )
  end

  defp ingest(name, tarball, origins, blobs) do
    Ingest.ingest(result(name, tarball, origins), opts(name, files_dir(blobs), tarball))
  end

  defp origin(archive),
    do: %{
      "path" => "priv/native/libfx.so",
      "checksum_file" => "checksum-Elixir.Fx.Native.exs",
      "archive" => @archive,
      "archive_sha256" => sha(archive)
    }

  # A downloader: its tarball's checksum file pins the archive the NIF is a
  # member of, and the run handed over both. `{tarball, origins, blobs}`.
  defp downloader do
    archive = archive()
    checksum = ~s(%{"#{@archive}" => "sha256:#{sha(archive)}"}\n)
    tarball = hex_tarball(%{"checksum-Elixir.Fx.Native.exs" => checksum})
    {tarball, [origin(archive)], ["{application,fx,[]}.", nif(), archive]}
  end

  describe "the setting" do
    test "off by default: nothing is queued" do
      refute HostNative.enabled?()
      assert HostNative.enqueue("fx", "1.0.0") == {:error, :disabled}
    end

    test "on: a build is queued on its triple's architecture's queue" do
      on!()

      assert {:ok, job} = HostNative.enqueue("fx", "1.0.0", triple: "aarch64-linux-gnu")
      assert job.queue == "host_native_aarch64"
      assert %{"triple" => "aarch64-linux-gnu", "builder_version" => 1} = job.args

      assert HostNative.enqueue("fx", "1.0.0", triple: "x86_64-linux-musl") ==
               {:error, :unknown_triple}

      assert HostNative.queue("x86_64-linux-gnu") == {:ok, "host_native_x86_64"}
    end
  end

  describe "ingest" do
    # Nothing checks what a compile in the run assumed of the builder's CPU
    # (`-march=native`), its run paths, or what it downloaded unchecked.
    test "a NIF the package compiled in the run is refused, with no files" do
      name = unique()
      tarball = hex_tarball(%{})

      assert {:ok, %{status: :fail, reason: reason, file_manifest: nil, origins: nil} = row} =
               ingest(name, tarball, [], ["{application,fx,[]}.", nif()])

      assert reason ==
               "refused at ingest: native file compiled in the run, " <>
                 "not a checksum-pinned download: priv/native/libfx.so"

      assert ArtifactMembership
             |> Ash.Query.filter(host_native_build_id == ^row.id)
             |> Ash.read!(domain: Catalog) == []
    end

    test "a downloader's NIF is stored with the host's own ELF facts" do
      {tarball, origins, blobs} = downloader()
      assert {:ok, row} = ingest(unique(), tarball, origins, blobs)

      assert %{status: :pass, triple: @triple, nif_version: "2.18", origins: ^origins} = row
      assert row.elf_needs["libc.so.6"] == ["GLIBC_2.17"]

      shas =
        ArtifactMembership
        |> Ash.Query.filter(host_native_build_id == ^row.id)
        |> Ash.read!(domain: Catalog)
        |> Enum.map(& &1.sha256)

      assert sha(nif()) in shas
    end

    test "a native file outside priv is refused, with no files" do
      {tarball, origins, blobs} = downloader()
      name = unique()

      result =
        update_in(
          result(name, tarball, origins),
          ["host_native_build", "file_manifest", "ebin"],
          &[entry("ebin/libextra.so", nif(), 33_261) | &1]
        )

      assert {:ok, %{status: :fail, reason: reason, file_manifest: nil}} =
               Ingest.ingest(result, opts(name, files_dir(blobs), tarball))

      assert reason == "refused at ingest: ships a native file outside priv (ebin/libextra.so)"
    end

    test "a could-not-judge names its cause, with no files" do
      name = unique()
      tarball = hex_tarball(%{})

      result =
        name
        |> result(tarball, [])
        |> update_in(["host_native_build"], fn build ->
          Map.merge(build, %{
            "status" => "skipped",
            "reason" => "portability could not be judged",
            "compile_observations" => %{"problems" => ["traced compile exited 1"]}
          })
        end)

      assert {:ok, %{status: :skipped, reason: reason, file_manifest: nil}} =
               Ingest.ingest(result, opts(name, files_dir([]), tarball))

      assert reason == "portability could not be judged (traced compile exited 1)"
    end

    test "a NIF of another machine is refused, with no files" do
      name = unique()
      tarball = hex_tarball(%{})

      opts =
        opts(name, files_dir(["{application,fx,[]}.", nif()]), tarball, %{
          triple: "x86_64-linux-gnu"
        })

      result =
        put_in(result(name, tarball, []), ["host_native_build", "triple"], "x86_64-linux-gnu")

      assert {:ok, %{status: :fail, reason: reason, file_manifest: nil}} =
               Ingest.ingest(result, opts)

      assert reason =~ "x86_64-linux-gnu cannot load (priv/native/libfx.so)"
    end

    # The library a user's own compile loads is picked by env its native
    # tool reads (rustler_precompiled's TARGET_* overrides, a force-build
    # variable), which only the build's compile inputs carry: a client takes
    # a build without that list (as builds from before 0.6.0 have none), so
    # a pass without it would reach a user whose env picks another library.
    test "a pass that records no compile inputs is refused, with no files" do
      {tarball, origins, blobs} = downloader()
      name = unique()

      result =
        update_in(
          result(name, tarball, origins),
          ["host_native_build"],
          &Map.delete(&1, "compile_inputs")
        )

      assert {:ok, %{status: :fail, reason: reason, file_manifest: nil, origins: nil}} =
               Ingest.ingest(result, opts(name, files_dir(blobs), tarball))

      assert reason == "refused at ingest: records no compile inputs"
    end

    # Round 5, R3-2: a declared-absent probe of a module another popular
    # package defines refuses here too (`Portal.Catalog.ModuleIndex`); with
    # no complete index, every recorded probe does.
    test "a declared-absent probe the module index refuses is refused, with no files" do
      {tarball, origins, blobs} = downloader()
      name = unique()

      record = %{
        "kind" => "module_absent",
        "module" => "Elixir.Money",
        "declared" => ["ex_money"],
        "declared_apps" => ["ex_money"],
        "via" => "Code.ensure_loaded?/1"
      }

      result =
        put_in(
          result(name, tarball, origins),
          ["host_native_build", "compile_observations"],
          %{"declared_absent" => [record]}
        )

      assert {:ok, %{status: :fail, reason: reason, file_manifest: nil}} =
               Ingest.ingest(result, opts(name, files_dir(blobs), tarball))

      assert reason ==
               "refused at ingest: compile-time probe of a dependency outside the closure: " <>
                 "Elixir.Money via Code.ensure_loaded?/1 (module index not complete)"
    end

    test "a result naming another triple than the job is refused whole" do
      name = unique()
      tarball = hex_tarball(%{})
      opts = opts(name, files_dir([]), tarball, %{triple: "x86_64-linux-gnu"})

      assert {:error, {:identity_mismatch, _job, %{triple: @triple}}} =
               Ingest.ingest(result(name, tarball, []), opts)
    end
  end

  defmodule LoadRunStub do
    def load_run(_run_id), do: Process.get(:load_run)
  end

  describe "the ingest job" do
    setup do
      Application.put_env(:portal, :build_runner, LoadRunStub)
      on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    end

    test "stores a host-native result under the job's identity" do
      name = unique()
      {tarball, origins, blobs} = downloader()
      dir = files_dir(blobs)
      Process.put(:load_run, {:ok, %{result: result(name, tarball, origins), files_dir: dir}})
      Process.put({Portal.Test.FakeHexDeps, :tarball}, {:ok, tarball})
      Process.put({Portal.Test.FakeHexDeps, :outer_checksum}, {:ok, sha(tarball)})

      args = %{
        "kind" => "host_native",
        "run_id" => "hn-job",
        "image_digest" => "sha256:hn",
        "package" => name,
        "version" => "1.0.0",
        "toolchain" => "1.20/29",
        "triple" => @triple,
        "builder_version" => 1
      }

      assert :ok = perform_job(Portal.Workers.Ingest, args)

      assert [%{status: :pass, run_id: "hn-job"}] =
               HostNativeBuild
               |> Ash.Query.filter(package.name == ^name)
               |> Ash.read!(domain: Catalog)

      # The same result for a job of another triple is refused whole.
      Process.put(:load_run, {:ok, %{result: result(name, tarball, origins), files_dir: dir}})
      args = %{args | "triple" => "x86_64-linux-gnu", "run_id" => "hn-job-2"}
      assert {:cancel, _reason} = perform_job(Portal.Workers.Ingest, args)
    end
  end

  describe "publication" do
    setup do
      name = unique()
      {tarball, origins, blobs} = downloader()
      {:ok, %{status: :pass} = row} = ingest(name, tarball, origins, blobs)
      %{name: name, row: row}
    end

    test "listed under builds_host_native and served only while the setting is on", %{name: name} do
      refute Catalog.published_sha256?(sha(nif()))
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute Map.has_key?(Catalog.precompiled_fingerprints(), name)
      refute name in Catalog.packages_with_precompiled_files()

      on!()

      assert %{"versions" => %{"1.0.0" => version}} = Catalog.precompiled_manifest_v2(name)
      assert version["builds"] == []

      assert [%{"target" => "host_native", "build" => build, "priv" => [priv]}] =
               version["builds_host_native"]

      assert %{"triple" => @triple, "libc" => "glibc", "nif_version" => "2.18", "native" => true} =
               build

      assert build["elf"]["needs"]["libc.so.6"] == ["GLIBC_2.17"]
      assert priv["sha256"] == sha(nif())
      assert Catalog.published_sha256?(sha(nif()))
      assert name in Catalog.packages_with_precompiled_files()
      assert Map.has_key?(Catalog.precompiled_fingerprints(), name)
    end

    # Withdrawing one build: the setting and `Withheld` act per feature and
    # per package; a build found unsafe (a judge refinement rolled back, a
    # bad upstream archive) needs a lever of its own.
    test "revoke/1 lists, then takes a build out of the manifest, files and fingerprint",
         %{name: name, row: row} do
      alias Portal.Precompiled.HostNativeRevocation, as: Revocation

      on!()
      before = Map.fetch!(Catalog.precompiled_fingerprints(), name)

      assert {:dry_run, [listed]} = Revocation.revoke(package: name)
      assert listed.id == row.id and listed.package == name and listed.triple == @triple
      assert Catalog.published_sha256?(sha(nif()))

      assert {:error, :filter_required} = Revocation.revoke(dry_run: false)
      assert {:error, :filter_required} = Revocation.revoke(package: nil, dry_run: false)
      assert {:dry_run, []} = Revocation.revoke(package: name, judge_revision: 10_000)

      assert {:revoked, 1, [_], at} = Revocation.revoke(package: name, dry_run: false)
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute Catalog.published_sha256?(sha(nif()))
      refute name in Catalog.packages_with_precompiled_files()
      refute Map.get(Catalog.precompiled_fingerprints(), name) == before
      assert {at, 1} in Revocation.revocations()

      # A rebuild of the same identity stays revoked.
      {tarball, origins, blobs} = downloader()
      assert {:ok, %{revoked_at: %DateTime{}}} = ingest(name, tarball, origins, blobs)
      assert Catalog.precompiled_manifest_v2(name) == nil

      assert {:ok, 1} = Revocation.undo(at)

      assert %{"versions" => %{"1.0.0" => %{"builds_host_native" => [_]}}} =
               Catalog.precompiled_manifest_v2(name)
    end

    test "the manifest route serves the documented shape", %{name: name} do
      on!()

      conn =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(
          PortalWeb.Endpoint,
          :get,
          "/api/precompiled/v2/manifests/#{name}.json"
        )

      assert conn.status == 200
      PortalWeb.ApiSpecAssertions.assert_documented_response(conn, "getManifestV2")

      blob =
        Phoenix.ConnTest.build_conn()
        |> Phoenix.ConnTest.dispatch(
          PortalWeb.Endpoint,
          :get,
          "/api/precompiled/files/#{sha(nif())}"
        )

      assert blob.status in [200, 404]
    end

    # A batch reuses a package's manifests while its fingerprint holds, and
    # the setting changes no manifest of a package with no host-native row.
    test "a package without host-native builds keeps its fingerprint bytes" do
      other = "hn_fp_#{System.unique_integer([:positive])}"
      Portal.PrecompiledFixtures.ingest_toolchain_build(other, "0.1.0", deps_lock: %{})
      off = Map.fetch!(Catalog.precompiled_fingerprints(), other)
      refute off =~ "host_native"

      on!()
      assert Map.fetch!(Catalog.precompiled_fingerprints(), other) == off
    end

    # A batch remembers a package's manifests only when its fingerprint
    # read before the renders equals the one read after; the setting turned
    # on and off again between the two must still read as a change.
    test "the setting turned on and off again changes the fingerprint of its packages only",
         %{name: name} do
      PrecompiledFixtures.ingest_toolchain_build(name, "0.1.0")
      other = "hn_aba_#{System.unique_integer([:positive])}"
      PrecompiledFixtures.ingest_toolchain_build(other, "0.1.0")
      before = Catalog.precompiled_fingerprints()

      on!()
      off!()

      now = Catalog.precompiled_fingerprints()
      refute now[name] == before[name]
      assert now[other] == before[other]
    end

    @tag :tmp_dir
    test "the setting turned on during a batch and off again leaves no stale manifest",
         %{name: name, tmp_dir: dir} do
      # Listed while the setting is off, through a toolchain build.
      PrecompiledFixtures.ingest_toolchain_build(name, "0.1.0")
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
      refute bytes =~ "builds_host_native"
    end

    # Review S5 S1: a host-native build that ran a rebar3 plugin is withheld
    # while Hex has a release of it nobody reviewed.
    test "a build that ran a watched plugin is withheld, and served again once reviewed" do
      name = unique()
      {tarball, origins, blobs} = downloader()

      plugins = %{
        "rebar3_plugins" => [%{"owner" => "dep", "name" => "rebar3_hex", "version" => "7.5.0"}]
      }

      result =
        put_in(
          result(name, tarball, origins),
          ["host_native_build", "compile_observations"],
          plugins
        )

      {:ok, %{status: :pass}} = Ingest.ingest(result, opts(name, files_dir(blobs), tarball))
      on!()

      # A watch never written withholds it too (review S5 R4).
      refute name in Catalog.packages_with_precompiled_files()

      Portal.Precompiled.PluginWatch.refresh([
        %{
          name: "rebar3_hex",
          latest_version: "x",
          versions: Map.keys(Compatibility.RebarPlugins.pins()["rebar3_hex"])
        }
      ])

      # The NIF's bytes are the setup's build's too: judged per package.
      assert name in Catalog.packages_with_precompiled_files()

      reviewed = Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Map.keys()

      watch =
        &Portal.Precompiled.PluginWatch.refresh([
          %{name: "rebar3_hex", latest_version: "x", versions: &1}
        ])

      watch.(reviewed ++ ["9.0.0"])
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute name in Catalog.packages_with_precompiled_files()

      watch.(reviewed)

      assert %{"versions" => %{"1.0.0" => %{"builds_host_native" => [_]}}} =
               Catalog.precompiled_manifest_v2(name)

      assert name in Catalog.packages_with_precompiled_files()
    end

    test "a revoked build is not served", %{name: name, row: row} do
      on!()
      row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
      assert Catalog.precompiled_manifest_v2(name) == nil
      refute Catalog.published_sha256?(sha(nif()))

      assert [%HostNativeBuild{}] =
               Ash.read!(HostNativeBuild, domain: Catalog) |> Enum.filter(&(&1.id == row.id))
    end
  end
end
