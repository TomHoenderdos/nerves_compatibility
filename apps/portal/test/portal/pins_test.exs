defmodule Portal.PinsTest do
  # The operator's entry point: a project's mix.lock to pinned builds.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog
  alias Portal.Workers.PinnedBuild

  defmodule FakeHex do
    # The signed registry as the test sets it: `{name => [release]}`, and by
    # default each release at the checksum the lock names.
    def releases(name, _opts) do
      case Process.get({:fake_hex, name}) do
        nil ->
          {:ok,
           [
             %{
               version: Process.get({:fake_version, name}),
               outer_checksum: Process.get({:fake_sum, name}),
               retired_reason: nil
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
      hex("app_a", "1.0.0", "a", [
        {"decimal", "~> 2.0", false},
        {"jason", "~> 1.0", true},
        {"floki", "~> 0.3", true},
        {"absent_opt", "~> 1.0", true}
      ]) <>
      hex("decimal", "2.3.0", "b") <>
      hex("jason", "1.4.4", "c", [{"decimal", "~> 1.0 or ~> 2.0", true}]) <>
      hex("floki", "0.36.0", "d") <>
      hex("needs_git", "1.0.0", "e", [{"g", "~> 1.0", false}]) <>
      ~s|  "g": {:git, "https://example.invalid/g.git", "abc", []},\n| <>
      hex("missing", "1.0.0", "e", [{"gone", "~> 1.0", false}]) <>
      hex("over", "1.0.0", "f", [{"decimal", "~> 1.0", false}]) <>
      hex("nif", "1.0.0", "1", [{"elixir_make", "~> 0.6", false}], "[:make, :mix]") <>
      hex("elixir_make", "0.8.4", "2") <>
      hex("nerves", "1.11.0", "3") <>
      hex("ranch", "1.8.0", "4", [], "[:make, :rebar3]") <> "}\n"
  end

  defp run(opts \\ []),
    do: Portal.Pins.from_lock(Keyword.get(opts, :lock, lock()), [hex: FakeHex] ++ opts)

  defp reasons(report), do: Map.new(report.skipped, &{&1.package, &1.reason})

  test "a dry run derives each package's set from the lock and queues nothing" do
    assert {:ok, report} = run()
    assert report.dry_run and report.target == "pure_elixir" and report.toolchain == "1.20/29"
    # ranch's `make` manager is erlang.mk's: pure Erlang, not native.
    assert Enum.map(report.queue, & &1.package) == ~w(app_a decimal floki jason ranch)
    assert %{deps: 2} = Enum.find(report.queue, &(&1.package == "app_a"))

    assert %{
             "needs_git" => "non_hex: g",
             "g" => "non_hex",
             "missing" => "member_missing: gone",
             "over" => "unsatisfied: decimal",
             # Native sets need the lock's Nerves system (phase 2).
             "nif" => "no_system",
             "elixir_make" => "no_system",
             "nerves" => "tooling"
           } = reasons(report)

    assert report.counts["queue"] == 5
    assert all_enqueued(worker: PinnedBuild) == []
  end

  test "the set follows present optional edges, never into test tooling, and hashes like the worker" do
    {sets, _refused} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock()), 1))
    app_a = Enum.find(sets, &(&1.package == "app_a"))

    assert Enum.map(app_a.pins["deps"], & &1["name"]) == ["decimal", "jason"]
    assert {:ok, _} = Compatibility.Pins.validate("app_a", "1.0.0", app_a.pins)
  end

  test "acting queues at priority 3 and a second call finds them queued" do
    assert {:ok, %{queue: [_, _, _, _, _]}} = run(dry_run: false)
    jobs = all_enqueued(worker: PinnedBuild)
    assert length(jobs) == 5
    assert Enum.all?(jobs, &(&1.priority == 3 and &1.queue == "toolchain"))
    assert %{"target" => "pure_elixir", "pins" => %{"hash" => _}} = hd(jobs).args

    assert {:ok, %{queue: []} = again} = run(dry_run: false)
    assert reasons(again)["decimal"] == "queued_dup"
    assert length(all_enqueued(worker: PinnedBuild)) == 5
  end

  # Review M3: jobs a phase-1 release queued carry no `system_version`. A
  # new release still sees one as the same build, both in `from_lock`'s own
  # check and in Oban's unique keys, which now include `system_version`.
  test "a job queued by a phase-1 release is still the same build" do
    {sets, _} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock()), 1))
    decimal = Enum.find(sets, &(&1.package == "decimal"))

    old_args = %{
      "package" => "decimal",
      "version" => "2.3.0",
      "toolchain" => "1.20/29",
      "image" => "ncc-worker:local",
      "builder_version" => Portal.Toolchains.builder_version(),
      "target" => "pure_elixir",
      "pin_hash" => decimal.pins["hash"],
      "pins" => decimal.pins
    }

    {:ok, old} =
      old_args |> PinnedBuild.new(priority: 9, queue: :toolchain) |> Oban.insert()

    refute Map.has_key?(old.args, "system_version")

    assert {:ok, report} = run(dry_run: false)
    assert reasons(report)["decimal"] == "queued_dup"
    refute "decimal" in Enum.map(report.queue, & &1.package)

    assert {:ok, %Oban.Job{conflict?: true, id: id}} =
             old_args |> PinnedBuild.new(queue: :toolchain) |> Oban.insert()

    assert id == old.id
    assert length(all_enqueued(worker: PinnedBuild, args: %{"package" => "decimal"})) == 1
  end

  test "the cap bounds one call" do
    assert {:ok, report} = run(cap: 2)
    assert length(report.queue) == 2
    assert report.counts["cap"] == 3
  end

  # The cap is phase 1's one bound on what a call costs: a value that is no
  # count (in Erlang's term order every integer is below `nil` or a string)
  # must not lift it.
  test "a cap that is not a count is refused, not unbounded" do
    for cap <- [nil, "2", -1, 2.5] do
      assert {:error, {:invalid_cap, ^cap}} = run(cap: cap, dry_run: false)
    end

    assert all_enqueued(worker: PinnedBuild) == []
  end

  test "a closure already served or judged is not queued again" do
    {sets, _} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock()), 1))
    jason = Enum.find(sets, &(&1.package == "jason"))

    package =
      Catalog.Package
      |> Ash.Changeset.for_create(:create, %{name: "jason"})
      |> Ash.create!(domain: Catalog)

    Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package.id,
      version: "1.4.4",
      toolchain: "1.20/29",
      builder_version: 1,
      variant: :with,
      config_variant: "default",
      status: :pass,
      deps_lock: Compatibility.Pins.to_lock(jason.pins["deps"])
    })
    |> Ash.create!(domain: Catalog)

    decimal =
      Catalog.Package
      |> Ash.Changeset.for_create(:create, %{name: "decimal"})
      |> Ash.create!(domain: Catalog)

    set = Enum.find(sets, &(&1.package == "decimal"))

    Catalog.PinnedBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: decimal.id,
      version: "2.3.0",
      pin_hash: set.pins["hash"],
      target: "pure_elixir",
      system_version: "",
      toolchain: "1.20/29",
      builder_version: 1,
      config_variant: "default",
      pins: set.pins,
      status: :skipped
    })
    |> Ash.create!(domain: Catalog)

    assert {:ok, report} = run()
    assert reasons(report)["jason"] == "served"
    assert reasons(report)["decimal"] == "judged"
  end

  test "the signed registry must agree with the lock" do
    Process.put({:fake_hex, "decimal"}, [
      %{version: "2.3.0", outer_checksum: sum("9"), retired_reason: nil}
    ])

    Process.put({:fake_hex, "floki"}, [
      %{version: "0.36.0", outer_checksum: sum("d"), retired_reason: "security"}
    ])

    Process.put({:fake_hex, "jason"}, :down)

    assert {:ok, report} = run()
    assert reasons(report)["decimal"] == "checksum: decimal"
    assert reasons(report)["app_a"] == "checksum: decimal"
    assert reasons(report)["floki"] == "retired: floki"
    assert reasons(report)["jason"] == "registry_unavailable: jason"
  end

  test "a path, a bad lock and an unknown target or toolchain" do
    path = Path.join(System.tmp_dir!(), "pins-#{System.unique_integer([:positive])}.lock")
    File.write!(path, lock())
    on_exit(fn -> File.rm(path) end)

    assert {:ok, %{queue: [_, _, _, _, _]}} = Portal.Pins.from_lock(path, hex: FakeHex)
    assert {:error, {:unreadable, :enoent}} = Portal.Pins.from_lock("/nonexistent/mix.lock")
    assert {:error, :unparsable} = Portal.Pins.from_lock("%{")

    assert {:error, {:unsupported_target, "nerves_system_rpi4"}} =
             run(target: "nerves_system_rpi4")

    assert {:error, {:unknown_toolchain, "9.9/99"}} = run(toolchain: "9.9/99")
  end

  # Phase 2: native sets are firmware builds of the lock's one system at its
  # exact release.
  describe "native sets" do
    # A system's own `nerves` requirement says which Nerves line it is for:
    # every Nerves 2 release declares this one (trellis 0.6.x, x86_64
    # 1.35.x, rpi4 2.x alike), a Nerves 1 era one `~> 1.11`.
    @nerves2 "~> 1.11 or ~> 2.0 or ~> 2.0.0-dev"

    defp system(name, version, nerves \\ @nerves2),
      do: hex(name, version, "9", [{"nerves", nerves, false}])

    defp abi!(system, version, otp) do
      {:ok, _} =
        Portal.Catalog.SystemAbi.observe(%{
          system_pkg: system,
          version: version,
          source: "lock",
          otp: otp,
          toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
          toolchain_version: "15.3.1"
        })
    end

    defp with_system(lines), do: lock(lines <> hex("nerves_system_br", "1.35.3", "8"))

    test "are queued on :builds for the lock's system at its release" do
      abi!("nerves_system_rpi4", "2.1.2", "29.0.6")
      lock = with_system(system("nerves_system_rpi4", "2.1.2"))

      assert {:ok, report} = run(lock: lock, dry_run: false)
      assert report.system == %{name: "nerves_system_rpi4", version: "2.1.2", refused: nil}

      assert Enum.map(report.queue, &{&1.package, &1.target}) == [
               {"app_a", "pure_elixir"},
               {"decimal", "pure_elixir"},
               {"elixir_make", "nerves_system_rpi4"},
               {"floki", "pure_elixir"},
               {"jason", "pure_elixir"},
               {"nif", "nerves_system_rpi4"},
               {"ranch", "pure_elixir"}
             ]

      firmware = all_enqueued(worker: PinnedBuild, queue: :builds)
      assert length(firmware) == 2
      assert length(all_enqueued(worker: PinnedBuild, queue: :toolchain)) == 5

      assert %{
               "package" => "nif",
               "target" => "nerves_system_rpi4",
               "system_version" => "2.1.2",
               "toolchain" => "1.20/29",
               "pins" => %{"deps" => [%{"name" => "elixir_make"}]}
             } = Enum.find(firmware, &(&1.args["package"] == "nif")).args

      assert Enum.all?(firmware, &(&1.priority == 3 and not Map.has_key?(&1.args, "image")))
      assert reasons(report)["nerves_system_rpi4"] == "tooling"

      assert {:ok, again} = run(lock: lock, dry_run: false)
      assert reasons(again)["nif"] == "queued_dup"
      assert length(all_enqueued(worker: PinnedBuild, queue: :builds)) == 2
    end

    test "a Nerves 1 release is unbuildable, one the ABI table lacks or holds on another OTP is named" do
      abi!("nerves_system_rpi4", "2.0.0", "28.0.2")

      for {version, nerves, reason} <- [
            {"1.24.0", "~> 1.11", "unbuildable_system: nerves_system_rpi4 1.24.0"},
            {"2.2.0", @nerves2, "system_abi_unknown: nerves_system_rpi4 2.2.0"},
            {"2.0.0", @nerves2, "system_otp: nerves_system_rpi4 2.0.0 (OTP 28.0.2)"}
          ] do
        lock = with_system(system("nerves_system_rpi4", version, nerves))
        assert {:ok, report} = run(lock: lock)
        assert reasons(report)["nif"] == reason
        assert reasons(report)["elixir_make"] == reason
        assert report.system.refused == reason
        assert length(report.queue) == 5
      end
    end

    # Stream S11: the rule read "major 2" as "a Nerves 2 system" and refused
    # every trellis, x86_64, mangopi_mq_pro and qemu_aarch64 Nerves 2
    # release (0.6.x, 1.35.x, 0.18.x, 0.5.x).
    test "a Nerves 2 release of any major is built; the line comes from its nerves requirement" do
      for {system, version} <- [
            {"nerves_system_trellis", "0.6.4"},
            {"nerves_system_x86_64", "1.35.3"},
            {"nerves_system_mangopi_mq_pro", "0.18.0"},
            {"nerves_system_qemu_aarch64", "0.5.0"}
          ] do
        abi!(system, version, "29.1.2")
        assert {:ok, report} = run(lock: with_system(system(system, version)))
        assert report.system == %{name: system, version: version, refused: nil}

        assert %{target: ^system, system_version: ^version} =
                 Enum.find(report.queue, &(&1.package == "nif"))
      end

      abi!("nerves_system_trellis", "0.3.0", "29.1.2")

      for nerves <- ["~> 1.11", "~> 2.1"] do
        lock = with_system(system("nerves_system_trellis", "0.3.0", nerves))
        assert {:ok, report} = run(lock: lock)
        assert report.system.refused == "unbuildable_system: nerves_system_trellis 0.3.0"
      end

      no_edge = with_system(hex("nerves_system_trellis", "0.3.0", "9"))
      assert {:ok, report} = run(lock: no_edge)
      assert report.system.refused == "unbuildable_system: nerves_system_trellis 0.3.0"
    end

    test "a system the worker does not build, several systems, and the system: option" do
      abi!("nerves_system_rpi4", "2.1.2", "29.0.6")

      assert {:ok, report} = run(lock: with_system(system("nerves_system_rpi3", "2.1.2")))
      assert reasons(report)["nif"] == "unsupported_system: nerves_system_rpi3"

      both =
        with_system(
          system("nerves_system_rpi4", "2.1.2") <> system("nerves_system_rpi5", "2.1.2")
        )

      assert {:ok, report} = run(lock: both)
      assert reasons(report)["nif"] == "ambiguous_system: nerves_system_rpi4, nerves_system_rpi5"

      assert {:ok, report} = run(lock: both, system: "nerves_system_rpi4")
      assert %{target: "nerves_system_rpi4"} = Enum.find(report.queue, &(&1.package == "nif"))

      assert {:error, {:system_not_in_lock, "nerves_system_bbb"}} =
               run(lock: both, system: "nerves_system_bbb")
    end

    test "a firmware build already judged or served is not queued again" do
      abi!("nerves_system_rpi4", "2.1.2", "29.0.6")
      lock = with_system(system("nerves_system_rpi4", "2.1.2"))
      {sets, _} = Portal.Pins.derive(elem(Portal.Pins.Lock.parse(lock), 1))
      nif = Enum.find(sets, &(&1.package == "nif"))
      elixir_make = Enum.find(sets, &(&1.package == "elixir_make"))

      package =
        Catalog.Package
        |> Ash.Changeset.for_create(:create, %{name: "elixir_make"})
        |> Ash.create!(domain: Catalog)

      Catalog.PinnedBuild
      |> Ash.Changeset.for_create(:upsert, %{
        package_id: package.id,
        version: "0.8.4",
        pin_hash: elixir_make.pins["hash"],
        target: "nerves_system_rpi4",
        system_version: "2.1.2",
        toolchain: "1.20/29",
        builder_version: Portal.Toolchains.builder_version(),
        config_variant: "default",
        pins: elixir_make.pins,
        status: :fail
      })
      |> Ash.create!(domain: Catalog)

      served_run!("nif", "1.0.0", Compatibility.Pins.to_lock(nif.pins["deps"]))

      assert {:ok, report} = run(lock: lock)
      assert reasons(report)["elixir_make"] == "judged"
      assert reasons(report)["nif"] == "served"

      # The same build on another release serves nothing here.
      abi!("nerves_system_rpi4", "2.2.0", "29.1.2")
      assert {:ok, report} = run(lock: with_system(system("nerves_system_rpi4", "2.2.0")))

      assert Enum.map(report.queue, & &1.package) -- ~w(app_a decimal floki jason ranch) ==
               ~w(elixir_make nif)
    end

    test "the cap counts both paths" do
      abi!("nerves_system_rpi4", "2.1.2", "29.0.6")
      lock = with_system(system("nerves_system_rpi4", "2.1.2"))
      assert {:ok, report} = run(lock: lock, cap: 6)
      assert length(report.queue) == 6
      assert report.counts["cap"] == 1
    end
  end

  # A regular run of `package` whose rpi4 2.1.2 target passed with `lock`.
  defp served_run!(package, version, lock) do
    fixture = Path.join([__DIR__, "..", "support", "fixtures", "result.json"])

    result =
      fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{
        "run_id" => "served-#{System.unique_integer([:positive])}",
        "package" => %{"name" => package, "version" => version},
        "toolchain" => %{"elixir" => "1.20.5", "erlang" => "29"},
        "deps_lock" => lock
      })
      |> update_in(["systems"], &Map.take(&1, ["nerves_system_rpi4"]))
      |> put_in(["systems", "nerves_system_rpi4", "system_version"], "2.1.2")

    dir = Path.join(System.tmp_dir!(), "pins-served-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Portal.Catalog.Ingestion.ingest(result, %{
        package: package,
        version: version,
        run_id: result["run_id"],
        image_digest: "sha256:served",
        files_dir: dir,
        scan_request_id: nil,
        log: "log"
      })
  end
end
