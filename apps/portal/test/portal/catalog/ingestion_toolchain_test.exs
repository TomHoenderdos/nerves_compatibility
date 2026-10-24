defmodule Portal.Catalog.IngestionToolchainTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Artifact, ArtifactMembership, Ingestion, Package, Run, ToolchainBuild}
  alias Portal.Workers.Ingest

  @domain Portal.Catalog

  # Stands in for Portal.Builder in the worker test: replays the build the
  # test put in the process dictionary instead of reading a scratch dir. The
  # worker cleans up through Portal.Builder itself, on a path that is not there.
  defmodule StubBuilder do
    def load_run(_run_id) do
      case Process.get(:toolchain_stub_build) do
        nil -> {:error, :missing_result_json}
        build -> {:ok, build}
      end
    end
  end

  defp blob(content), do: {:crypto.hash(:sha256, content) |> Base.encode16(case: :lower), content}

  defp files_dir_with(blobs) do
    dir = Path.join(System.tmp_dir!(), "toolchain-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(blobs, fn {sha, content} -> File.write!(Path.join(dir, sha), content) end)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp entry(path, {sha, content}),
    do: %{"path" => path, "sha256" => sha, "size" => byte_size(content), "mode" => 33_188}

  defp pass_result(name, beam, priv) do
    %{
      "run_id" => "ignored",
      "scope" => "toolchain",
      "finished_at" => "2026-10-24T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.4.4", "description" => "JSON"},
      "systems" => %{},
      "deps_lock" => %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}},
      "package_checksum" => "outer",
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}},
        "package_checksum" => "outer",
        "compile_env" => [%{"app" => name, "path" => ["k"], "value" => "g2o"}],
        "file_manifest" => %{
          "ebin" => [entry("ebin/#{name}.beam", beam)],
          "priv" => [entry("priv/data.txt", priv)]
        }
      }
    }
  end

  defp skipped_result(name) do
    %{
      "scope" => "toolchain",
      "finished_at" => "2026-10-24T11:00:00Z",
      "package" => %{"name" => name, "version" => "1.4.4"},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "skipped",
        "reason" => "os-specific source",
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => nil
      }
    }
  end

  defp opts(files_dir, run_id \\ "tc-#{System.unique_integer([:positive])}") do
    %{
      run_id: run_id,
      image_digest: "sha256:toolchain",
      files_dir: files_dir,
      output_dir: files_dir,
      toolchain: "1.19/28",
      builder_version: 1
    }
  end

  defp memberships(tb) do
    ArtifactMembership
    |> Ash.Query.filter(toolchain_build_id == ^tb.id)
    |> Ash.read!(domain: @domain)
  end

  defp existing_package!(name) do
    last_run_at = ~U[2026-10-01 09:00:00Z]

    Package
    |> Ash.Changeset.for_create(:upsert, %{
      name: name,
      latest_version: "1.4.4",
      last_run_at: last_run_at
    })
    |> Ash.create!(domain: @domain)
  end

  defp unique_name, do: "tcpkg_#{System.unique_integer([:positive])}"

  test "a passing build stores one row, its files and their memberships, and no run" do
    name = unique_name()
    pkg = existing_package!(name)
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")
    runs_before = Ash.count!(Run, domain: @domain)

    assert {:ok, %ToolchainBuild{} = tb} =
             Ingestion.ingest_toolchain(
               pass_result(name, beam, priv),
               opts(files_dir_with([beam, priv]))
             )

    assert tb.package_id == pkg.id
    assert tb.status == :pass
    assert tb.version == "1.4.4"
    assert tb.toolchain == "1.19/28"
    assert tb.builder_version == 1
    assert tb.elixir == "1.19.1" and tb.otp == "28"
    assert tb.image_digest == "sha256:toolchain"
    assert tb.deps_lock == %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
    assert tb.package_checksum == "outer"
    assert tb.compile_env == [%{"app" => name, "path" => ["k"], "value" => "g2o"}]
    assert %{"ebin" => [_], "priv" => [_]} = tb.file_manifest
    assert tb.finished_at == ~U[2026-10-24 10:00:00.000000Z]

    shas = Enum.sort([elem(beam, 0), elem(priv, 0)])
    assert shas == tb |> memberships() |> Enum.map(& &1.sha256) |> Enum.sort()

    for sha <- shas do
      assert File.exists?(ArtifactStore.blob_path(sha))

      assert Artifact
             |> Ash.Query.filter(sha256 == ^sha)
             |> Ash.exists?(domain: @domain)
    end

    assert Ash.count!(Run, domain: @domain) == runs_before
    assert Ash.get!(Package, pkg.id, domain: @domain).last_run_at == pkg.last_run_at
  end

  test "re-ingesting the same build keeps one row and its memberships" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")
    result = pass_result(name, beam, priv)
    files_dir = files_dir_with([beam, priv])

    assert {:ok, first} = Ingestion.ingest_toolchain(result, opts(files_dir, "tc-a"))
    # The blobs have left files_dir by now, as on an Oban retry.
    assert {:ok, second} = Ingestion.ingest_toolchain(result, opts(files_dir, "tc-a"))

    assert first.id == second.id
    assert length(memberships(second)) == 2
    assert 1 == ToolchainBuild |> Ash.Query.filter(id == ^first.id) |> Ash.count!(domain: @domain)
  end

  test "a package seen first through a toolchain build gets a row with no last run" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")

    assert {:ok, tb} =
             Ingestion.ingest_toolchain(
               pass_result(name, beam, priv),
               opts(files_dir_with([beam, priv]))
             )

    pkg = Ash.get!(Package, tb.package_id, domain: @domain)
    assert pkg.name == name
    assert pkg.last_run_at == nil
  end

  test "a skipped build stores its reason and no memberships" do
    name = unique_name()

    assert {:ok, tb} = Ingestion.ingest_toolchain(skipped_result(name), opts(files_dir_with([])))

    assert tb.status == :skipped
    assert tb.reason == "os-specific source"
    assert tb.file_manifest == nil
    assert memberships(tb) == []
  end

  test "a rebuild that no longer passes drops the previous build's memberships" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")

    {:ok, passed} =
      Ingestion.ingest_toolchain(
        pass_result(name, beam, priv),
        opts(files_dir_with([beam, priv]))
      )

    {:ok, skipped} = Ingestion.ingest_toolchain(skipped_result(name), opts(files_dir_with([])))

    assert passed.id == skipped.id
    assert memberships(skipped) == []
  end

  describe "Portal.Workers.Ingest with kind toolchain" do
    setup do
      Application.put_env(:portal, :build_runner, StubBuilder)
      on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
      :ok
    end

    test "ingests the toolchain build and touches no run or request" do
      name = unique_name()
      pkg = existing_package!(name)
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")
      files_dir = files_dir_with([beam, priv])

      Process.put(:toolchain_stub_build, %{
        exit_code: 0,
        result: pass_result(name, beam, priv),
        files_dir: files_dir,
        output_dir: files_dir,
        log: "runner log"
      })

      runs_before = Ash.count!(Run, domain: @domain)

      args = %{
        "run_id" => "tc-worker",
        "image_digest" => "sha256:toolchain",
        "kind" => "toolchain",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }

      assert :ok = Ingest.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})

      assert [tb] =
               ToolchainBuild
               |> Ash.Query.filter(package_id == ^pkg.id)
               |> Ash.read!(domain: @domain)

      assert tb.run_id == "tc-worker"
      assert tb.toolchain == "1.19/28"
      assert length(memberships(tb)) == 2
      assert Ash.count!(Run, domain: @domain) == runs_before
      assert Ash.get!(Package, pkg.id, domain: @domain).last_run_at == pkg.last_run_at
    end

    test "cancels when the build output is gone" do
      Process.delete(:toolchain_stub_build)

      args = %{
        "run_id" => "tc-missing",
        "image_digest" => "sha256:toolchain",
        "kind" => "toolchain",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }

      assert {:cancel, _} = Ingest.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})
    end
  end
end
