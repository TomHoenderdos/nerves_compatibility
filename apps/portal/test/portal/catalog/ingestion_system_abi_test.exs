defmodule Portal.Catalog.IngestionSystemAbiTest do
  # A passing target build records the toolchain its lock resolved, the
  # system release's OTP and the release's library table; ingest keeps the
  # first two on the system result and all three, per system release, in
  # `catalog_system_abi`. After the blobs are stored it reads the target's
  # published priv files as ELF and records whether they are native, whether
  # they can be judged on another release, and what they need.
  use Portal.DataCase, async: false

  require Ash.Query
  require Logger

  import ExUnit.CaptureLog, only: [capture_log: 1, capture_log: 2]

  alias Portal.Catalog.{Ingestion, SystemAbi, SystemResult}

  @domain Portal.Catalog
  @fixtures Path.expand("../../../../compatibility/test/fixtures/elf", __DIR__)
  @toolchain "nerves_toolchain_aarch64_nerves_linux_gnu"
  @libs %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.41"]}

  defp nif, do: File.read!(Path.join(@fixtures, "nif_aarch64.so"))

  defp sha(content), do: :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)

  defp unique(prefix), do: "#{prefix}_#{System.unique_integer([:positive])}"

  defp files_dir_with(contents) do
    dir = Path.join(System.tmp_dir!(), "abi-ingest-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    Enum.each(contents, &File.write!(Path.join(dir, sha(&1)), &1))
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp entry(path, content),
    do: %{
      "path" => path,
      "sha256" => sha(content),
      "size" => byte_size(content),
      "mode" => 33_188
    }

  defp result(name, system_version, otp_full, beam, priv) do
    %{
      "run_id" => "abi-#{name}",
      "package" => %{"name" => name, "version" => "1.0.0"},
      "systems" => %{
        "nerves_system_rpi4" => %{
          "status" => "pass",
          "duration_sec" => 100.0,
          "log_tail" => "ok",
          "system_version" => system_version,
          "toolchain" => %{"package" => @toolchain, "version" => "15.3.1"},
          "otp_full" => otp_full,
          "system_libs" => @libs,
          "beam_scan" => %{
            "footprint" => %{
              "file_manifest" => %{
                "ebin" => [entry("ebin/#{name}.beam", beam)],
                "priv" => Enum.map(priv, fn {path, content} -> entry(path, content) end)
              }
            }
          }
        },
        "host" => %{
          "status" => "pass",
          "duration_sec" => 5.0,
          "log_tail" => "ok",
          "system_version" => nil,
          "beam_scan" => nil
        }
      },
      "finished_at" => "2026-11-12T10:00:00Z"
    }
  end

  defp ingest(result, files_dir, extra \\ %{}) do
    Ingestion.ingest(
      result,
      Map.merge(
        %{
          package: result["package"]["name"],
          version: result["package"]["version"],
          run_id: result["run_id"] <> "-#{System.unique_integer([:positive])}",
          image_digest: "sha256:abi",
          files_dir: files_dir,
          scan_request_id: nil,
          log: nil
        },
        extra
      )
    )
  end

  defp system_result(run, system_pkg) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == ^system_pkg)
    |> Ash.read_one!(domain: @domain)
  end

  defp abi_rows(system_pkg) do
    SystemAbi
    |> Ash.Query.filter(system_pkg == ^system_pkg)
    |> Ash.read!(domain: @domain)
  end

  defp abi_row(system_pkg, version) do
    SystemAbi
    |> Ash.Query.filter(system_pkg == ^system_pkg and version == ^version)
    |> Ash.read_one!(domain: @domain)
  end

  defp attach_conflicts do
    test = self()
    id = "system-abi-conflict-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      id,
      [:portal, :system_abi, :conflict],
      fn _event, measurements, metadata, _ -> send(test, {:conflict, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
  end

  defp observed(system_pkg, version, extra \\ %{}) do
    Map.merge(
      %{
        system_pkg: system_pkg,
        version: version,
        toolchain_pkg: @toolchain,
        toolchain_version: "15.3.1",
        otp: "29.1.2",
        libs: @libs,
        source: "lock"
      },
      extra
    )
  end

  describe "ingesting a target build" do
    test "records its toolchain, OTP, ELF facts and the release's ABI" do
      name = unique("abipkg")
      version = "1.33.#{System.unique_integer([:positive])}"
      beam = "beam-#{name}"
      so = nif()
      files_dir = files_dir_with([beam, so])

      {:ok, run} =
        ingest(result(name, version, "29.1.2", beam, [{"priv/gpio_nif.so", so}]), files_dir)

      row = system_result(run, "nerves_system_rpi4")
      assert row.toolchain_pkg == @toolchain
      assert row.toolchain_version == "15.3.1"
      assert row.otp_full == "29.1.2"
      assert row.native == true
      assert row.portable == true

      assert row.elf_needs == %{
               "libc.so.6" => ["GLIBC_2.17"],
               "ld-linux-aarch64.so.1" => ["GLIBC_2.17"]
             }

      host = system_result(run, "host")
      assert host.native == nil
      assert host.toolchain_pkg == nil

      assert [abi] = abi_rows("nerves_system_rpi4") |> Enum.filter(&(&1.version == version))
      assert abi.series == "15.3"
      assert abi.source == "lock"
      assert abi.otp == "29.1.2"
      assert abi.libs == @libs
      assert abi.toolchain_pkg == @toolchain
      assert abi.toolchain_version == "15.3.1"
      assert %DateTime{} = abi.observed_at
    end

    test "a second build of the release with another OTP keeps the first, and says so" do
      attach_conflicts()
      name = unique("abipkg")
      version = "1.34.#{System.unique_integer([:positive])}"
      beam = "beam-#{name}"
      files_dir = files_dir_with([beam])
      {:ok, _} = ingest(result(name, version, "29.1.2", beam, []), files_dir)

      log =
        capture_log(fn ->
          {:ok, _} = ingest(result(name, version, "29.1.3", beam, []), files_dir_with([beam]))
        end)

      assert abi_row("nerves_system_rpi4", version).otp == "29.1.2"
      assert log =~ "nerves_system_rpi4"
      assert log =~ version
      assert log =~ "otp"

      assert_received {:conflict, %{count: 1},
                       %{system_pkg: "nerves_system_rpi4", version: ^version, field: :otp}}
    end

    test "a target with ebin files and an empty priv is beam-only" do
      name = unique("abipkg")
      version = "1.35.#{System.unique_integer([:positive])}"
      beam = "beam-#{name}"
      {:ok, run} = ingest(result(name, version, "29.1.2", beam, []), files_dir_with([beam]))

      row = system_result(run, "nerves_system_rpi4")
      assert row.native == false
      assert row.portable == true
      assert row.elf_needs == %{}
      assert row.otp_full == "29.1.2"
    end

    test "a target without a file manifest has no ELF facts" do
      name = unique("abipkg")
      version = "1.38.#{System.unique_integer([:positive])}"
      beam = "beam-#{name}"
      result = result(name, version, "29.1.2", beam, [])

      result =
        update_in(result, ["systems", "nerves_system_rpi4"], &Map.put(&1, "beam_scan", nil))

      {:ok, run} = ingest(result, files_dir_with([beam]))

      row = system_result(run, "nerves_system_rpi4")
      assert row.native == nil
      assert row.portable == nil
      assert row.elf_needs == nil
    end

    test "a priv blob that never reached the store leaves the ELF facts null" do
      name = unique("abipkg")
      version = "1.36.#{System.unique_integer([:positive])}"
      beam = "beam-#{name}"
      missing = "missing-#{name}"

      {:ok, run} =
        ingest(
          result(name, version, "29.1.2", beam, [{"priv/gone.so", missing}]),
          files_dir_with([beam])
        )

      row = system_result(run, "nerves_system_rpi4")
      assert row.native == nil
      assert row.portable == nil
      assert row.otp_full == "29.1.2"
    end
  end

  # The run is committed before these facts are read: however reading them
  # fails, the ingest has succeeded, or the job would retry a stored run.
  describe "a failure after the ingest commits" do
    for {label, fail} <- [
          raise: quote(do: fn _run_id -> raise DBConnection.ConnectionError, "dropped" end),
          exit: quote(do: fn _run_id -> exit(:pool_timeout) end),
          throw: quote(do: fn _run_id -> throw(:boom) end)
        ] do
      test "a candidates query that fails by #{label} still returns the run" do
        name = unique("abipkg")
        version = "1.37.#{System.unique_integer([:positive])}"
        beam = "beam-#{name}"
        so = nif()
        result = result(name, version, "29.1.2", beam, [{"priv/gpio_nif.so", so}])

        log =
          capture_log(fn ->
            assert {:ok, run} =
                     ingest(result, files_dir_with([beam, so]), %{elf_candidates: unquote(fail)})

            send(self(), {:run, run})
          end)

        assert_received {:run, run}
        assert log =~ "Could not record the system ABI facts of run"
        assert log =~ run.id
        assert system_result(run, "nerves_system_rpi4").native == nil
        # The observations made before the failure stand.
        assert abi_row("nerves_system_rpi4", version).otp == "29.1.2"
      end
    end
  end

  describe "observe/1" do
    test "fills a null field of an existing row" do
      version = "2.0.#{System.unique_integer([:positive])}"
      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version, %{otp: nil}))
      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version))

      assert abi_row("nerves_system_bbb", version).otp == "29.1.2"
    end

    test "an empty library table is not stored" do
      version = "2.1.#{System.unique_integer([:positive])}"

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   SystemAbi.observe(observed("nerves_system_bbb", version, %{libs: %{}}))
        end)

      assert abi_row("nerves_system_bbb", version).libs == nil
      assert log =~ "it is empty"
    end

    test "a library table without a libc is not stored" do
      version = "2.2.#{System.unique_integer([:positive])}"
      libs = %{"libz.so.1" => ["ZLIB_1.2.0"]}

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   SystemAbi.observe(observed("nerves_system_bbb", version, %{libs: libs}))
        end)

      assert abi_row("nerves_system_bbb", version).libs == nil
      assert log =~ "libc"

      # musl's libc is libc.so.
      musl = %{"libc.so" => []}
      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version, %{libs: musl}))
      assert abi_row("nerves_system_bbb", version).libs == musl
    end

    test "a lock observation replaces a requirement row's toolchain" do
      version = "2.3.#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               SystemAbi.observe(%{
                 system_pkg: "nerves_system_bbb",
                 version: version,
                 toolchain_pkg: @toolchain,
                 toolchain_version: "~> 15.2.0",
                 otp: nil,
                 libs: nil,
                 source: "requirement"
               })

      requirement = abi_row("nerves_system_bbb", version)
      assert requirement.source == "requirement"
      assert requirement.series == "15.2"

      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version))

      row = abi_row("nerves_system_bbb", version)
      assert row.source == "lock"
      assert row.toolchain_version == "15.3.1"
      assert row.series == "15.3"
      assert row.otp == "29.1.2"
      assert row.libs == @libs
    end

    test "a lock observation without a toolchain package keeps the row's" do
      version = "2.5.#{System.unique_integer([:positive])}"

      assert {:ok, _} =
               SystemAbi.observe(%{
                 system_pkg: "nerves_system_bbb",
                 version: version,
                 toolchain_pkg: @toolchain,
                 toolchain_version: "~> 15.3.0",
                 source: "requirement"
               })

      assert {:ok, _} =
               SystemAbi.observe(observed("nerves_system_bbb", version, %{toolchain_pkg: nil}))

      row = abi_row("nerves_system_bbb", version)
      assert row.source == "lock"
      assert row.toolchain_pkg == @toolchain
      assert row.toolchain_version == "15.3.1"
    end

    test "a malformed library table is refused for being malformed" do
      version = "2.6.#{System.unique_integer([:positive])}"
      libs = %{"libc.so.6" => "GLIBC_2.17"}

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   SystemAbi.observe(observed("nerves_system_bbb", version, %{libs: libs}))
        end)

      assert abi_row("nerves_system_bbb", version).libs == nil
      assert log =~ "not a map of soname to version names"
      refute log =~ "names no libc"
    end

    test "another patch of the same toolchain series is not a conflict" do
      attach_conflicts()
      version = "2.7.#{System.unique_integer([:positive])}"
      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version))
      Logger.put_module_level(SystemAbi, :info)
      on_exit(fn -> Logger.delete_module_level(SystemAbi) end)

      log =
        capture_log([level: :info], fn ->
          assert {:ok, _} =
                   SystemAbi.observe(
                     observed("nerves_system_bbb", version, %{toolchain_version: "15.3.2"})
                   )
        end)

      row = abi_row("nerves_system_bbb", version)
      assert row.toolchain_version == "15.3.1"
      assert row.series == "15.3"
      assert log =~ "[info]"
      assert log =~ "15.3.2"
      refute log =~ "[error]"
      refute log =~ "conflict"
      refute_received {:conflict, _, _}
    end

    test "a conflicting toolchain on a lock row is kept, logged and counted" do
      attach_conflicts()
      version = "2.4.#{System.unique_integer([:positive])}"
      assert {:ok, _} = SystemAbi.observe(observed("nerves_system_bbb", version))

      log =
        capture_log(fn ->
          assert {:ok, _} =
                   SystemAbi.observe(
                     observed("nerves_system_bbb", version, %{toolchain_version: "15.4.0"})
                   )
        end)

      row = abi_row("nerves_system_bbb", version)
      assert row.toolchain_version == "15.3.1"
      assert row.series == "15.3"
      assert log =~ "[error]"
      assert log =~ "toolchain_version"

      assert_received {:conflict, %{count: 1},
                       %{
                         system_pkg: "nerves_system_bbb",
                         version: ^version,
                         field: :toolchain_version
                       }}

      refute_received {:conflict, _, _}
    end
  end

  test "observe_all/1 records a system_abi run's releases and skips its errors" do
    v1 = "3.0.#{System.unique_integer([:positive])}"
    v2 = "3.1.#{System.unique_integer([:positive])}"

    entries = [
      %{
        "system" => "nerves_system_rpi5",
        "version" => v1,
        "toolchain" => %{"package" => @toolchain, "version" => "15.3.1"},
        "otp_full" => "29.1.2",
        "system_libs" => @libs
      },
      %{"system" => "nerves_system_rpi5", "version" => v2, "error" => "nerves 1 only"}
    ]

    assert :ok = SystemAbi.observe_all(entries)

    assert [row] = abi_rows("nerves_system_rpi5") |> Enum.filter(&(&1.version in [v1, v2]))
    assert row.version == v1
    assert row.source == "lock"
    assert row.series == "15.3"
    assert row.otp == "29.1.2"
    assert row.libs == @libs
  end
end
