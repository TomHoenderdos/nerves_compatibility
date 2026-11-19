defmodule Portal.Pins.BackfillTest do
  # A sibling backfill (`Portal.Pins.from_lock/2`, `deterministic: true`): the
  # rebuild of a served pinned pass that has no deterministic sibling replaces
  # that pass only with a pass whose sibling held. Any other outcome leaves the
  # served row, its files, memberships and status as they were and only
  # records the attempt, so the next call queues nothing. Driven through the
  # real `PinnedBuild` and `Ingest` workers on a stub builder.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  import Portal.PinnedFixtures, only: [entry: 2, files: 1, tmp: 1]

  alias Portal.Catalog
  alias Portal.Catalog.{ArtifactMembership, DeterministicBuild, Ingestion, PinnedBuild}
  alias Portal.Repo
  alias Portal.Workers.Ingest
  alias Portal.Workers.PinnedBuild, as: PinnedBuildWorker

  @r2_pass %{"status" => "pass", "reason" => nil, "observations" => []}

  defmodule StubBuilder do
    # The build the test put in the process dictionary, and its scratch dir
    # replayed to the ingest.
    def build(_args, _opts \\ []), do: Process.get(:stub_build)
    def cleanup(_run_id), do: :ok
    def image_digest(_image), do: "sha256:stub"
    def load_run(_run_id), do: {:ok, Process.get(:stub_run)}
  end

  defmodule FakeHex do
    def releases(name, _opts) do
      {:ok,
       [
         %{
           version: Process.get({:fake_version, name}),
           outer_checksum: Process.get({:fake_sum, name}),
           retired_reason: nil
         }
       ]}
    end
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})

    {:ok, _} =
      Catalog.SystemAbi.observe(%{
        system_pkg: "nerves_system_rpi4",
        version: "2.1.2",
        source: "lock",
        otp: "29.0.6",
        toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
        toolchain_version: "15.3.1"
      })

    :ok
  end

  defp sum(char), do: String.duplicate(char, 64)

  defp hex(app, version, char, deps \\ [], managers \\ "[:mix]") do
    Process.put({:fake_version, app}, version)
    Process.put({:fake_sum, app}, sum(char))

    edges =
      Enum.map_join(deps, ", ", fn {dep, req, optional} ->
        ~s|{:#{dep}, "#{req}", [hex: :#{dep}, repo: "hexpm", optional: #{optional}]}|
      end)

    ~s|  "#{app}": {:hex, :#{app}, "#{version}", "inner", #{managers}, [#{edges}], "hexpm", "#{sum(char)}"},\n|
  end

  # jason a pure set, nif a native one on the lock's rpi4 2.1.2.
  defp lock do
    "%{\n" <>
      hex("jason", "1.4.4", "c", [{"decimal", "~> 2.0", true}]) <>
      hex("decimal", "2.3.0", "b") <>
      hex("nif", "1.0.0", "1", [{"elixir_make", "~> 0.6", false}], "[:make, :mix]") <>
      hex("elixir_make", "0.8.4", "2") <>
      hex("nerves", "1.11.0", "3") <>
      hex("nerves_system_rpi4", "2.1.2", "9", [{"nerves", "~> 1.0", false}]) <>
      hex("nerves_system_br", "1.35.3", "8") <> "}\n"
  end

  defp run(opts),
    do: Portal.Pins.from_lock(lock(), [hex: FakeHex, deterministic: true] ++ opts)

  defp reasons(report), do: Map.new(report.skipped, &{&1.package, &1.reason})

  defp set(package) do
    {sets, _refused} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock()), 1))
    Enum.find(sets, &(&1.package == package))
  end

  defp lock_of(set), do: Compatibility.Pins.to_lock(set.pins["deps"])

  # An Erlang module holding `?FILE`, compiled without and with the option.
  defp beams(tag) do
    path = Path.join(tmp("pb-src"), "m0.erl")
    File.write!(path, "-module(m0).\n-export([f/0]).\nf() -> {?FILE, #{inspect(tag)}}.\n")
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  defp manifest(beam), do: %{"ebin" => [entry("ebin/m0.beam", beam)], "priv" => []}

  defp sibling(:toolchain, build, det),
    do:
      Map.merge(build, %{
        "erl_compiler_options" => ["deterministic"],
        "file_manifest" => manifest(det)
      })

  defp sibling(:firmware, _build, det),
    do: %{
      "status" => "pass",
      "reason" => nil,
      "erl_compiler_options" => ["deterministic"],
      "judge_revision" => 29,
      "file_manifest" => manifest(det),
      "build_root" => @r2_pass
    }

  @refused %{"status" => "skipped", "reason" => "its compile failed"}

  defp sibling_for(nil, _make), do: nil
  defp sibling_for(:refused, _make), do: @refused
  defp sibling_for(:pass, make), do: make.()

  defp put_present(map, _key, nil), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)

  # A pinned toolchain run of `set` (the "1.20/29" toolchain from_lock
  # builds on) whose files are `beam`; `opts`: `status`, `reason`, `lock`,
  # `sibling` (`:pass`, `:refused` or nil).
  defp toolchain_result(set, {beam, det}, opts) do
    build = %{
      "status" => Keyword.get(opts, :status, "pass"),
      "reason" => Keyword.get(opts, :reason),
      "elixir" => "1.20.5",
      "otp" => "29",
      "deps_lock" => Keyword.get(opts, :lock, lock_of(set)),
      "package_checksum" => set.pins["package_checksum"],
      "declared" => [],
      "manager" => "rebar3",
      "compile_env" => [],
      "compile_env_rule" => 1,
      "compile_inputs" => [],
      "built_priv" => [],
      "portability_rule" => 2,
      "judge_revision" => 29,
      "file_manifest" => manifest(beam)
    }

    %{
      "scope" => "toolchain",
      "finished_at" => Keyword.get(opts, :finished_at, "2026-11-19T10:00:00Z"),
      "package" => %{"name" => set.package, "version" => set.version},
      "systems" => %{},
      "requested_optional_deps" => "pinned",
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => "pinned"},
      "pins" => %{"hash" => set.pins["hash"], "status" => "reproduced"},
      "toolchain_build" => build
    }
    |> put_present(
      "deterministic_build",
      sibling_for(opts[:sibling], fn -> sibling(:toolchain, build, det) end)
    )
  end

  # A pinned firmware run of `set`'s one target, rpi4 2.1.2; `opts`:
  # `status`, `build_root`, `otp`, `sibling`.
  defp firmware_result(set, {beam, det}, opts) do
    build_root = Keyword.get(opts, :build_root, @r2_pass)
    withheld? = build_root["status"] == "skipped"

    rpi4 =
      %{
        "status" => Keyword.get(opts, :status, "pass"),
        "duration_sec" => 90.0,
        "firmware_size_bytes" => 1_000,
        "log_tail" => "built",
        "system_version" => "2.1.2",
        "compile_env" => [],
        "compile_inputs" => [],
        "otp_full" => "29.0.6",
        "error" => Keyword.get(opts, :error),
        "beam_scan" => %{
          "footprint" => %{"file_manifest" => if(withheld?, do: nil, else: manifest(beam))}
        },
        "build_root" => build_root
      }
      |> put_present(
        "deterministic_build",
        sibling_for(opts[:sibling], fn -> sibling(:firmware, nil, det) end)
      )

    %{
      "scope" => "targets",
      "finished_at" => Keyword.get(opts, :finished_at, "2026-11-19T11:00:00Z"),
      "package" => %{"name" => set.package, "version" => set.version},
      "toolchain" => %{"elixir" => "1.20.5", "erlang" => Keyword.get(opts, :otp, "29")},
      "systems" => %{"host" => %{"status" => "pass"}, "nerves_system_rpi4" => rpi4},
      "deps_lock" => lock_of(set),
      "package_checksum" => set.pins["package_checksum"],
      "declared" => [],
      "requested_optional_deps" => "pinned",
      "optional_deps" => %{"added" => [], "dropped" => [], "skipped" => [], "reason" => "pinned"},
      "pins" => %{"hash" => set.pins["hash"], "status" => "reproduced"}
    }
  end

  defp result(:toolchain, set, beams, opts), do: toolchain_result(set, beams, opts)
  defp result(:firmware, set, beams, opts), do: firmware_result(set, beams, opts)

  defp package_of(:toolchain), do: "jason"
  defp package_of(:firmware), do: "nif"

  defp key(:toolchain), do: %{target: "pure_elixir", system_version: ""}
  defp key(:firmware), do: %{target: "nerves_system_rpi4", system_version: "2.1.2"}

  # The served pinned pass of the path's set, built before siblings: no
  # sibling, no attempt recorded.
  defp served_pass!(path) do
    set = set(package_of(path))
    {normal, _det} = beams = beams(set.package <> "-first")

    {:ok, row} =
      Ingestion.ingest_pinned(
        result(path, set, beams, []),
        Map.merge(
          %{
            package: set.package,
            version: set.version,
            pin_hash: set.pins["hash"],
            pins: set.pins,
            run_id: "pb-first-#{System.unique_integer([:positive])}",
            image_digest: "sha256:first",
            files_dir: files([normal]),
            output_dir: tmp("pb-out"),
            toolchain: "1.20/29",
            builder_version: Portal.Toolchains.builder_version()
          },
          key(path)
        )
      )

    assert %PinnedBuild{status: :pass, sibling_attempted: false} = row
    {set, row}
  end

  # from_lock queues the pass's rebuild for its sibling alone.
  defp backfill!(set) do
    assert {:ok, report} = run(dry_run: false)
    assert [%{no_sibling: true}] = Enum.filter(report.queue, &(&1.package == set.package))

    assert [%Oban.Job{args: %{"sibling_backfill" => true}} = job] =
             all_enqueued(worker: PinnedBuildWorker, args: %{"package" => set.package})

    job
  end

  # The backfill job run on the stub builder: `{:ingest, result, blobs}` is a
  # written result its ingest job then reads, `{:exit, code}` a run with no
  # result, on the job's last attempt.
  defp rebuild!(job, {:ingest, result, blobs}) do
    dir = files(blobs)
    out = %{exit_code: 0, result: result, files_dir: dir, output_dir: dir, log: ""}
    Process.put(:stub_build, {:ok, out})
    Process.put(:stub_run, %{result: result, files_dir: dir, output_dir: dir})

    assert :ok = perform_job(PinnedBuildWorker, job.args, queue: job.queue)

    assert [%Oban.Job{args: ingest_args, queue: queue}] = all_enqueued(worker: Ingest)
    assert ingest_args["sibling_backfill"] == true
    assert :ok = perform_job(Ingest, ingest_args, queue: queue)
  end

  defp rebuild!(job, {:exit, code}) do
    out = %{exit_code: code, result: nil, files_dir: "/scratch", output_dir: "/scratch", log: ""}
    Process.put(:stub_build, {:ok, out})

    assert {:error, _} =
             perform_job(PinnedBuildWorker, job.args, queue: job.queue, attempt: 2)
  end

  # Every job the backfill left behind ran: the next call sees no queued one.
  defp done!, do: Repo.delete_all(Oban.Job)

  defp row(row), do: Ash.get!(PinnedBuild, row.id, domain: Catalog)

  defp shas(row) do
    ArtifactMembership
    |> Ash.Query.filter(pinned_build_id == ^row.id)
    |> Ash.read!(domain: Catalog)
    |> Enum.map(& &1.sha256)
    |> Enum.sort()
  end

  defp siblings(row) do
    DeterministicBuild
    |> Ash.Query.filter(pinned_build_id == ^row.id)
    |> Ash.read!(domain: Catalog)
  end

  # What a backfill must never touch on a row it does not replace.
  @kept ~w(id status reason run_id image_digest file_manifest deps_lock finished_at
           attempted_at revoked_at unpublished_at elixir otp judge_revision compile_env)a

  defp snapshot(row), do: {Map.take(row(row), @kept), shas(row), siblings(row)}

  # A closure a regular build serves without a sibling has no pinned row to
  # keep: its backfill writes the rebuild's verdict, here an error, with the
  # attempt, which holds the closure as judged.
  test "a backfill of a closure no pinned row serves that errors is not queued again" do
    set = set("jason")

    Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: Ingestion.ensure_package_id("jason") |> elem(1),
      version: set.version,
      toolchain: "1.20/29",
      builder_version: 1,
      variant: :with,
      config_variant: "default",
      status: :pass,
      deps_lock: lock_of(set)
    })
    |> Ash.create!(domain: Catalog)

    job = backfill!(set)
    rebuild!(job, {:exit, 10})

    assert [%PinnedBuild{status: :error, sibling_attempted: true}] =
             PinnedBuild
             |> Ash.Query.filter(package.name == "jason")
             |> Ash.read!(domain: Catalog)

    done!()
    assert {:ok, report} = run(dry_run: false)
    assert reasons(report)["jason"] == "judged"
    assert report.counts["no_sibling"] == 0
    assert all_enqueued(worker: PinnedBuildWorker, args: %{"package" => "jason"}) == []
  end

  # Each outcome that is not a pass with its sibling, on each path.
  defp outcomes(path, set) do
    other = beams(set.package <> "-rebuilt")
    {normal, _det} = other

    ingest = fn opts -> {:ingest, result(path, set, other, opts), [normal]} end

    common = [
      {"errors (exit 10, last attempt)", {:exit, 10}},
      {"passes with its sibling refused", ingest.(sibling: :refused)},
      {"passes without a sibling", ingest.([])}
    ]

    common ++ path_outcomes(path, set, ingest)
  end

  defp path_outcomes(:toolchain, _set, ingest) do
    [
      {"fails",
       ingest.(status: "error", reason: "processes survived the sweep: 1", sibling: :refused)},
      {"is skipped (not the set)",
       ingest.(lock: %{"decimal" => %{"version" => "2.2.0", "checksum" => sum("b")}})}
    ]
  end

  defp path_outcomes(:firmware, _set, ingest) do
    [
      {"fails", ingest.(status: "fail", error: "boom")},
      {"is skipped (R2 withheld its files)",
       ingest.(
         build_root: %{"status" => "skipped", "reason" => "a build path", "observations" => []}
       )},
      {"errors (another toolchain)", ingest.(otp: "30", sibling: :pass)}
    ]
  end

  for path <- [:toolchain, :firmware] do
    test "a #{path} backfill records the attempt when it is queued: a rebuild that never ingests counts" do
      {set, first} = served_pass!(unquote(path))

      assert {:ok, _report} = run(dry_run: true)
      refute row(first).sibling_attempted

      backfill!(set)
      assert row(first).sibling_attempted

      # The job never ran, nor will.
      done!()
      assert {:ok, report} = run(dry_run: false)
      assert reasons(report)[set.package] == "judged"
      assert report.counts["no_sibling"] == 0
      assert all_enqueued(worker: PinnedBuildWorker, args: %{"package" => set.package}) == []
    end

    # Review M1: a pinned pass that owns a sibling row, revoked or not, is no
    # backfill's, even one written before the attempt was recorded.
    test "a #{path} pinned pass whose sibling was revoked is never queued again" do
      path = unquote(path)
      {set, first} = served_pass!(path)
      {normal, det} = beams = beams(set.package <> "-rebuilt")

      rebuild!(
        backfill!(set),
        {:ingest, result(path, set, beams, sibling: :pass, finished_at: "2026-11-20T10:00:00Z"),
         [normal, det]}
      )

      done!()

      assert {:revoked, 1, _rows, _at} =
               Portal.Precompiled.DeterministicRevocation.revoke(
                 package: set.package,
                 dry_run: false
               )

      Repo.query!("UPDATE catalog_pinned_builds SET sibling_attempted = false WHERE id = $1", [
        Ecto.UUID.dump!(first.id)
      ])

      assert {:ok, report} = run(dry_run: false)
      assert reasons(report)[set.package] == "judged"
      assert report.counts["no_sibling"] == 0
      assert all_enqueued(worker: PinnedBuildWorker, args: %{"package" => set.package}) == []
    end

    describe "a served #{path} pinned pass whose backfill rebuild" do
      test "does not pass with its sibling is left as it was, and recorded as attempted" do
        path = unquote(path)
        {set, first} = served_pass!(path)
        before = snapshot(first)

        for {label, outcome} <- outcomes(path, set) do
          Repo.query!(
            "UPDATE catalog_pinned_builds SET sibling_attempted = false WHERE id = $1",
            [
              Ecto.UUID.dump!(first.id)
            ]
          )

          job = backfill!(set)
          rebuild!(job, outcome)

          assert snapshot(first) == before, label
          assert row(first).sibling_attempted, label

          done!()
          assert {:ok, report} = run(dry_run: false)
          assert reasons(report)[set.package] == "judged", label
          assert all_enqueued(worker: PinnedBuildWorker, args: %{"package" => set.package}) == []
        end
      end

      test "passes with its sibling replaces it" do
        path = unquote(path)
        {set, first} = served_pass!(path)
        {normal, det} = beams = beams(set.package <> "-rebuilt")

        job = backfill!(set)

        rebuild!(
          job,
          {:ingest, result(path, set, beams, sibling: :pass, finished_at: "2026-11-20T10:00:00Z"),
           [normal, det]}
        )

        assert %PinnedBuild{status: :pass, sibling_attempted: true} = rebuilt = row(first)
        assert rebuilt.run_id != first.run_id
        assert [%DeterministicBuild{status: :pass, run_id: run_id}] = siblings(first)
        assert run_id == rebuilt.run_id

        assert %{"builds_closure" => [_]} =
                 Catalog.precompiled_manifest_v2(set.package)["versions"][set.version][
                   "deterministic"
                 ]

        done!()
        assert {:ok, report} = run(dry_run: false)
        assert reasons(report)[set.package] == "judged"
      end
    end
  end
end
