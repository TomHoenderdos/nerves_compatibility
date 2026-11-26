defmodule Portal.Pins.RefeedTest do
  # Stream S11: a pinned firmware build is built at its lock's exact system
  # release, and nothing fed the stored locks again when a system released
  # (2026-11-25, rpi4 and rpi5 2.2.3: 84 miss lines in client 0.9.0). Every
  # lock fed for real is stored, and a new release of its system feeds it
  # again at that release.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Pins.Locks
  alias Portal.Pins.Refeed
  alias Portal.Workers.{PinnedBuild, PinRefeed}

  @nerves2 "~> 1.11 or ~> 2.0 or ~> 2.0.0-dev"

  defmodule FakeHex do
    # `{name => [release]}` from the test process; by default each package
    # at the version and checksum the lock names.
    def releases(name, _opts \\ []) do
      case Process.get({:refeed_hex, name}) do
        nil ->
          {:ok,
           [
             %{
               version: Process.get({:refeed_version, name}),
               outer_checksum: Process.get({:refeed_sum, name}),
               retired_reason: nil,
               retired?: false,
               deps: []
             }
           ]}

        :down ->
          {:error, :hex_registry_unavailable}

        releases ->
          {:ok, releases}
      end
    end
  end

  defp sum(char), do: String.duplicate(char, 64)

  defp hex(app, version, char, deps \\ [], managers \\ "[:mix]") do
    Process.put({:refeed_version, app}, version)
    Process.put({:refeed_sum, app}, sum(char))

    edges =
      Enum.map_join(deps, ", ", fn {dep, req} ->
        ~s|{:#{dep}, "#{req}", [hex: :#{dep}, repo: "hexpm", optional: false]}|
      end)

    ~s|  "#{app}": {:hex, :#{app}, "#{version}", "inner", #{managers}, [#{edges}], "hexpm", "#{sum(char)}"},\n|
  end

  # A Nerves project's lock: one native set (nif), on rpi4 at `release`.
  defp lock(release) do
    "%{\n" <>
      hex("nif", "1.0.0", "1", [{"elixir_make", "~> 0.6"}], "[:make, :mix]") <>
      hex("elixir_make", "0.8.4", "2") <>
      hex("nerves", "2.0.0-pre.3", "3") <>
      hex("nerves_system_rpi4", release, "9", [{"nerves", @nerves2}]) <>
      hex("nerves_system_br", "1.35.3", "8") <> "}\n"
  end

  defp abi!(version, otp \\ "29.1.2") do
    {:ok, _} =
      Portal.Catalog.SystemAbi.observe(%{
        system_pkg: "nerves_system_rpi4",
        version: version,
        source: "lock",
        otp: otp,
        toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
        toolchain_version: "15.3.1"
      })
  end

  defp system_release(version, nerves \\ @nerves2) do
    %{
      version: version,
      retired?: false,
      retired_reason: nil,
      outer_checksum: sum("9"),
      deps: [%{package: "nerves", requirement: nerves, optional: false, repository: "hexpm"}]
    }
  end

  defp feed(content, opts \\ []),
    do: Portal.Pins.from_lock(content, [hex: FakeHex, system: "nerves_system_rpi4"] ++ opts)

  defp firmware_releases do
    for job <- all_enqueued(worker: PinnedBuild),
        job.args["target"] == "nerves_system_rpi4",
        do: {job.args["package"], job.args["system_version"]}
  end

  setup do
    Application.put_env(:portal, Portal.Pins.Refeed, hex: FakeHex)
    on_exit(fn -> Application.delete_env(:portal, Portal.Pins.Refeed) end)
  end

  describe "the stored locks" do
    test "a real feed stores its lock once with its options; a dry run stores nothing" do
      abi!("2.2.2")
      content = lock("2.2.2")

      assert {:ok, _} = feed(content)
      assert Locks.all() == []

      assert {:ok, _} = feed(content, dry_run: false, cap: 10)
      assert {:ok, _} = feed(content, dry_run: false)

      assert [stored] = Locks.all()
      assert stored.content == content
      assert stored.system == "nerves_system_rpi4"
      assert stored.release == "2.2.2"
      assert stored.deterministic == false
      assert stored.refed == %{}
    end
  end

  describe "from_lock/2 with system_release:" do
    test "builds the lock's firmware sets at that release, checked by the registry" do
      abi!("2.2.2")
      abi!("2.2.3")

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [
        system_release("2.2.2"),
        system_release("2.2.3")
      ])

      assert {:ok, report} = feed(lock("2.2.2"), system_release: "2.2.3", dry_run: false)
      assert report.system == %{name: "nerves_system_rpi4", version: "2.2.3", refused: nil}
      assert {"nif", "2.2.3"} in firmware_releases()
    end

    test "a release the registry does not list, or one for Nerves 1, is refused" do
      abi!("2.2.3")
      Process.put({:refeed_hex, "nerves_system_rpi4"}, [system_release("2.2.2")])

      assert {:error, {:unknown_system_release, "nerves_system_rpi4", "2.2.3"}} =
               feed(lock("2.2.2"), system_release: "2.2.3")

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [system_release("2.2.3", "~> 1.11")])
      assert {:ok, report} = feed(lock("2.2.2"), system_release: "2.2.3")
      assert report.system.refused == "unbuildable_system: nerves_system_rpi4 2.2.3"
    end

    test "needs a system the lock holds" do
      no_system = "%{\n" <> hex("elixir_make", "0.8.4", "2") <> "}\n"

      assert {:error, :system_release_needs_system} =
               Portal.Pins.from_lock(no_system, hex: FakeHex, system_release: "2.2.3")
    end
  end

  describe "Refeed.offer/1 and the job" do
    defp registry(versions),
      do: [%{name: "nerves_system_rpi4", latest_version: List.last(versions), versions: versions}]

    test "a newer stable release of a stored lock's system queues one job" do
      abi!("2.2.2")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)

      assert Refeed.offer(registry(["2.2.2"])) == 0
      assert Refeed.offer(registry(["2.2.2", "2.3.0-rc.0"])) == 0
      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 1
      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 0

      assert [%{args: %{"system" => "nerves_system_rpi4", "version" => "2.2.3"}}] =
               all_enqueued(worker: PinRefeed)
    end

    test "the job feeds every stored lock of the system at the release, once" do
      abi!("2.2.2")
      abi!("2.2.3")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [
        system_release("2.2.2"),
        system_release("2.2.3")
      ])

      assert :ok =
               perform_job(PinRefeed, %{"system" => "nerves_system_rpi4", "version" => "2.2.3"})

      assert {"nif", "2.2.3"} in firmware_releases()
      assert [%{refed: %{"nerves_system_rpi4" => "2.2.3"}}] = Locks.all()

      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 0
    end

    test "a release whose ABI row is not there yet waits; one not built on Nerves 2 is dropped" do
      abi!("2.2.2")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)
      Process.put({:refeed_hex, "nerves_system_rpi4"}, [system_release("2.2.3")])
      args = %{"system" => "nerves_system_rpi4", "version" => "2.2.3"}

      assert {:snooze, 3600} = perform_job(PinRefeed, args)
      assert {:cancel, :system_abi_unknown} = perform_job(PinRefeed, args, attempt: 25)

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [system_release("2.2.3", "~> 1.11")])
      assert {:cancel, :not_nerves_2} = perform_job(PinRefeed, args)
      refute Enum.any?(firmware_releases(), &(elem(&1, 1) == "2.2.3"))

      # A release the worker cannot build is no release to feed at: the
      # lock is done with it, so it is not offered again.
      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 0
    end

    # Review S1.
    test "NCC_PIN_REFEED=0 offers nothing and a queued job feeds nothing" do
      abi!("2.2.2")
      abi!("2.2.3")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)
      Process.put({:refeed_hex, "nerves_system_rpi4"}, [system_release("2.2.3")])
      Application.put_env(:portal, Portal.Pins.Refeed, hex: FakeHex, enabled: false)

      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 0
      assert all_enqueued(worker: PinRefeed) == []

      args = %{"system" => "nerves_system_rpi4", "version" => "2.2.3"}
      assert {:cancel, :pin_refeed_off} = perform_job(PinRefeed, args)
      refute Enum.any?(firmware_releases(), &(elem(&1, 1) == "2.2.3"))
      assert [%{refed: %{}}] = Locks.all()
    end

    # Review S2: a cancelled job (the ABI row a day late) never blocks the
    # release for good.
    test "a cancelled or discarded job does not keep the release from being offered again" do
      abi!("2.2.2")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)

      for state <- ["cancelled", "discarded"] do
        assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 1

        Portal.Repo.query!("UPDATE oban_jobs SET state = $1 WHERE worker = $2", [
          state,
          inspect(PinRefeed)
        ])
      end

      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 1
    end

    test "a lock stored after the release's job completed is offered at it too" do
      abi!("2.2.2")
      abi!("2.2.3")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [
        system_release("2.2.2"),
        system_release("2.2.3")
      ])

      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 1
      [job] = all_enqueued(worker: PinRefeed)
      assert :ok = perform_job(PinRefeed, job.args)
      Portal.Repo.query!("UPDATE oban_jobs SET state = 'completed' WHERE id = $1", [job.id])

      other = String.replace(lock("2.2.2"), "\n}\n", hex("extra", "0.1.0", "7") <> "}\n")
      {:ok, _} = feed(other, dry_run: false)

      assert Refeed.offer(registry(["2.2.2", "2.2.3"])) == 1
    end

    test "a lock whose feed fails is not marked fed, and the job fails to be retried" do
      abi!("2.2.2")
      abi!("2.2.3")
      {:ok, _} = feed(lock("2.2.2"), dry_run: false)
      :ok = Locks.store("%{not a lock", %{system: "nerves_system_rpi4", release: "2.2.2"})

      Process.put({:refeed_hex, "nerves_system_rpi4"}, [
        system_release("2.2.2"),
        system_release("2.2.3")
      ])

      args = %{"system" => "nerves_system_rpi4", "version" => "2.2.3"}
      assert {:error, _} = perform_job(PinRefeed, args)

      refed = Locks.all() |> Enum.map(&{&1.content =~ "not a lock", &1.refed}) |> Enum.sort()
      assert refed == [{false, %{"nerves_system_rpi4" => "2.2.3"}}, {true, %{}}]
    end
  end
end
