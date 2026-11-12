defmodule Portal.Workers.SystemAbiBackfillTest do
  # Target builds published before their ELF facts and toolchain were
  # recorded get them here, once, and the system releases those builds ran
  # on get a `system_abi` run when the portal has no library table for them.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  import ExUnit.CaptureLog, only: [capture_log: 1]

  alias Portal.ArtifactStore
  alias Portal.Catalog.{Ingestion, SystemAbi, SystemResult}
  alias Portal.Workers.{SystemAbiBackfill, SystemAbiRun}

  @domain Portal.Catalog
  @fixtures Path.expand("../../../../compatibility/test/fixtures/elf", __DIR__)
  @toolchain "nerves_toolchain_aarch64_nerves_linux_gnu"

  defp nif, do: File.read!(Path.join(@fixtures, "nif_aarch64.so"))

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  defp system(version, priv) do
    %{
      "status" => "pass",
      "duration_sec" => 100.0,
      "log_tail" => "ok",
      "system_version" => version,
      "beam_scan" => %{
        "footprint" => %{
          "file_manifest" => %{
            "ebin" => [],
            "priv" => Enum.map(priv, fn {path, content} -> entry(path, content) end)
          }
        }
      }
    }
  end

  # A beam-only build: ebin files and an empty priv.
  defp ebin_only(version) do
    put_in(
      system(version, []),
      ["beam_scan", "footprint", "file_manifest", "ebin"],
      [entry("ebin/circuits_gpio.beam", "a beam")]
    )
  end

  # One run from before the facts were recorded: three target builds with
  # priv files and no toolchain, OTP or library table, ingested without
  # reading their ELF facts.
  defp ingest_old_run!(missing) do
    contents = [nif(), "a plain data file", missing]
    dir = Path.join(System.tmp_dir!(), "abi-backfill-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "run_id" => "abi-backfill",
      "package" => %{"name" => "circuits_gpio", "version" => "2.1.0"},
      "systems" => %{
        "nerves_system_rpi4" => system("2.2.2", [{"priv/gpio_nif.so", nif()}]),
        "nerves_system_bbb" => system("2.0.0", [{"priv/data.txt", "a plain data file"}]),
        "nerves_system_rpi3" => system("2.0.0", [{"priv/gone.so", missing}]),
        "nerves_system_rpi0" => ebin_only("2.0.0"),
        "host" => %{"status" => "pass", "duration_sec" => 5.0, "beam_scan" => nil}
      },
      "finished_at" => "2026-11-12T10:00:00Z"
    }

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: "circuits_gpio",
        version: "2.1.0",
        run_id: "abi-backfill-#{System.unique_integer([:positive])}",
        image_digest: "sha256:abi",
        files_dir: dir,
        scan_request_id: nil,
        log: nil,
        elf_candidates: fn _run_id -> [] end
      })

    File.rm!(ArtifactStore.blob_path(sha(missing)))
    run
  end

  defp row(run, system_pkg) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == ^system_pkg)
    |> Ash.read_one!(domain: @domain)
  end

  defp elf_checked_at(row) do
    %{rows: [[at]]} =
      Repo.query!("SELECT elf_checked_at FROM catalog_system_results WHERE id = $1", [
        Ecto.UUID.dump!(row.id)
      ])

    at
  end

  defp run_pairs do
    SystemAbiRun
    |> all_enqueued_jobs()
    |> Enum.map(& &1.args["pairs"])
  end

  defp all_enqueued_jobs(worker), do: all_enqueued(worker: worker)

  setup do
    missing = "missing-#{System.unique_integer([:positive])}"
    {:ok, run: ingest_old_run!(missing)}
  end

  describe "perform/1" do
    test "fills the ELF facts it can read and marks the one it cannot", %{run: run} do
      assert row(run, "nerves_system_rpi4").native == nil

      log =
        capture_log(fn ->
          assert :ok = perform_job(SystemAbiBackfill, %{})
        end)

      rpi4 = row(run, "nerves_system_rpi4")
      assert rpi4.native == true and rpi4.portable == true
      assert Map.has_key?(rpi4.elf_needs, "libc.so.6")

      bbb = row(run, "nerves_system_bbb")
      assert bbb.native == false and bbb.portable == true and bbb.elf_needs == %{}

      rpi3 = row(run, "nerves_system_rpi3")
      assert rpi3.native == nil
      assert elf_checked_at(rpi3) != nil
      assert log =~ "nerves_system_rpi3"

      # The host result is never read.
      assert row(run, "host").native == nil
      assert elf_checked_at(row(run, "host")) == nil

      # A second run leaves the filled rows alone and does not retry the
      # unreadable one.
      updated = Map.new(["nerves_system_rpi4", "nerves_system_bbb"], &{&1, row(run, &1)})
      checked = elf_checked_at(rpi3)

      second = capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)

      for {system_pkg, before} <- updated do
        assert row(run, system_pkg).updated_at == before.updated_at
      end

      assert elf_checked_at(row(run, "nerves_system_rpi3")) == checked
      refute second =~ "nerves_system_rpi3"
    end

    test "an ebin-only build with an empty priv becomes beam-only", %{run: run} do
      assert row(run, "nerves_system_rpi0").native == nil

      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)

      rpi0 = row(run, "nerves_system_rpi0")
      assert rpi0.native == false and rpi0.portable == true and rpi0.elf_needs == %{}
      assert elf_checked_at(rpi0) != nil
    end

    test "queues a system_abi run for a native release without a library table", %{run: run} do
      Application.put_env(:portal, :build_runner, __MODULE__.NeverBuilds)
      on_exit(fn -> Application.delete_env(:portal, :build_runner) end)

      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)
      assert row(run, "nerves_system_rpi4").native

      assert run_pairs() == [[%{"system" => "nerves_system_rpi4", "version" => "2.2.2"}]]

      # Asked once a day at most, and not again by the next backfill.
      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)
      assert length(run_pairs()) == 1
    end

    test "a release with a library table gets no run", %{run: run} do
      {:ok, _row} =
        SystemAbi.observe(%{
          system_pkg: "nerves_system_rpi4",
          version: "2.2.2",
          source: "lock",
          toolchain_pkg: @toolchain,
          toolchain_version: "15.3.1",
          otp: "28.1.2",
          libs: %{"libc.so.6" => ["GLIBC_2.17"]}
        })

      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)
      assert row(run, "nerves_system_rpi4").native
      assert run_pairs() == []
    end

    test "fills a build's toolchain and OTP from its release's lock row", %{run: run} do
      {:ok, _row} =
        SystemAbi.observe(%{
          system_pkg: "nerves_system_rpi4",
          version: "2.2.2",
          source: "lock",
          toolchain_pkg: @toolchain,
          toolchain_version: "15.3.1",
          otp: "28.1.2"
        })

      # A requirement row's toolchain is a requirement, never a build's.
      {:ok, _row} =
        SystemAbi.observe(%{
          system_pkg: "nerves_system_bbb",
          version: "2.0.0",
          source: "requirement",
          toolchain_pkg: "nerves_toolchain_armv7_nerves_linux_gnueabihf",
          toolchain_version: "~> 15.3.0"
        })

      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)

      rpi4 = row(run, "nerves_system_rpi4")
      assert {rpi4.toolchain_pkg, rpi4.toolchain_version} == {@toolchain, "15.3.1"}
      assert rpi4.otp_full == "28.1.2"

      bbb = row(run, "nerves_system_bbb")
      assert {bbb.toolchain_pkg, bbb.toolchain_version, bbb.otp_full} == {nil, nil, nil}

      assert row(run, "host").toolchain_pkg == nil
    end

    test "never replaces a toolchain or OTP a build already recorded", %{run: run} do
      Repo.query!(
        "UPDATE catalog_system_results SET toolchain_pkg = 'own', toolchain_version = '15.2.0', " <>
          "otp_full = '28.0.1' WHERE id = $1",
        [Ecto.UUID.dump!(row(run, "nerves_system_rpi4").id)]
      )

      {:ok, _row} =
        SystemAbi.observe(%{
          system_pkg: "nerves_system_rpi4",
          version: "2.2.2",
          source: "lock",
          toolchain_pkg: @toolchain,
          toolchain_version: "15.3.1",
          otp: "28.1.2"
        })

      capture_log(fn -> assert :ok = perform_job(SystemAbiBackfill, %{}) end)

      rpi4 = row(run, "nerves_system_rpi4")

      assert {rpi4.toolchain_pkg, rpi4.toolchain_version, rpi4.otp_full} ==
               {"own", "15.2.0", "28.0.1"}
    end
  end

  describe "enqueue/0" do
    test "is one job on :maintenance while one is pending" do
      assert {:ok, first} = SystemAbiBackfill.enqueue()
      assert {:ok, again} = SystemAbiBackfill.enqueue()
      assert again.id == first.id
      assert first.queue == "maintenance"
    end
  end

  defmodule NeverBuilds do
    def build(_args, _opts \\ []), do: raise("the backfill never builds")
    def cleanup(_run_id), do: :ok
  end
end
