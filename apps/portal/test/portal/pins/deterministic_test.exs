defmodule Portal.Pins.DeterministicTest do
  # `Portal.Pins.from_lock/2`'s `deterministic: true`: while the
  # `deterministic_builds_enabled` setting is on, a closure counts as served
  # only when the format-2 manifest lists a deterministic sibling of it, and
  # one served without is queued as a pinned build (`no_sibling`), once.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  import Portal.PinnedFixtures, only: [entry: 2, files: 1, tmp: 1]

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, PinnedBuild}
  alias Portal.Repo

  defmodule FakeHex do
    # The signed registry: each release at the checksum the lock names.
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

  defp lock(extra \\ "") do
    "%{\n" <>
      extra <>
      hex("jason", "1.4.4", "c", [{"decimal", "~> 2.0", true}]) <>
      hex("decimal", "2.3.0", "b") <> "}\n"
  end

  # A native set on the lock's one Nerves system (phase 2).
  defp native_lock do
    lock(
      hex("nif", "1.0.0", "1", [{"elixir_make", "~> 0.6", false}], "[:make, :mix]") <>
        hex("elixir_make", "0.8.4", "2") <>
        hex("nerves", "1.11.0", "3") <>
        hex("nerves_system_rpi4", "2.1.2", "9", [
          {"nerves", "~> 1.11 or ~> 2.0 or ~> 2.0.0-dev", false}
        ]) <>
        hex("nerves_system_br", "1.35.3", "8")
    )
  end

  defp run(opts \\ []),
    do: Portal.Pins.from_lock(Keyword.get(opts, :lock, lock()), [hex: FakeHex] ++ opts)

  defp reasons(report), do: Map.new(report.skipped, &{&1.package, &1.reason})
  defp queued(report), do: Map.new(report.queue, &{&1.package, &1})

  defp set(package, lock \\ lock()) do
    {sets, _refused} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock), 1))
    Enum.find(sets, &(&1.package == package))
  end

  defp setting(on?), do: {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: on?})

  defp lock_of(set), do: Compatibility.Pins.to_lock(set.pins["deps"])

  defp package!(name) do
    case Catalog.Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog) do
      nil ->
        Catalog.Package
        |> Ash.Changeset.for_create(:create, %{name: name})
        |> Ash.create!(domain: Catalog)

      package ->
        package
    end
  end

  # A passing toolchain build of the set's closure, as `@served_sql` reads
  # one: no files, so no manifest lists it, nor any sibling of it. Its own
  # variant, so an ingested build of the package is another row.
  defp served!(set) do
    Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package!(set.package).id,
      version: set.version,
      toolchain: "1.20/29",
      builder_version: 1,
      variant: :without,
      config_variant: "default",
      status: :pass,
      deps_lock: lock_of(set)
    })
    |> Ash.create!(domain: Catalog)
  end

  # An Erlang module holding `?FILE`, compiled without and with the option:
  # a real sibling pair.
  defp beams(tag) do
    path = Path.join(tmp("pd-src"), "m0.erl")
    File.write!(path, "-module(m0).\n-export([f/0]).\nf() -> {?FILE, #{inspect(tag)}}.\n")
    {erl(path, []), erl(path, [:deterministic])}
  end

  defp erl(path, opts) do
    {:ok, _, beam} = :compile.file(String.to_charlist(path), [:binary, :debug_info | opts])
    beam
  end

  defp manifest(beam), do: %{"ebin" => [entry("ebin/m0.beam", beam)], "priv" => []}

  # The `toolchain_build` of a passing run of `set` on "1.20/29" whose files
  # are `beam`.
  defp toolchain_build(set, beam) do
    %{
      "status" => "pass",
      "reason" => nil,
      "elixir" => "1.20.5",
      "otp" => "29",
      "deps_lock" => lock_of(set),
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
  end

  defp sibling(build, det),
    do:
      Map.merge(build, %{
        "erl_compiler_options" => ["deterministic"],
        "file_manifest" => manifest(det)
      })

  # A toolchain build of the set's closure, ingested with its deterministic
  # sibling: the manifest lists both.
  defp served_with_sibling!(set) do
    {normal, det} = beams(set.package)
    build = toolchain_build(set, normal)

    result = %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-19T10:00:00Z",
      "package" => %{"name" => set.package, "version" => set.version},
      "systems" => %{},
      "toolchain_build" => build,
      "deterministic_build" => sibling(build, det)
    }

    {:ok, tb} =
      Ingestion.ingest_toolchain(result, %{
        package: set.package,
        version: set.version,
        run_id: "pd-#{System.unique_integer([:positive])}",
        image_digest: "sha256:pd",
        files_dir: files([normal, det]),
        output_dir: tmp("pd-out"),
        toolchain: "1.20/29",
        builder_version: Portal.Toolchains.builder_version()
      })

    tb
  end

  # The set's pinned build on the toolchain path, ingested as its job's
  # ingest would: `sibling:` `:pass` brings a sibling that holds,
  # `:skipped` one the worker could not build, `nil` none (a run that was
  # not asked for one).
  defp pinned!(set, opts \\ []) do
    {normal, det} = beams(set.package <> "-pinned")
    build = toolchain_build(set, normal)

    result =
      %{
        "scope" => "toolchain",
        "finished_at" => "2026-11-19T11:00:00Z",
        "package" => %{"name" => set.package, "version" => set.version},
        "systems" => %{},
        "requested_optional_deps" => "pinned",
        "optional_deps" => %{
          "added" => [],
          "dropped" => [],
          "skipped" => [],
          "reason" => "pinned"
        },
        "pins" => %{"hash" => set.pins["hash"], "status" => "reproduced"},
        "toolchain_build" => build
      }
      |> put_sibling(Keyword.get(opts, :sibling), build, det)

    {:ok, row} =
      Ingestion.ingest_pinned(result, %{
        package: set.package,
        version: set.version,
        pin_hash: set.pins["hash"],
        pins: set.pins,
        target: "pure_elixir",
        run_id: "pd-#{System.unique_integer([:positive])}",
        image_digest: "sha256:pd",
        files_dir: files([normal, det]),
        output_dir: tmp("pd-out"),
        toolchain: "1.20/29",
        builder_version: Portal.Toolchains.builder_version()
      })

    row
  end

  defp put_sibling(result, nil, _build, _det), do: result

  defp put_sibling(result, :pass, build, det),
    do: Map.put(result, "deterministic_build", sibling(build, det))

  defp put_sibling(result, :skipped, _build, _det),
    do:
      Map.put(result, "deterministic_build", %{"status" => "skipped", "reason" => "did not hold"})

  defp deterministic_listed(name, version) do
    case Catalog.precompiled_manifest_v2(name) do
      %{"versions" => %{^version => %{"deterministic" => lists}}} -> lists
      _ -> nil
    end
  end

  describe "the option off, or the setting off" do
    test "changes nothing: a closure served without a sibling is served" do
      setting(true)
      served!(set("jason"))

      assert {:ok, report} = run()
      assert reasons(report)["jason"] == "served"
      refute Map.has_key?(report, :deterministic)
      refute Map.has_key?(report.counts, "no_sibling")
      refute Enum.any?(report.queue, &Map.has_key?(&1, :no_sibling))

      assert {:ok, ^report} = run(deterministic: false)
    end

    test "with the setting off, the option holds nothing to siblings" do
      setting(false)
      served!(set("jason"))

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert reasons(report)["jason"] == "served"
      assert report.deterministic == false
      assert report.counts["no_sibling"] == 0
      assert Enum.map(report.queue, &{&1.package, &1.no_sibling}) == [{"decimal", false}]
    end

    test "an option that is not a boolean is refused" do
      for value <- [nil, "true", 1] do
        assert {:error, {:invalid_deterministic, ^value}} = run(deterministic: value)
      end
    end
  end

  describe "with the setting on" do
    setup do
      setting(true)
      :ok
    end

    test "a closure served without a sibling is queued, counted as no_sibling" do
      served!(set("jason"))

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert report.deterministic == true
      assert %{"jason" => %{no_sibling: true}, "decimal" => %{no_sibling: false}} = queued(report)
      assert report.counts["no_sibling"] == 1
      assert report.counts["queue"] == 2

      assert [%{args: %{"pin_hash" => hash}}] =
               all_enqueued(worker: Portal.Workers.PinnedBuild, args: %{"package" => "jason"})

      assert hash == set("jason").pins["hash"]

      # The usual dedupe: its job is still queued.
      assert {:ok, again} = run(deterministic: true, dry_run: false)
      assert reasons(again)["jason"] == "queued_dup"
      assert again.counts["no_sibling"] == 0
    end

    test "a closure served with a listed sibling is served" do
      jason = set("jason")
      served_with_sibling!(jason)
      assert %{"builds" => [_]} = deterministic_listed("jason", "1.4.4")

      assert {:ok, report} = run(deterministic: true)
      assert reasons(report)["jason"] == "served"
      assert report.counts["no_sibling"] == 0
    end

    # A revoked sibling is never built again, not as a pinned build's either.
    test "a closure whose served sibling was revoked is not queued" do
      jason = set("jason")
      served_with_sibling!(jason)

      assert {:revoked, 1, _rows, _at} =
               Portal.Precompiled.DeterministicRevocation.revoke(package: "jason", dry_run: false)

      assert deterministic_listed("jason", "1.4.4") == nil

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert reasons(report)["jason"] == "sibling_revoked"
      assert report.counts["no_sibling"] == 0
      assert all_enqueued(worker: Portal.Workers.PinnedBuild, args: %{"package" => "jason"}) == []
    end

    test "a sibling of another closure serves nothing here" do
      jason = set("jason")
      other = %{jason | pins: %{jason.pins | "deps" => []}}
      served_with_sibling!(other)
      served!(jason)

      assert {:ok, report} = run(deterministic: true)
      assert %{no_sibling: true} = queued(report)["jason"]
    end

    # The judged check: the key's own pinned build row would block a
    # re-queue. A served pass whose run never tried for a sibling is let
    # through once; its rebuild records the attempt, held or not.
    test "a pinned pass built before siblings is queued again once, then judged" do
      jason = set("jason")
      row = pinned!(jason)
      refute row.sibling_attempted

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert %{no_sibling: true} = queued(report)["jason"]
      assert report.counts["no_sibling"] == 1

      # The job ran: its rebuild was asked for a sibling and got none.
      Repo.delete_all(Oban.Job)
      assert %PinnedBuild{id: id, sibling_attempted: true} = pinned!(jason, sibling: :skipped)
      assert id == row.id

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert reasons(report)["jason"] == "judged"
      assert report.counts["no_sibling"] == 0
      assert all_enqueued(worker: Portal.Workers.PinnedBuild, args: %{"package" => "jason"}) == []
    end

    test "a pinned build with a listed sibling is judged" do
      jason = set("jason")
      row = pinned!(jason, sibling: :pass)
      assert %{"builds_closure" => [_]} = deterministic_listed("jason", "1.4.4")

      # Even a row written before the attempt was recorded.
      Repo.query!("UPDATE catalog_pinned_builds SET sibling_attempted = false WHERE id = $1", [
        Ecto.UUID.dump!(row.id)
      ])

      assert {:ok, report} = run(deterministic: true)
      assert reasons(report)["jason"] == "judged"
    end

    test "a closure served by a toolchain build is queued once, then judged by its pinned row" do
      jason = set("jason")
      served!(jason)

      assert {:ok, %{queue: [_, _]}} = run(deterministic: true, dry_run: false)
      Repo.delete_all(Oban.Job)
      pinned!(jason, sibling: :skipped)

      assert {:ok, report} = run(deterministic: true, dry_run: false)
      assert reasons(report)["jason"] == "judged"
      assert report.counts["no_sibling"] == 0
    end

    test "a pinned build that is no served pass is judged" do
      jason = set("jason")
      served!(jason)
      row = pinned!(jason)

      for change <- [
            "status = 'fail'",
            "status = 'skipped'",
            "status = 'pass', revoked_at = now()",
            "revoked_at = NULL, unpublished_at = now()"
          ] do
        Repo.query!("UPDATE catalog_pinned_builds SET #{change} WHERE id = $1", [
          Ecto.UUID.dump!(row.id)
        ])

        assert {:ok, report} = run(deterministic: true)
        assert reasons(report)["jason"] == "judged", change
      end
    end
  end

  # dc8bf1d5's selection: a firmware target's sibling is served only beside
  # the build that won its key in the manifest.
  describe "on the firmware path, with the setting on" do
    @r2_pass %{"status" => "pass", "reason" => nil, "observations" => []}

    setup do
      setting(true)

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

    # A firmware run of `set` whose rpi4 2.1.2 target passed with `beam`, and
    # with `det` as its sibling unless that is nil.
    defp firmware_run!(set, beam, det, finished_at) do
      sibling =
        det &&
          %{
            "status" => "pass",
            "reason" => nil,
            "erl_compiler_options" => ["deterministic"],
            "judge_revision" => 29,
            "file_manifest" => manifest(det),
            "build_root" => @r2_pass
          }

      rpi4 = %{
        "status" => "pass",
        "duration_sec" => 90.0,
        "firmware_size_bytes" => 1_000,
        "log_tail" => "built",
        "system_version" => "2.1.2",
        "compile_env" => [],
        "error" => nil,
        "beam_scan" => %{"footprint" => %{"file_manifest" => manifest(beam)}},
        "build_root" => @r2_pass,
        "deterministic_build" => sibling
      }

      result = %{
        "run_id" => "pd-#{System.unique_integer([:positive])}",
        "scope" => "full",
        "finished_at" => finished_at,
        "package" => %{"name" => set.package, "version" => set.version},
        "image" => %{"name" => "ncc-worker:local", "digest" => "sha256:pd"},
        "toolchain" => %{"elixir" => "1.20.5", "erlang" => "29", "mix" => "1.20.5"},
        "deps_lock" => lock_of(set),
        "package_checksum" => set.pins["package_checksum"],
        "declared" => [],
        "systems" => %{
          "host" => %{"status" => "pass", "duration_sec" => 5.0, "log_tail" => "ok"},
          "nerves_system_rpi4" => rpi4
        }
      }

      {:ok, run} =
        Ingestion.ingest(result, %{
          package: set.package,
          version: set.version,
          run_id: result["run_id"],
          image_digest: "sha256:pd",
          files_dir: files(Enum.reject([beam, det], &is_nil/1)),
          scan_request_id: nil,
          log: "log"
        })

      run
    end

    test "a target served with its sibling is served; a newer build of its key without one queues it" do
      nif = set("nif", native_lock())
      {normal, det} = beams("nif")
      firmware_run!(nif, normal, det, "2026-11-19T12:00:00Z")
      assert %{"builds" => [listed]} = deterministic_listed("nif", "1.0.0")
      assert listed["target"] == "nerves_system_rpi4"

      assert {:ok, report} = run(lock: native_lock(), deterministic: true)
      assert reasons(report)["nif"] == "served"

      # A newer run of the same version, target, toolchain, release and lock
      # that brought no sibling takes the key, and the sibling with it.
      {newer, _det} = beams("nif-newer")
      firmware_run!(nif, newer, nil, "2026-11-20T12:00:00Z")
      assert deterministic_listed("nif", "1.0.0") == nil

      assert {:ok, report} = run(lock: native_lock(), deterministic: true, dry_run: false)
      assert %{no_sibling: true, target: "nerves_system_rpi4"} = queued(report)["nif"]

      assert [%{queue: "builds"}] =
               all_enqueued(worker: Portal.Workers.PinnedBuild, args: %{"package" => "nif"})

      # Without the option the same closure is served, as before.
      assert {:ok, report} = run(lock: native_lock())
      assert reasons(report)["nif"] == "served"
    end

    test "a target whose served sibling was revoked is not queued" do
      nif = set("nif", native_lock())
      {normal, det} = beams("nif")
      firmware_run!(nif, normal, det, "2026-11-19T12:00:00Z")

      assert {:revoked, 1, _rows, _at} =
               Portal.Precompiled.DeterministicRevocation.revoke(package: "nif", dry_run: false)

      assert {:ok, report} = run(lock: native_lock(), deterministic: true, dry_run: false)
      assert reasons(report)["nif"] == "sibling_revoked"
      assert all_enqueued(worker: Portal.Workers.PinnedBuild, args: %{"package" => "nif"}) == []
    end
  end
end
