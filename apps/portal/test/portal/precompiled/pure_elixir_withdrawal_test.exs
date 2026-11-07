defmodule Portal.Precompiled.PureElixirWithdrawalTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Compatibility.Portability
  alias Portal.ArtifactStore
  alias Portal.Catalog
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.SystemResult
  alias Portal.Precompiled.PureElixirWithdrawal

  require Ash.Query

  import Portal.PrecompiledFixtures

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @sha "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"
  # A cutoff after every run a test ingests.
  @later ~U[2100-01-01 00:00:00Z]
  @host_read "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)"

  # The fixture's jason run with its publishing rpi4 result also published as
  # the run's pure_elixir result (the same file). The rpi4 row stands for the
  # run's firmware results, which a withdrawal never touches.
  defp pure_elixir_result(overrides \\ %{}) do
    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.put("deps_lock", %{})
      |> Map.put("package_checksum", "outer")
      |> put_in(["systems", "nerves_system_rpi4", "compile_env"], [])

    result
    |> put_in(["systems", "pure_elixir"], result["systems"]["nerves_system_rpi4"])
    |> Map.merge(overrides)
  end

  defp pure_elixir_run!(overrides \\ %{}), do: ingest_with_artifact(pure_elixir_result(overrides))

  defp version_run!(version) do
    pure_elixir_run!(%{
      "run_id" => "fixture-jason-#{version}",
      "package" => %{"name" => "jason", "version" => version}
    })
  end

  defp toolchain_build!(reason, observations, opts \\ []) do
    dir = Path.join(System.tmp_dir!(), "withdrawal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    version = Keyword.get(opts, :version, "1.4.1")
    variant = Keyword.get(opts, :variant, :with)

    result = %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-06T10:00:00Z",
      "requested_optional_deps" => if(variant == :with, do: "include", else: "exclude"),
      "package" => %{"name" => "jason", "version" => version},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => Keyword.get(opts, :status, "skipped"),
        "reason" => reason,
        "elixir" => Keyword.get(opts, :elixir, "1.20.4"),
        "otp" => Keyword.get(opts, :otp, "29"),
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => nil,
        "portability_rule" => 1,
        "rule1_reason" => nil,
        "compile_observations" => observations
      }
    }

    {:ok, tb} =
      Ingestion.ingest_toolchain(result, %{
        package: "jason",
        version: version,
        run_id: "tc-#{System.unique_integer([:positive])}",
        image_digest: "sha256:toolchain",
        files_dir: dir,
        output_dir: dir,
        toolchain: Keyword.get(opts, :toolchain, "1.20/29"),
        builder_version: Keyword.get(opts, :builder_version, 1),
        variant: variant
      })

    tb
  end

  # Each `ingest_with_artifact/1` removes the shared blob before it ingests,
  # and an ingest of a sha already on record stores nothing: put it back.
  defp restore_blob! do
    path = ArtifactStore.blob_path(@sha)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "precompiled-beam")
  end

  defp results(system_pkg) do
    SystemResult
    |> Ash.Query.filter(system_pkg == ^system_pkg)
    |> Ash.read!(domain: Catalog)
  end

  defp published_versions do
    case Catalog.precompiled_manifest("jason") do
      nil -> []
      manifest -> manifest.versions |> Map.keys() |> Enum.sort()
    end
  end

  test "a publication whose toolchain build the trace refused is counted, then withdrawn" do
    pure_elixir_run!()
    tb = toolchain_build!(@host_read, %{"refusals" => []})

    assert [
             %{
               package: "jason",
               version: "1.4.1",
               reason: @host_read,
               toolchain_build_id: tb_id,
               results: [%{id: id, built_at: %DateTime{}}]
             }
           ] = PureElixirWithdrawal.candidates()

    assert tb_id == tb.id
    assert [%{id: ^id}] = results("pure_elixir")

    # The default is the count: nothing changes.
    assert {:dry_run, [%{version: "1.4.1"}]} = PureElixirWithdrawal.withdraw()
    assert {:dry_run, [_]} = PureElixirWithdrawal.withdraw(dry_run: true)
    assert [%{unpublished_at: nil}] = results("pure_elixir")

    assert {:withdrawn, 1, [%{version: "1.4.1", withdrawn_at: %DateTime{}}]} =
             PureElixirWithdrawal.withdraw(dry_run: false, before: @later)

    assert [%{unpublished_at: %DateTime{}}] = results("pure_elixir")
    assert PureElixirWithdrawal.candidates() == []

    # The run's firmware result and the file it shares stay published.
    assert [%{unpublished_at: nil}] = results("nerves_system_rpi4")
    assert Catalog.published_sha256?(@sha)

    assert Map.keys(Catalog.precompiled_manifest("jason").versions["1.4.1"]) == [
             "nerves_system_rpi4"
           ]
  end

  test "the run's only published file stops being served" do
    result = pure_elixir_result()
    {_rpi4, systems} = Map.pop(result["systems"], "nerves_system_rpi4")
    ingest_with_artifact(Map.put(result, "systems", systems))
    toolchain_build!(@host_read, %{})

    assert Catalog.published_sha256?(@sha)
    assert {:withdrawn, 1, [_]} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    refute Catalog.published_sha256?(@sha)
    assert Catalog.precompiled_manifest("jason") == nil
  end

  test "every R1 and R2 reason withdraws" do
    pure_elixir_run!()

    for reason <- [
          "compile-time host read: os:type/0",
          "compile-time host read in mix.exs: System.get_env/1 (mix.exs:3)",
          "compile-time write outside ebin: file:write_file/2 \"/tmp/x\"",
          "compile-time tracing or system flag: erlang:trace/3",
          "compile-time Elixir patch dependence: System.build_info/0 in X (lib/x.ex:1)",
          "bakes the build path: Elixir.X \"<root>\""
        ] do
      toolchain_build!(reason, %{})
      assert [%{reason: ^reason}] = PureElixirWithdrawal.candidates(), reason
    end
  end

  test "R3 taint, native calls, rebar3 rules, could-not-judge and rule 1 withdraw nothing" do
    pure_elixir_run!()

    # Each ingest replaces the previous 1.20/29 row of the same identity, so
    # every case is checked right after its own ingest.
    held = [
      "closure dependency observed the host: telemetry (sentinel missing)",
      # An R3 reason quoting the dependency's R1 refusal is still R3.
      "closure dependency observed the host: x (compile-time host read: os:type/0)",
      "calls natively built dependency at compile time: Elixir.Bcrypt.hash/1",
      "rebar3 build runs pre_hooks",
      "rebar3 build config unreadable"
    ]

    for reason <- held do
      toolchain_build!(reason, %{})
      assert PureElixirWithdrawal.candidates() == [], reason
      # Listed for a hand check, never acted on.
      assert [%{reason: ^reason}] = PureElixirWithdrawal.held(), reason
    end

    for {reason, observations} <- [
          {Portability.could_not_judge(), %{"problems" => ["x"]}},
          {"calls System.cmd/2", %{}}
        ] do
      toolchain_build!(reason, observations)
      assert PureElixirWithdrawal.candidates() == [], reason
      assert PureElixirWithdrawal.held() == [], reason
    end

    assert {:withdrawn, 0, []} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    assert [%{unpublished_at: nil}] = results("pure_elixir")
    assert Catalog.published_sha256?(@sha)
  end

  test "untraced, revoked, passing, other-toolchain, other-variant and stale builds withdraw nothing" do
    pure_elixir_run!()

    toolchain_build!(@host_read, nil)
    assert PureElixirWithdrawal.candidates() == []

    ingest_toolchain_build("jason", "1.4.1", toolchain: "1.20/29", elixir: "1.20.4", otp: "29")
    assert PureElixirWithdrawal.candidates() == []

    @host_read
    |> toolchain_build!(%{})
    |> Ash.Changeset.for_update(:revoke, %{})
    |> Ash.update!(domain: Catalog)

    assert PureElixirWithdrawal.candidates() == []

    toolchain_build!(@host_read, %{}, toolchain: "1.19/28", elixir: "1.19.1", otp: "28")
    toolchain_build!(@host_read, %{}, variant: :without)
    toolchain_build!(@host_read, %{}, builder_version: 0)
    assert PureElixirWithdrawal.candidates() == []

    # The toolchain is a parameter: the count can look at another one.
    assert [%{version: "1.4.1"}] = PureElixirWithdrawal.candidates("1.19/28")

    assert {:withdrawn, 0, []} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    assert [%{unpublished_at: nil}] = results("pure_elixir")
  end

  # Every pure_elixir row of the version goes, or an older
  # run's result moves up into the manifest and carried copies stay served.
  test "older runs of the version and carried copies are withdrawn with it" do
    pure_elixir_run!(%{"run_id" => "fixture-jason-old", "finished_at" => "2026-01-01T00:00:00Z"})
    pure_elixir_run!()

    pure_elixir_run!(%{
      "run_id" => "fixture-jason-targets",
      "scope" => "targets",
      "finished_at" => "2030-01-01T00:00:00Z",
      "systems" => Map.take(pure_elixir_result()["systems"], ["nerves_system_x86_64"])
    })

    restore_blob!()
    assert [_, _, _] = results("pure_elixir")
    assert [_] = Enum.filter(results("pure_elixir"), & &1.carried_from_run_id)
    toolchain_build!(@host_read, %{})

    assert [%{results: [_, _, _]}] = PureElixirWithdrawal.candidates()

    assert Map.has_key?(Catalog.precompiled_manifest("jason").versions["1.4.1"], "pure_elixir")
    assert {:withdrawn, 3, [_]} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    assert Enum.all?(results("pure_elixir"), & &1.unpublished_at)

    systems = Catalog.precompiled_manifest("jason").versions["1.4.1"]
    refute Map.has_key?(systems, "pure_elixir")
    assert Enum.all?(results("nerves_system_rpi4"), &is_nil(&1.unpublished_at))
  end

  test "acting without a before: cutoff writes nothing" do
    pure_elixir_run!()
    toolchain_build!(@host_read, %{})

    assert {:error, :before_required} = PureElixirWithdrawal.withdraw(dry_run: false)
    assert [%{unpublished_at: nil}] = results("pure_elixir")
    assert [_] = PureElixirWithdrawal.candidates()

    assert_raise ArgumentError, fn ->
      PureElixirWithdrawal.withdraw(dry_run: false, before: "x")
    end
  end

  # A full run after P1 published pure_elixir only because
  # its own traced compile passed, which the portal does not store, so the
  # toolchain build's refusal never withdraws it. The cutoff applies to the
  # run that built a result: a copy carried after the cutoff from an older
  # run goes with that run.
  test "only results built by runs inserted before the cutoff are withdrawn" do
    pure_elixir_run!(%{"run_id" => "fixture-jason-old", "finished_at" => "2026-01-01T00:00:00Z"})
    cutoff = DateTime.utc_now()

    pure_elixir_run!(%{
      "run_id" => "fixture-jason-targets",
      "scope" => "targets",
      "finished_at" => "2026-02-01T00:00:00Z",
      "systems" => Map.take(pure_elixir_result()["systems"], ["nerves_system_x86_64"])
    })

    pure_elixir_run!(%{"run_id" => "fixture-jason-p1", "finished_at" => "2030-01-01T00:00:00Z"})
    restore_blob!()
    toolchain_build!(@host_read, %{})

    # The count lists every row with when its run was inserted.
    assert [%{results: listed}] = PureElixirWithdrawal.candidates()

    assert [false, true, true] =
             Enum.map(listed, &(DateTime.compare(&1.built_at, cutoff) == :lt)) |> Enum.sort()

    assert {:dry_run, [%{results: [_, _]}]} = PureElixirWithdrawal.withdraw(before: cutoff)

    assert {:withdrawn, 2, [_]} = PureElixirWithdrawal.withdraw(dry_run: false, before: cutoff)

    [kept] = Enum.reject(results("pure_elixir"), & &1.unpublished_at)
    assert is_nil(kept.carried_from_run_id)
    assert Map.has_key?(Catalog.precompiled_manifest("jason").versions["1.4.1"], "pure_elixir")

    # Nothing left before the cutoff: no write and no log line.
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:withdrawn, 0, []} = PureElixirWithdrawal.withdraw(dry_run: false, before: cutoff)
      end)

    refute log =~ "withdrew"
  end

  test "a second withdrawal changes nothing" do
    pure_elixir_run!()
    toolchain_build!(@host_read, %{})

    assert {:withdrawn, 1, [%{withdrawn_at: first}]} =
             PureElixirWithdrawal.withdraw(dry_run: false, before: @later)

    assert {:withdrawn, 0, []} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    assert [%{unpublished_at: at}] = results("pure_elixir")
    assert DateTime.compare(at, first) == :eq
  end

  test "undo puts exactly one withdrawal back" do
    pure_elixir_run!()
    version_run!("1.4.2")
    toolchain_build!(@host_read, %{})

    toolchain_build!(@host_read, %{}, version: "1.4.2")

    assert {:withdrawn, 1, [%{version: "1.4.1", withdrawn_at: first}]} =
             PureElixirWithdrawal.withdraw(dry_run: false, limit: 1, before: @later)

    assert {:withdrawn, 1, [%{version: "1.4.2", withdrawn_at: second}]} =
             PureElixirWithdrawal.withdraw(dry_run: false, limit: 1, before: @later)

    assert [%{withdrawn_at: ^first, results: 1}, %{withdrawn_at: ^second, results: 1}] =
             Enum.sort_by(PureElixirWithdrawal.withdrawals(), & &1.withdrawn_at, DateTime)

    assert {:restored, 1} = PureElixirWithdrawal.undo(first)
    assert {:restored, 0} = PureElixirWithdrawal.undo(first)
    assert "1.4.1" in published_versions()
    assert [%{version: "1.4.1"}] = PureElixirWithdrawal.candidates()

    [withdrawn] = Enum.filter(results("pure_elixir"), & &1.unpublished_at)
    assert DateTime.compare(withdrawn.unpublished_at, second) == :eq
  end

  test "one call withdraws at most limit versions" do
    pure_elixir_run!()
    version_run!("1.4.2")
    version_run!("1.4.3")

    for version <- ["1.4.1", "1.4.2", "1.4.3"],
        do: toolchain_build!(@host_read, %{}, version: version)

    assert {:dry_run, [_, _, _]} = PureElixirWithdrawal.withdraw(limit: 1)

    assert {:withdrawn, 2, [_, _]} =
             PureElixirWithdrawal.withdraw(dry_run: false, limit: 2, before: @later)

    assert [%{version: "1.4.3"}] = PureElixirWithdrawal.candidates()
    assert {:withdrawn, 1, [_]} = PureElixirWithdrawal.withdraw(dry_run: false, before: @later)
    assert PureElixirWithdrawal.candidates() == []

    assert_raise ArgumentError, fn ->
      PureElixirWithdrawal.withdraw(dry_run: false, limit: 0, before: @later)
    end
  end
end
