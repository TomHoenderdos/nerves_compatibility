defmodule Portal.PinnedFirmwareIngestTest do
  # A pinned firmware build's result.json (lock-driven builds spec, phase 2):
  # only the job's target, only at the job's release, only under the set's
  # own closure, and never a run.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  import Portal.PinnedFixtures

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  @b String.duplicate("b", 64)

  # Replays the build the test put in the process dictionary, as the
  # scratch dir would.
  defmodule StubBuilder do
    def load_run(_run_id), do: {:ok, Process.get(:pinned_build)}
  end

  defp runs(name) do
    Catalog.Run
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Catalog)
  end

  defp row_name(row), do: Ash.get!(Catalog.Package, row.package_id, domain: Catalog).name

  defp package(name) do
    Catalog.Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
  end

  test "a reproduced set on its target and release is a pass with its files and facts" do
    name = unique()
    pins = pins(name)
    assert {:ok, row} = ingest_firmware(name, pins)

    assert row.status == :pass
    assert row.target == "nerves_system_rpi4"
    assert row.system_version == "2.1.2"
    assert row.toolchain == "1.20/29"
    assert row.pin_hash == pins["hash"]
    assert row.deps_lock == Compatibility.Pins.to_lock(pins["deps"])
    assert row.elixir == "1.20.5" and row.otp == "29" and row.otp_full == "29.0.6"
    assert row.toolchain_pkg == "nerves_toolchain_aarch64_nerves_linux_gnu"
    assert row.toolchain_version == "15.3.1"
    assert row.compile_env == [] and row.compile_env_rule == nil
    assert row.native == false and row.elf_needs == %{}
    assert shas(row) == [sha("beam-" <> name)]
  end

  # `Portal.Pins.from_lock/2`'s `deterministic: true` builds a served pass
  # again for its sibling only while its row records no attempt. The worker
  # gives a passing target it could not build one for a `skipped` sibling.
  test "a target that was tried for a sibling records the attempt, held or not" do
    name = unique()
    pins = pins(name)
    assert {:ok, %{status: :pass, sibling_attempted: false}} = ingest_firmware(name, pins)

    result =
      name
      |> firmware_result(pins)
      |> put_in(["systems", "nerves_system_rpi4", "deterministic_build"], %{
        "status" => "skipped",
        "reason" => "run budget exhausted"
      })

    job = firmware_opts(name, pins, files(["beam-" <> name]))
    assert {:ok, %{status: :pass, sibling_attempted: true}} = Ingestion.ingest_pinned(result, job)
  end

  # The bug: R2 (`NccWorker.FirmwareBuildRoot`) withholds a passing target's
  # files but leaves its own `status` at "pass"; only `build_root` says so.
  # Stored as a pass, the row would show as served when nothing of it is.
  test "a target withheld by the baked build path rule (R2) is skipped with the reason and no files" do
    name = unique()
    reason = "bakes the build path: Elixir.Foo string table \"<root>\""

    assert {:ok, row} =
             ingest_firmware(name, pins(name),
               build_root: %{"status" => "skipped", "reason" => reason}
             )

    assert row.status == :skipped
    assert row.reason == reason
    assert row.file_manifest == nil
    assert row.native == nil and row.portable == nil
    assert shas(row) == []
  end

  describe "the firmware judge and the holds (stream S8, review S2)" do
    @refused %{
      "status" => "skipped",
      "reason" => "rebar3 build runs plugins",
      "classes" => ["plugins_hooks"]
    }

    # Review R2, the reviewer's T10: the plugin watch covers a pinned
    # firmware target, as it covers a regular one.
    test "a pinned target that ran an unreviewed plugin release is not served" do
      reviewed = Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Map.keys() |> Enum.sort()

      Portal.Precompiled.PluginWatch.refresh(
        Portal.PrecompiledFixtures.plugin_registry([{"rebar3_hex", reviewed}])
      )

      {version, sha} =
        Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Enum.max_by(&elem(&1, 0))

      hex = %{"name" => "rebar3_hex", "version" => version, "sha256" => sha, "owners" => ["dep"]}

      dirs = %{
        "name" => "rebar3_dirs",
        "version" => "0.1.0",
        "sha256" => String.duplicate("a", 64),
        "owners" => ["dep"]
      }

      served = fn row ->
        row.id in Enum.map(Portal.Pins.Served.served(row.package_id, row_name(row), []), & &1.id)
      end

      clean = unique()
      assert {:ok, ok_row} = ingest_firmware(clean, pins(clean), plugins: [hex])
      assert ok_row.status == :pass and served.(ok_row)

      bad = unique()
      assert {:ok, bad_row} = ingest_firmware(bad, pins(bad), plugins: [hex, dirs])
      assert bad_row.status == :pass
      refute served.(bad_row)
    end

    test "a target the judge refused is skipped with its verdict and no files" do
      name = unique()
      assert {:ok, row} = ingest_firmware(name, pins(name), judge: @refused)

      assert row.status == :skipped
      assert row.reason == "firmware judge (plugins_hooks): rebar3 build runs plugins"
      assert row.firmware_judge == @refused
      assert shas(row) == []
    end

    test "a judge pass is stored with its verdict and its files" do
      name = unique()
      pass = %{"status" => "pass", "reason" => nil, "classes" => []}
      assert {:ok, row} = ingest_firmware(name, pins(name), judge: pass)

      assert row.status == :pass and row.firmware_judge == pass
      assert shas(row) == [sha("beam-" <> name)]
    end

    test "a revoked pinned build of the version holds a new one of another set" do
      name = unique()
      assert {:ok, first} = ingest_firmware(name, pins(name))

      Repo.query!(
        "UPDATE catalog_pinned_builds SET revoked_at = $2, revoked_reason = $3 WHERE id = $1",
        [
          Ecto.UUID.dump!(first.id),
          ~N[2026-11-21 13:01:33.162146],
          "compile-time probe revoked (own)"
        ]
      )

      other =
        pins(name, [
          %{"name" => "decimal", "hex" => "decimal", "version" => "2.2.0", "checksum" => @b}
        ])

      assert {:ok, row} = ingest_firmware(name, other)

      assert row.status == :pass
      assert row.unpublished_reason == "compile-time probe revoked (own)"
      assert row.unpublished_at == ~U[2026-11-21 13:01:33.162146Z]
      refute row.id in Enum.map(Portal.Pins.Served.served(row.package_id, name, []), & &1.id)
    end

    test "a judge refusal holds a later pinned build of the target that is no judge pass" do
      name = unique()
      assert {:ok, refusal} = ingest_firmware(name, pins(name), judge: @refused)

      other =
        pins(name, [
          %{"name" => "decimal", "hex" => "decimal", "version" => "2.2.0", "checksum" => @b}
        ])

      assert {:ok, row} = ingest_firmware(name, other)

      assert row.unpublished_reason == Catalog.SystemResult.judge_refusal()
      assert row.unpublished_at == refusal.inserted_at
    end

    test "a newer judge refusal withdraws an older pinned pass of the target" do
      name = unique()
      assert {:ok, old} = ingest_firmware(name, pins(name))

      Repo.query!("UPDATE catalog_pinned_builds SET finished_at = $2 WHERE id = $1", [
        Ecto.UUID.dump!(old.id),
        ~U[2026-11-18 10:00:00.000000Z]
      ])

      other =
        pins(name, [
          %{"name" => "decimal", "hex" => "decimal", "version" => "2.2.0", "checksum" => @b}
        ])

      # Review R1: the pinned ingest runs the sweep itself.
      assert {:ok, _refusal} = ingest_firmware(name, other, judge: @refused)

      old = Ash.get!(Catalog.PinnedBuild, old.id, domain: Catalog)
      assert old.unpublished_reason == Catalog.SystemResult.judge_refusal()
    end

    # Review R1, the reviewer's T4: an older regular firmware build of the
    # target is withdrawn by a pinned refusal's own ingest, not only by the
    # next regular run of the version.
    test "a pinned judge refusal withdraws an older served regular build of the target" do
      name = unique()

      fixture =
        [__DIR__, "..", "support", "fixtures", "result.json"]
        |> Path.join()
        |> File.read!()
        |> Jason.decode!()

      bytes = "regular-" <> name
      dir = files([bytes])

      rpi4 =
        fixture["systems"]["nerves_system_rpi4"]
        |> Map.put("compile_env", [])
        |> Map.put("beam_scan", %{
          "footprint" => %{
            "file_manifest" => %{"ebin" => [entry("ebin/m0.beam", bytes)], "priv" => []}
          }
        })

      result =
        Map.merge(fixture, %{
          "run_id" => "regular-#{name}",
          "package" => %{"name" => name, "version" => "1.0.0"},
          "deps_lock" => %{},
          "finished_at" => "2026-11-01T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => rpi4}
        })

      {:ok, run} =
        Ingestion.ingest(result, %{
          package: name,
          version: "1.0.0",
          run_id: result["run_id"],
          image_digest: "sha256:x",
          files_dir: dir,
          scan_request_id: nil,
          log: "log"
        })

      regular = fn ->
        Catalog.SystemResult
        |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
        |> Ash.read_one!(domain: Catalog)
      end

      assert is_nil(regular.().unpublished_at)
      assert {:ok, _refusal} = ingest_firmware(name, pins(name), judge: @refused)
      assert regular.().unpublished_reason == Catalog.SystemResult.judge_refusal()
    end
  end

  test "a target R2 passed is still stored as pass with its files" do
    name = unique()

    assert {:ok, row} =
             ingest_firmware(name, pins(name), build_root: %{"status" => "pass", "reason" => nil})

    assert row.status == :pass
    assert shas(row) == [sha("beam-" <> name)]
  end

  test "a native priv file is recorded as native" do
    name = unique()
    elf = <<0x7F, "ELF", "not a real one">>
    assert {:ok, row} = ingest_firmware(name, pins(name), priv: [{"priv/nif.so", elf}])

    assert row.status == :pass
    assert row.native == true
    assert row.portable == false
    assert Enum.sort(shas(row)) == Enum.sort([sha("beam-" <> name), sha(elf)])
  end

  # Review focus 2: a build is never stored under a release it was not built on.
  test "another system release is skipped with no files" do
    name = unique()
    assert {:ok, row} = ingest_firmware(name, pins(name), system_version: "2.2.0")

    assert row.status == :skipped
    assert row.reason =~ "2.2.0"
    assert row.system_version == "2.1.2"
    assert row.file_manifest == nil
    assert shas(row) == []
  end

  # Review focus 3: the published `deps` is what Mix resolved, and it must be the set.
  test "a lock that is not the set is skipped with no files" do
    name = unique()
    lock = %{"decimal" => %{"version" => "2.2.0", "checksum" => @b}}
    assert {:ok, row} = ingest_firmware(name, pins(name), lock: lock)

    assert row.status == :skipped
    assert row.reason =~ "pins not reproduced on the host: pins_closure_mismatch (~decimal)"
    assert shas(row) == []
  end

  test "a result echoing another set, or none, is skipped" do
    name = unique()
    assert {:ok, row} = ingest_firmware(name, pins(name), hash: @b)
    assert row.status == :skipped and row.reason =~ "does not echo the set"

    other = unique()
    assert {:ok, row} = ingest_firmware(other, pins(other), pins_status: "refused")
    assert row.status == :skipped and shas(row) == []
  end

  # Review focus 5: only the job's target is ever read.
  test "only the job's target is read: a pure selection or another target is skipped" do
    name = unique()
    pure = firmware_result(name, pins(name))["systems"]["nerves_system_rpi4"]

    assert {:ok, row} = ingest_firmware(name, pins(name), systems: %{"pure_elixir" => pure})
    assert row.status == :skipped
    assert row.reason == "pinned target not built: the worker judged the closure pure Elixir"
    assert shas(row) == []

    other = unique()

    assert {:ok, row} =
             ingest_firmware(other, pins(other), systems: %{"nerves_system_rpi5" => pure})

    assert row.status == :skipped
    assert row.reason == "pinned target not built: the result has no nerves_system_rpi4"
    assert row.target == "nerves_system_rpi4"
  end

  test "a run of another scope is skipped" do
    name = unique()
    assert {:ok, row} = ingest_firmware(name, pins(name), scope: "full")
    assert row.status == :skipped and shas(row) == []
  end

  test "a refused set is skipped with the worker's reason" do
    name = unique()
    reason = "pins not reproduced: pins_closure_mismatch (+logger_backends)"

    assert {:ok, row} =
             ingest_firmware(name, pins(name),
               status: "skipped",
               log_tail: reason,
               error: "pins_not_reproduced",
               pins_status: "refused"
             )

    assert row.status == :skipped
    assert row.reason == reason
    assert shas(row) == []
  end

  test "a failed target is a fail verdict, an errored one no verdict" do
    name = unique()
    assert {:ok, row} = ingest_firmware(name, pins(name), status: "fail", error: "build_failed")
    assert row.status == :fail and row.reason =~ "build_failed"
    assert shas(row) == []

    other = unique()
    assert {:ok, row} = ingest_firmware(other, pins(other), status: "error", error: "timeout")
    assert row.status == :error
  end

  # Review I1: a firmware image off the job's toolchain wastes every build;
  # the error row it leaves says so in the catalog, and never serves.
  test "a result built on another toolchain is an error row naming that toolchain, with no files" do
    name = unique()
    pins = pins(name)
    result = firmware_result(name, pins, otp: "30")

    assert {:ok, row} =
             Ingestion.ingest_pinned(result, firmware_opts(name, pins, files(["beam-" <> name])))

    assert row.status == :error
    assert row.toolchain == "1.20/29"
    assert {row.elixir, row.otp} == {"1.20.5", "30"}
    assert row.reason == "pinned build on toolchain 1.20/30, not the job's 1.20/29"
    assert row.file_manifest == nil and row.deps_lock == nil
    assert shas(row) == []
    assert runs(name) == []
  end

  test "a toolchain mismatch never replaces a served pass" do
    name = unique()
    pins = pins(name)
    assert {:ok, %{status: :pass} = pass} = ingest_firmware(name, pins)

    assert {:ok, row} =
             Ingestion.ingest_pinned(
               firmware_result(name, pins, otp: "30"),
               firmware_opts(name, pins, files(["beam-" <> name]))
             )

    assert row.id == pass.id and row.status == :pass and row.attempted_at != nil
    assert shas(row) == [sha("beam-" <> name)]
  end

  test "the ingest job keys the row on the job's target and release" do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)

    name = unique()
    pins = pins(name)
    files_dir = files(["beam-" <> name])

    Process.put(:pinned_build, %{
      result: firmware_result(name, pins),
      files_dir: files_dir,
      output_dir: files_dir
    })

    args = %{
      "kind" => "pinned",
      "run_id" => "pin-#{name}",
      "image_digest" => "sha256:fw",
      "package" => name,
      "version" => "1.0.0",
      "toolchain" => "1.20/29",
      "builder_version" => Portal.Toolchains.builder_version(),
      "config_variant" => "default",
      "pins" => pins,
      "pin_hash" => pins["hash"],
      "target" => "nerves_system_rpi4",
      "system_version" => "2.1.2"
    }

    assert :ok = perform_job(Portal.Workers.Ingest, args)

    assert [%Catalog.PinnedBuild{status: :pass} = row] =
             Catalog.PinnedBuild
             |> Ash.Query.filter(package.name == ^name)
             |> Ash.read!(domain: Catalog)

    assert {row.target, row.system_version, row.run_id} ==
             {"nerves_system_rpi4", "2.1.2", "pin-#{name}"}
  end

  # Review focus 5: never a run, and never the package's latest version.
  test "never a run, never the latest version" do
    name = unique()

    Catalog.Package
    |> Ash.Changeset.for_create(:create, %{name: name, latest_version: "0.9.0"})
    |> Ash.create!(domain: Catalog)

    assert {:ok, %{status: :pass}} = ingest_firmware(name, pins(name))
    assert runs(name) == []
    assert package(name).latest_version == "0.9.0"

    fresh = unique()
    assert {:ok, _row} = ingest_firmware(fresh, pins(fresh))
    assert package(fresh).latest_version == nil
  end
end
