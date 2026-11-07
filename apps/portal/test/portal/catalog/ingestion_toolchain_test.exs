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

  # The release as Hex serves it: an outer tar around contents.tar.gz with
  # the build's priv file, which the host checks the build against at ingest
  # (Portal.Catalog.ToolchainPriv). Put where Portal.Test.FakeHexDeps answers
  # from, for the ingest and the inline job alike; returns its outer checksum.
  defp hex_release!({_sha, priv}) do
    contents = in_memory_tar([{~c"priv/data.txt", priv}], [:compressed])

    outer =
      in_memory_tar([
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", ~s({<<"name">>,<<"x">>}.\n)},
        {~c"contents.tar.gz", contents}
      ])

    checksum = :crypto.hash(:sha256, outer) |> Base.encode16(case: :lower)
    Process.put({Portal.Test.FakeHexDeps, :tarball}, {:ok, outer})
    Process.put({Portal.Test.FakeHexDeps, :outer_checksum}, {:ok, checksum})
    checksum
  end

  defp in_memory_tar(entries, options \\ []) do
    path = Path.join(System.tmp_dir!(), "hex-release-#{System.unique_integer([:positive])}.tar")
    on_exit(fn -> File.rm(path) end)
    :ok = :erl_tar.create(String.to_charlist(path), entries, options)
    File.read!(path)
  end

  defp pass_result(name, beam, priv) do
    checksum = hex_release!(priv)

    %{
      "run_id" => "ignored",
      "scope" => "toolchain",
      "finished_at" => "2026-10-24T10:00:00Z",
      "package" => %{"name" => name, "version" => "1.4.4", "description" => "JSON"},
      "systems" => %{},
      "deps_lock" => %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}},
      "package_checksum" => checksum,
      "toolchain_build" => %{
        "status" => "pass",
        "reason" => nil,
        "elixir" => "1.19.1",
        "otp" => "28",
        "deps_lock" => %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}},
        "package_checksum" => checksum,
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

  defp opts(name, files_dir, run_id \\ "tc-#{System.unique_integer([:positive])}") do
    %{
      package: name,
      version: "1.4.4",
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
      description: "an existing package",
      latest_version: "1.4.3",
      last_run_at: last_run_at
    })
    |> Ash.create!(domain: @domain)
  end

  # Random as well as unique: blobs are named after the package, and the
  # artifact store outlives the test run, so a name reused by a later run would
  # find its "unstaged" blob already stored.
  defp unique_name,
    do:
      "tcpkg_#{System.unique_integer([:positive])}_#{Base.encode16(:crypto.strong_rand_bytes(4), case: :lower)}"

  test "a passing build stores one row, its files and their memberships, and no run" do
    name = unique_name()
    pkg = existing_package!(name)
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")
    runs_before = Ash.count!(Run, domain: @domain)

    assert {:ok, %ToolchainBuild{} = tb} =
             Ingestion.ingest_toolchain(
               pass_result(name, beam, priv),
               opts(name, files_dir_with([beam, priv]))
             )

    assert tb.package_id == pkg.id
    assert tb.status == :pass
    assert tb.version == "1.4.4"
    assert tb.toolchain == "1.19/28"
    assert tb.builder_version == 1
    assert tb.elixir == "1.19.1" and tb.otp == "28"
    assert tb.image_digest == "sha256:toolchain"
    assert tb.deps_lock == %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}}
    assert {:ok, tb.package_checksum} == Process.get({Portal.Test.FakeHexDeps, :outer_checksum})
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
    stored = Ash.get!(Package, pkg.id, domain: @domain)
    assert stored.last_run_at == pkg.last_run_at
    assert stored.description == "an existing package"
    assert stored.latest_version == "1.4.3"
  end

  test "re-ingesting the same build keeps one row and its memberships" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")
    result = pass_result(name, beam, priv)
    files_dir = files_dir_with([beam, priv])

    assert {:ok, first} = Ingestion.ingest_toolchain(result, opts(name, files_dir, "tc-a"))
    # The blobs have left files_dir by now, as on an Oban retry.
    assert {:ok, second} = Ingestion.ingest_toolchain(result, opts(name, files_dir, "tc-a"))

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
               opts(name, files_dir_with([beam, priv]))
             )

    pkg = Ash.get!(Package, tb.package_id, domain: @domain)
    assert pkg.name == name
    assert pkg.last_run_at == nil
  end

  test "a skipped build stores its reason and no memberships" do
    name = unique_name()

    assert {:ok, tb} =
             Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

    assert tb.status == :skipped
    assert tb.reason == "os-specific source"
    assert tb.file_manifest == nil
    assert memberships(tb) == []
  end

  test "each version a job names gets its own row" do
    name = unique_name()
    queued = Map.put(opts(name, files_dir_with([])), :version, "1.4.5")

    queued_result = put_in(skipped_result(name), ["package", "version"], "1.4.5")
    assert {:ok, tb} = Ingestion.ingest_toolchain(queued_result, queued)
    assert tb.version == "1.4.5"

    assert {:ok, fallback} =
             Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

    assert fallback.version == "1.4.4"
    refute fallback.id == tb.id
  end

  test "a failed host compile is stored as a fail verdict, not an error" do
    name = unique_name()

    result =
      skipped_result(name)
      |> put_in(["toolchain_build", "status"], "error")
      |> put_in(["toolchain_build", "reason"], "host compile failed")

    assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))

    assert tb.status == :fail
    assert tb.reason == "compile failed: host compile failed"
    assert memberships(tb) == []
  end

  # Processes left running after the build are not a compile failure: the
  # worker's own reason is stored under its own label.
  test "a build the worker's process sweep failed is stored with the sweep's reason" do
    name = unique_name()

    result =
      skipped_result(name)
      |> put_in(["toolchain_build", "status"], "error")
      |> put_in(
        ["toolchain_build", "reason"],
        "processes survived the sweep and could not be stopped: 40 (sh)"
      )

    assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))

    assert tb.status == :fail
    assert tb.reason == "worker: processes survived the sweep and could not be stopped: 40 (sh)"
    assert memberships(tb) == []
  end

  # A portal build whose sweep could not run at all is no more trusted than
  # one with survivors, and is stored under the same label. It says nothing
  # about the package, though: the image or runtime it ran on did it, so it
  # is an error the backlog retries after a day, not a week-long verdict.
  test "a build whose process sweep could not run is stored with the sweep's reason" do
    name = unique_name()

    result =
      skipped_result(name)
      |> put_in(["toolchain_build", "status"], "error")
      |> put_in(["toolchain_build", "reason"], "process sweep could not run: not linux")

    assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))

    assert tb.status == :error
    assert tb.reason == "worker: process sweep could not run: not linux"
    assert memberships(tb) == []
  end

  defp could_not_judge(name, trace_stats) do
    skipped_result(name)
    |> put_in(["toolchain_build", "reason"], "portability could not be judged")
    |> put_in(["toolchain_build", "compile_observations"], %{"trace_stats" => trace_stats})
  end

  describe "a trace that could not judge" do
    # A traced compile that did not finish, or whose report was over its
    # read budget, says nothing about the package: an error, which the
    # backlog retries after a day.
    test "transiently is stored as an error" do
      name = unique_name()
      result = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert tb.status == :error
      assert tb.reason == "portability could not be judged"
      assert tb.compile_observations["trace_stats"]["transient"] == true
    end

    test "for a reason the package carries stays skipped" do
      name = unique_name()
      result = could_not_judge(name, %{"judge_compile" => "finished", "transient" => false})

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert {tb.status, tb.reason} == {:skipped, "portability could not be judged"}
    end

    test "from a worker that does not mark it stays skipped" do
      name = unique_name()
      result = could_not_judge(name, %{"judge_compile" => "not_finished"})

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert tb.status == :skipped
    end

    test "transiently, behind another skip reason, keeps that reason's skip" do
      name = unique_name()

      result =
        name
        |> could_not_judge(%{"judge_compile" => "not_finished", "transient" => true})
        |> put_in(["toolchain_build", "reason"], "os-specific source")

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert {tb.status, tb.reason} == {:skipped, "os-specific source"}
    end

    test "transiently never replaces a pass row; the row records the attempt" do
      name = unique_name()
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      {:ok, passed} =
        Ingestion.ingest_toolchain(
          pass_result(name, beam, priv),
          opts(name, files_dir_with([beam, priv]))
        )

      result = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})
      assert {:ok, kept} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))

      assert kept.id == passed.id
      assert kept.status == :pass
      assert kept.file_manifest == passed.file_manifest
      assert %DateTime{} = kept.attempted_at
      assert length(memberships(kept)) == 2
    end

    test "counts transient results and gives up at the cap, as a skip" do
      name = unique_name()
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      for n <- 1..4 do
        assert {:ok, tb} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
        assert {tb.status, tb.transient_attempts} == {:error, n}
      end

      assert {:ok, tb} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      assert tb.status == :skipped
      assert tb.reason == "portability could not be judged (transient 5 times)"
      assert tb.transient_attempts == 5
    end

    test "a verdict resets the count" do
      name = unique_name()
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      assert {:ok, %{transient_attempts: 1}} =
               Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

      assert {tb.status, tb.transient_attempts} == {:skipped, 0}
    end

    test "a kept row counts its transient retries" do
      name = unique_name()
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      {:ok, passed} =
        Ingestion.ingest_toolchain(
          pass_result(name, beam, priv),
          opts(name, files_dir_with([beam, priv]))
        )

      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      assert {:ok, kept} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      assert {kept.id, kept.status, kept.transient_attempts} == {passed.id, :pass, 1}
      assert %DateTime{} = kept.attempted_at

      assert {:ok, kept} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      assert kept.transient_attempts == 2
    end

    # Reaching the cap on a kept pass row neither unpublishes nor downgrades
    # it: the cap only turns a row with no verdict into a skip.
    test "a kept pass row stays published at and past the cap" do
      name = unique_name()
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      {:ok, passed} =
        Ingestion.ingest_toolchain(
          pass_result(name, beam, priv),
          opts(name, files_dir_with([beam, priv]))
        )

      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      for _ <- 1..6 do
        assert {:ok, _} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      end

      kept = Ash.get!(ToolchainBuild, passed.id, domain: @domain)
      assert {kept.status, kept.reason, kept.transient_attempts} == {:pass, nil, 6}
      assert kept.file_manifest == passed.file_manifest
      assert kept.revoked_at == nil
      assert length(memberships(kept)) == 2
    end

    test "a pass after the cap publishes and resets the count" do
      name = unique_name()
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      for _ <- 1..5 do
        assert {:ok, _} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      end

      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(
                 pass_result(name, beam, priv),
                 opts(name, files_dir_with([beam, priv]))
               )

      assert {tb.status, tb.reason, tb.transient_attempts} == {:pass, nil, 0}
      assert length(memberships(tb)) == 2
    end

    # An error that is not a transient could-not-judge is no verdict either:
    # it neither counts towards the cap nor resets the count.
    test "another error keeps the count" do
      name = unique_name()
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      sweep_error =
        skipped_result(name)
        |> put_in(["toolchain_build", "status"], "error")
        |> put_in(["toolchain_build", "reason"], "process sweep could not run: not linux")

      for _ <- 1..2 do
        assert {:ok, _} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      end

      assert {:ok, tb} = Ingestion.ingest_toolchain(sweep_error, opts(name, files_dir_with([])))
      assert {tb.status, tb.transient_attempts} == {:error, 2}

      assert {:ok, tb} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      assert tb.transient_attempts == 3
    end

    test "a capped skip stays skipped, keeps counting and leaves the backlog" do
      name = unique_name()
      host_pass_run!(name)
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})

      for _ <- 1..4 do
        assert {:ok, _} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      end

      # An error row from a day ago is retried ...
      assert in_backlog?(name)

      assert {:ok, %{status: :skipped}} =
               Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))

      # ... a capped skip is not, at this builder version.
      refute in_backlog?(name)

      assert {:ok, tb} = Ingestion.ingest_toolchain(transient, opts(name, files_dir_with([])))
      assert tb.status == :skipped
      assert tb.reason == "portability could not be judged (transient 5 times)"
      assert tb.transient_attempts == 6
      assert %DateTime{} = tb.attempted_at
      refute in_backlog?(name)
    end

    # Two ingests of one identity, from different nodes' ingest queues or a
    # local and a remote build, must not both read the same count: each
    # waits for the other's transaction on the identity's lock.
    test "an ingest waits for another transaction holding the identity" do
      name = unique_name()
      transient = could_not_judge(name, %{"judge_compile" => "not_finished", "transient" => true})
      parent = self()

      holder =
        Task.async(fn ->
          :ok = Ecto.Adapters.SQL.Sandbox.checkout(Portal.Repo)

          Portal.Repo.transaction(fn ->
            :ok = Ingestion.lock_toolchain_identity(opts(name, nil))
            send(parent, :locked)
            receive do: (:release -> :ok)
          end)

          Ecto.Adapters.SQL.Sandbox.checkin(Portal.Repo)
        end)

      assert_receive :locked, 5_000

      ingest_opts = opts(name, files_dir_with([]))
      ingest = Task.async(fn -> Ingestion.ingest_toolchain(transient, ingest_opts) end)

      assert Task.yield(ingest, 300) == nil

      send(holder.pid, :release)
      Task.await(holder)

      assert {:ok, %{status: :error, transient_attempts: 1}} = Task.await(ingest)
    end
  end

  defp host_pass_run!(name) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{
            "name" => name,
            "version" => "1.4.4",
            "native_components" => %{"nif_language" => nil, "port_languages" => []}
          },
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          package: name,
          version: "1.4.4",
          run_id: "run-#{name}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )
  end

  defp in_backlog?(name) do
    "1.19/28"
    |> Portal.Catalog.toolchain_backlog(1, 1000)
    |> Enum.any?(&(&1.package == name))
  end

  test "a rebuild that no longer passes drops the previous build's memberships" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")

    {:ok, passed} =
      Ingestion.ingest_toolchain(
        pass_result(name, beam, priv),
        opts(name, files_dir_with([beam, priv]))
      )

    {:ok, skipped} =
      Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

    assert passed.id == skipped.id
    assert memberships(skipped) == []
  end

  test "a pass build whose files did not all stage is refused and keeps the previous row" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")

    {:ok, previous} =
      Ingestion.ingest_toolchain(
        pass_result(name, beam, priv),
        opts(name, files_dir_with([beam, priv]), "tc-first")
      )

    new_beam = blob("beam2-#{name}")
    new_priv = blob("priv2-#{name}")
    {missing_sha, _} = new_priv

    assert {:error, {:artifacts_unstaged, [^missing_sha]}} =
             Ingestion.ingest_toolchain(
               pass_result(name, new_beam, new_priv),
               opts(name, files_dir_with([new_beam]), "tc-second")
             )

    assert [row] =
             ToolchainBuild
             |> Ash.Query.filter(package_id == ^previous.package_id)
             |> Ash.read!(domain: @domain)

    assert row.id == previous.id
    assert row.run_id == "tc-first"

    assert Enum.sort([elem(beam, 0), elem(priv, 0)]) ==
             row |> memberships() |> Enum.map(& &1.sha256) |> Enum.sort()
  end

  test "a pass build that fails to stage writes no row" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")

    assert {:error, {:artifacts_unstaged, [_]}} =
             Ingestion.ingest_toolchain(
               pass_result(name, beam, priv),
               opts(name, files_dir_with([beam]))
             )

    refute ToolchainBuild
           |> Ash.Query.filter(package.name == ^name)
           |> Ash.exists?(domain: @domain)
  end

  test "a non-pass build that carries a manifest stores none and no memberships" do
    name = unique_name()
    beam = blob("beam-#{name}")
    priv = blob("priv-#{name}")
    manifest = get_in(pass_result(name, beam, priv), ["toolchain_build", "file_manifest"])
    result = put_in(skipped_result(name), ["toolchain_build", "file_manifest"], manifest)

    assert {:ok, tb} =
             Ingestion.ingest_toolchain(result, opts(name, files_dir_with([beam, priv])))

    assert tb.status == :skipped
    assert tb.file_manifest == nil
    assert memberships(tb) == []
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
        "package" => name,
        "version" => "1.4.4",
        "toolchain" => "1.19/28",
        "builder_version" => 1
      }

      assert :ok = Ingest.perform(%Oban.Job{args: args, attempt: 1, max_attempts: 5})

      assert [tb] =
               ToolchainBuild
               |> Ash.Query.filter(package_id == ^pkg.id)
               |> Ash.read!(domain: @domain)

      assert tb.run_id == "tc-worker"
      assert tb.version == "1.4.4"
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

  describe "compile-time trace fields (P1)" do
    test "are stored as the worker reported them" do
      name = unique_name()
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      result =
        name
        |> pass_result(beam, priv)
        |> update_in(["toolchain_build"], fn build ->
          Map.merge(build, %{
            "portability_rule" => 1,
            "rule1_reason" => nil,
            "compile_observations" => %{"trace_stats" => %{"windows" => 3}, "taint" => %{}}
          })
        end)

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(result, opts(name, files_dir_with([beam, priv])))

      assert tb.portability_rule == 1
      assert tb.rule1_reason == nil
      assert tb.compile_observations == %{"trace_stats" => %{"windows" => 3}, "taint" => %{}}
    end

    test "a skipped build keeps both reasons" do
      name = unique_name()

      result =
        name
        |> skipped_result()
        |> update_in(["toolchain_build"], fn build ->
          Map.merge(build, %{
            "reason" => "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)",
            "portability_rule" => 1,
            "rule1_reason" => "calls System.cmd/2",
            "compile_observations" => %{"refusals" => []}
          })
        end)

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert tb.reason =~ "compile-time host read"
      assert tb.rule1_reason == "calls System.cmd/2"
    end

    test "builds from before the trace store nils, and oversized observations a marker" do
      name = unique_name()

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

      assert {tb.portability_rule, tb.rule1_reason, tb.compile_observations} == {nil, nil, nil}

      big = %{
        "config_reads" =>
          for(i <- 1..20_000, do: %{"key" => "k#{i}", "pad" => String.duplicate("x", 20)})
      }

      other = unique_name()

      result =
        update_in(
          skipped_result(other),
          ["toolchain_build"],
          &Map.put(&1, "compile_observations", big)
        )

      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(other, files_dir_with([])))
      assert tb.compile_observations == %{"truncated" => true}
    end
  end

  describe "the R5 mark" do
    defp with_rule(result, rule, compile_env \\ nil) do
      update_in(result, ["toolchain_build"], fn build ->
        build
        |> Map.put("compile_env_rule", rule)
        |> then(&if(compile_env, do: Map.put(&1, "compile_env", compile_env), else: &1))
      end)
    end

    test "is stored with a valid compile_env" do
      name = unique_name()
      beam = blob("beam-#{name}")
      priv = blob("priv-#{name}")

      result = name |> pass_result(beam, priv) |> with_rule(1)

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(result, opts(name, files_dir_with([beam, priv])))

      assert tb.compile_env_rule == 1
      assert tb.transient_attempts == 0
    end

    test "is dropped when the compile_env is malformed or the rule is not a small integer" do
      name = unique_name()
      result = name |> skipped_result() |> with_rule(1, [%{"app" => 1}])
      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert {tb.compile_env, tb.compile_env_rule} == {nil, nil}

      other = unique_name()
      result = other |> skipped_result() |> with_rule("1")
      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(other, files_dir_with([])))
      assert tb.compile_env_rule == nil
    end

    test "is absent for builds that do not report it" do
      name = unique_name()

      assert {:ok, tb} =
               Ingestion.ingest_toolchain(skipped_result(name), opts(name, files_dir_with([])))

      assert tb.compile_env_rule == nil
    end

    test "a null mark is stored as nil, never inferred" do
      name = unique_name()
      result = name |> skipped_result() |> with_rule(nil)
      assert {:ok, tb} = Ingestion.ingest_toolchain(result, opts(name, files_dir_with([])))
      assert tb.compile_env_rule == nil
      assert tb.revoked_reason == nil
    end

    test "the fixture passes it through" do
      tb =
        Portal.PrecompiledFixtures.ingest_toolchain_build(unique_name(), "1.0.0",
          compile_env_rule: 1
        )

      assert tb.compile_env_rule == 1

      assert Portal.PrecompiledFixtures.ingest_toolchain_build(unique_name(), "1.0.0").compile_env_rule ==
               nil
    end
  end

  describe "transient attempts and the revocation reason" do
    test "the cap and the reason are fixed values" do
      assert ToolchainBuild.transient_cap() == 5
      assert ToolchainBuild.withheld_revocation() == "withheld closure"
    end

    test ":retried_transient counts the attempt and stamps it" do
      tb = Portal.PrecompiledFixtures.ingest_toolchain_build(unique_name(), "1.0.0")
      assert tb.attempted_at == nil

      tb =
        tb
        |> Ash.Changeset.for_update(:retried_transient, %{transient_attempts: 2})
        |> Ash.update!(domain: @domain)

      assert tb.transient_attempts == 2
      assert %DateTime{} = tb.attempted_at
    end

    test "a rebuild resets the transient attempts" do
      name = unique_name()
      tb = Portal.PrecompiledFixtures.ingest_toolchain_build(name, "1.0.0")

      tb
      |> Ash.Changeset.for_update(:retried_transient, %{transient_attempts: 3})
      |> Ash.update!(domain: @domain)

      assert Portal.PrecompiledFixtures.ingest_toolchain_build(name, "1.0.0").transient_attempts ==
               0
    end

    test ":mark_withheld_revoked records the reason, :unrevoke_rebuilt clears it and the revocation" do
      tb =
        unique_name()
        |> Portal.PrecompiledFixtures.ingest_toolchain_build("1.0.0")
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update!(domain: @domain)
        |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
        |> Ash.update!(domain: @domain)

      assert %DateTime{} = tb.revoked_at
      assert tb.revoked_reason == ToolchainBuild.withheld_revocation()

      tb = tb |> Ash.Changeset.for_update(:unrevoke_rebuilt, %{}) |> Ash.update!(domain: @domain)
      assert {tb.revoked_at, tb.revoked_reason} == {nil, nil}
    end

    test ":mark_withheld_revoked leaves a row that is not revoked alone" do
      tb = Portal.PrecompiledFixtures.ingest_toolchain_build(unique_name(), "1.0.0")

      assert {:error, %Ash.Error.Invalid{errors: errors}} =
               tb
               |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
               |> Ash.update(domain: @domain)

      assert Enum.any?(errors, &match?(%Ash.Error.Changes.StaleRecord{}, &1))
      assert Ash.get!(ToolchainBuild, tb.id, domain: @domain).revoked_reason == nil
    end

    test ":unrevoke_rebuilt leaves a row revoked for another reason revoked" do
      tb =
        unique_name()
        |> Portal.PrecompiledFixtures.ingest_toolchain_build("1.0.0")
        |> Ash.Changeset.for_update(:revoke, %{})
        |> Ash.update!(domain: @domain)

      assert {:error, %Ash.Error.Invalid{}} =
               tb
               |> Ash.Changeset.for_update(:unrevoke_rebuilt, %{})
               |> Ash.update(domain: @domain)

      assert %DateTime{} = Ash.get!(ToolchainBuild, tb.id, domain: @domain).revoked_at
    end

    test "a rebuild keeps the revocation reason" do
      name = unique_name()

      name
      |> Portal.PrecompiledFixtures.ingest_toolchain_build("1.0.0")
      |> Ash.Changeset.for_update(:revoke, %{})
      |> Ash.update!(domain: @domain)
      |> Ash.Changeset.for_update(:mark_withheld_revoked, %{})
      |> Ash.update!(domain: @domain)

      tb = Portal.PrecompiledFixtures.ingest_toolchain_build(name, "1.0.0")
      assert %DateTime{} = tb.revoked_at
      assert tb.revoked_reason == "withheld closure"
    end
  end
end
