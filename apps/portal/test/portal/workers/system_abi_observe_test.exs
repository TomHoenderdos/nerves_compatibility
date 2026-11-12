defmodule Portal.Workers.SystemAbiObserveTest do
  # A release of a system the portal never built on is known first from Hex
  # (a requirement row) and gets its library table from a `system_abi` run.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import Portal.PrecompiledFixtures

  alias Portal.Catalog.SystemAbi, as: Row
  alias Portal.Precompiled.SystemAbi
  alias Portal.Test.FakeHexDeps
  alias Portal.Workers.{SystemAbiObserve, SystemAbiRun}

  @toolchain "nerves_toolchain_aarch64_nerves_linux_gnu"

  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), {:system_abi_build, args})

      entries =
        Enum.map(args.system_abi, fn %{"system" => system, "version" => version} ->
          %{
            "system" => system,
            "version" => version,
            "toolchain" => %{
              "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
              "version" => "15.3.2"
            },
            "otp_full" => "28.1.2",
            "system_libs" => %{"libc.so.6" => ["GLIBC_2.17", "GLIBC_2.41"]}
          }
        end)

      {:ok,
       %{
         exit_code: 0,
         result: %{"scope" => "system_abi", "systems" => %{}, "system_abi" => entries},
         files_dir: "",
         output_dir: "",
         log: ""
       }}
    end

    def cleanup(run_id) do
      send(self(), {:cleanup, run_id})
      :ok
    end
  end

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)

    {:ok, _row} =
      Row.observe(%{
        system_pkg: "nerves_system_rpi4",
        version: "2.2.2",
        source: "lock",
        toolchain_pkg: @toolchain,
        toolchain_version: "15.3.1",
        otp: "28.1.2",
        libs: %{"libc.so.6" => ["GLIBC_2.17"]}
      })

    ingest_with_artifact()

    Repo.query!(
      "UPDATE catalog_system_results SET native = true, portable = true, " <>
        "elf_needs = '{\"libc.so.6\": [\"GLIBC_2.17\"]}' WHERE system_pkg = 'nerves_system_rpi4'"
    )

    Process.put({FakeHexDeps, :releases}, %{
      "nerves_system_rpi4" => [
        %{
          version: "2.3.0",
          retired?: false,
          outer_checksum: nil,
          deps: [
            %{package: "nerves", requirement: "~> 1.10", optional: false, repository: "hexpm"},
            %{package: @toolchain, requirement: "~> 15.3.0", optional: false, repository: "hexpm"}
          ]
        }
      ]
    })

    :ok
  end

  test "a new Hex release gets a requirement row and one system_abi run" do
    assert :ok = perform_job(SystemAbiObserve, %{})

    assert SystemAbi.table()["nerves_system_rpi4"]["2.3.0"]["toolchain"]["series"] == "15.3"

    assert [job] = all_enqueued(worker: SystemAbiRun)
    assert job.args == %{"pairs" => [%{"system" => "nerves_system_rpi4", "version" => "2.3.0"}]}

    # Asked once: a second pass queues nothing.
    assert :ok = perform_job(SystemAbiObserve, %{})
    assert [_job] = all_enqueued(worker: SystemAbiRun)

    # The run's result fills the release's library table.
    assert :ok = perform_job(SystemAbiRun, job.args)
    assert_received {:system_abi_build, %{mode: "system_abi"} = args}

    assert args.system_abi == [%{"system" => "nerves_system_rpi4", "version" => "2.3.0"}]
    assert_received {:cleanup, run_id} when run_id == args.run_id

    libs = SystemAbi.table()["nerves_system_rpi4"]["2.3.0"]["libs"]
    assert libs["libc.so.6"] == ["GLIBC_2.17", "GLIBC_2.41"]
  end

  test "runs hourly on :maintenance, one at a time" do
    assert SystemAbiObserve.__opts__()[:queue] == :maintenance
    assert SystemAbiObserve.__opts__()[:unique][:states] == :incomplete
  end
end
