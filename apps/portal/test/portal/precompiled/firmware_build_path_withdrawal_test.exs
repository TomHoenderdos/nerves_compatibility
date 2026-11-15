defmodule Portal.Precompiled.FirmwareBuildPathWithdrawalTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Compatibility.Portability
  alias Portal.Catalog
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.SystemResult
  alias Portal.Precompiled.FirmwareBuildPathWithdrawal, as: Withdrawal

  require Ash.Query

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @baked "bakes the build path: Elixir.FxFw \"<root>/deps/fx/lib\""

  # A beam of `module` whose code holds `literal` (nil: nothing of the build).
  defp beam(module, literal) do
    body =
      if literal,
        do: "def p, do: Path.expand(\"x\", #{inspect(literal)})",
        else: "def p, do: :ok"

    [{^module, binary}] = Code.compile_string("defmodule #{inspect(module)} do #{body} end")
    :code.purge(module)
    :code.delete(module)
    binary
  end

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "fw-withdrawal-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  # A full run of jason `version` whose rpi4 target publishes `bytes` as its
  # one ebin file (and, with `variant:`, a "without" variant of those bytes).
  defp firmware_run!(version, bytes, opts \\ []) do
    dir = tmp_dir()
    File.write!(Path.join(dir, sha(bytes)), bytes)

    manifest = %{
      "ebin" => [
        %{
          "path" => "ebin/Elixir.Fx.beam",
          "sha256" => sha(bytes),
          "size" => byte_size(bytes),
          "mode" => 33_188
        }
      ],
      "priv" => []
    }

    rpi4 =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["systems", "nerves_system_rpi4"])
      |> Map.put("compile_env", [])
      |> Map.put("beam_scan", %{"footprint" => %{"file_manifest" => manifest}})

    rpi4 =
      if Keyword.get(opts, :variant, false) do
        Map.put(rpi4, "published_variants", [
          %{
            "variant" => "without",
            "beam_scan" => %{"footprint" => %{"file_manifest" => manifest}},
            "compile_env" => [],
            "deps_lock" => %{}
          }
        ])
      else
        rpi4
      end

    result =
      @fixture
      |> File.read!()
      |> Jason.decode!()
      |> Map.merge(%{
        "run_id" => "fw-jason-#{version}-#{System.unique_integer([:positive])}",
        "package" => %{"name" => "jason", "version" => version},
        "deps_lock" => %{},
        "package_checksum" => "outer"
      })
      |> put_in(["systems", "nerves_system_rpi4"], rpi4)

    {:ok, _run} =
      Ingestion.ingest(result, %{
        package: "jason",
        version: version,
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "log"
      })

    result
  end

  defp toolchain_build!(version, reason, opts \\ []) do
    dir = tmp_dir()

    result = %{
      "scope" => "toolchain",
      "finished_at" => "2026-11-06T10:00:00Z",
      "requested_optional_deps" => "include",
      "package" => %{"name" => "jason", "version" => version},
      "systems" => %{},
      "toolchain_build" => %{
        "status" => "skipped",
        "reason" => reason,
        "elixir" => "1.20.4",
        "otp" => "29",
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "compile_env" => [],
        "file_manifest" => nil,
        "portability_rule" => 2,
        "rule1_reason" => nil,
        "compile_observations" => %{"refusals" => []},
        "judge_revision" =>
          Keyword.get(opts, :judge_revision, Portability.withdrawal_judge_revision())
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
        toolchain: "1.20/29",
        builder_version: 1,
        variant: :with
      })

    tb
  end

  defp published_versions do
    case Catalog.precompiled_manifest("jason") do
      nil -> []
      manifest -> manifest.versions |> Map.keys() |> Enum.sort()
    end
  end

  defp rpi4_results do
    SystemResult
    |> Ash.Query.filter(system_pkg == "nerves_system_rpi4")
    |> Ash.read!(domain: Catalog)
  end

  defp unpublished(version) do
    for r <- rpi4_results(), version_of(r) == version, do: r.unpublished_at
  end

  defp version_of(result) do
    %{rows: [[v]]} =
      Repo.query!("SELECT version_tested FROM catalog_runs WHERE id = $1", [
        Ecto.UUID.dump!(result.run_id)
      ])

    v
  end

  test "a firmware result holding the build tree is counted, withdrawn and put back" do
    firmware_run!("1.4.1", beam(FxFwBaked, "/work/proj/deps_rpi4/fx/lib"))
    toolchain_build!("1.4.1", @baked)

    assert {:dry_run, %{confirmed: [row], clean: [], unreadable: [], next: next}} =
             Withdrawal.withdraw()

    assert %{package: "jason", version: "1.4.1", system_pkg: "nerves_system_rpi4"} = row
    assert row.reason == @baked
    assert row.holder == "ebin/Elixir.Fx.beam"
    assert next == nil
    assert [nil] = unpublished("1.4.1")
    assert published_versions() == ["1.4.1"]

    assert {:withdrawn, 1, %{confirmed: [%{id: id}], withdrawn_at: %DateTime{} = at}} =
             Withdrawal.withdraw(dry_run: false)

    assert id == row.id
    assert [%DateTime{}] = unpublished("1.4.1")
    assert published_versions() == []

    [%{unpublished_reason: reason}] = rpi4_results()
    assert reason == SystemResult.baked_build_path()

    # Idempotent: nothing is left to withdraw.
    assert {:withdrawn, 0, %{confirmed: [], withdrawn_at: nil}} =
             Withdrawal.withdraw(dry_run: false)

    assert [%{results: 1, versions: ["jason 1.4.1 nerves_system_rpi4"]}] =
             Withdrawal.withdrawals()

    assert {:restored, 1} = Withdrawal.undo(at)
    assert [nil] = unpublished("1.4.1")
    assert published_versions() == ["1.4.1"]
    assert {:restored, 0} = Withdrawal.undo(at)
  end

  test "a result whose files hold no build tree is listed as clean, never withdrawn" do
    firmware_run!("1.4.1", beam(FxFwClean, nil))
    toolchain_build!("1.4.1", @baked)

    assert {:dry_run, %{confirmed: [], clean: [%{version: "1.4.1"}]}} = Withdrawal.withdraw()
    assert {:withdrawn, 0, %{clean: [_]}} = Withdrawal.withdraw(dry_run: false)
    assert [nil] = unpublished("1.4.1")
  end

  test "without a toolchain build-path refusal a result is no candidate" do
    firmware_run!("1.4.1", beam(FxFwNoRefusal, "/work/proj/deps_rpi4/fx/lib"))
    toolchain_build!("1.4.1", "compile-time host read: os:type/0 in X.f/0 (lib/x.ex:2)")

    assert {:dry_run, %{confirmed: [], clean: [], unreadable: []}} = Withdrawal.withdraw()
  end

  test "a refusal by a judge older than the withdrawal floor is no evidence" do
    firmware_run!("1.4.1", beam(FxFwOldJudge, "/work/proj/deps_rpi4/fx/lib"))
    toolchain_build!("1.4.1", @baked, judge_revision: Portability.withdrawal_judge_revision() - 1)

    assert {:dry_run, %{confirmed: []}} = Withdrawal.withdraw()
  end

  # A toolchain build row of jason `version`, written directly.
  defp toolchain_row!(version, status, opts) do
    package =
      Catalog.Package |> Ash.Query.filter(name == "jason") |> Ash.read_one!(domain: Catalog)

    Catalog.ToolchainBuild
    |> Ash.Changeset.for_create(:create, %{
      package_id: package.id,
      version: version,
      toolchain: Keyword.get(opts, :toolchain, "1.20/29"),
      builder_version: Keyword.get(opts, :builder_version, 2),
      variant: Keyword.get(opts, :variant, :with),
      config_variant: "default",
      status: status,
      reason: Keyword.get(opts, :reason),
      deps_lock: %{},
      compile_observations: %{"refusals" => []},
      judge_revision: Portability.withdrawal_judge_revision(),
      run_id: "tc-row-#{System.unique_integer([:positive])}",
      finished_at: Keyword.fetch!(opts, :finished_at)
    })
    |> Ash.create!(domain: Catalog)
  end

  test "a refusal a later passing build of the version overturned is no evidence" do
    firmware_run!("1.4.1", beam(FxFwOverturned, "/work/proj/deps_rpi4/fx/lib"))
    toolchain_build!("1.4.1", @baked)

    # A pass that finished before the refusal does not overturn it.
    toolchain_row!("1.4.1", :pass, builder_version: 0, finished_at: ~U[2026-11-01 10:00:00Z])
    assert {:dry_run, %{confirmed: [_]}} = Withdrawal.withdraw()

    toolchain_row!("1.4.1", :pass, finished_at: ~U[2026-11-10 10:00:00Z])
    assert {:dry_run, %{confirmed: [], clean: [], unreadable: []}} = Withdrawal.withdraw()
  end

  test "a world variant's refusal is no evidence for a firmware build" do
    firmware_run!("1.4.1", beam(FxFwWorld, "/work/proj/deps_rpi4/fx/lib"))
    [world | _] = Catalog.ToolchainBuild.variants() -- [:with, :without]

    toolchain_row!("1.4.1", :skipped,
      variant: world,
      reason: @baked,
      finished_at: ~U[2026-11-10 10:00:00Z]
    )

    assert {:dry_run, %{confirmed: []}} = Withdrawal.withdraw()
  end

  test "a variant's files count for its result" do
    firmware_run!("1.4.1", beam(FxFwVariant, "/home/nerves/.mix/x"), variant: true)
    toolchain_build!("1.4.1", @baked)

    assert {:dry_run, %{confirmed: [%{version: "1.4.1"}]}} = Withdrawal.withdraw()
  end

  test "limit and max_bytes bound one call, next continues it" do
    for v <- ["1.4.1", "1.4.2", "1.4.3"] do
      firmware_run!(
        v,
        beam(:"Elixir.FxFwPage#{String.replace(v, ".", "")}", "/work/proj/deps_rpi4/#{v}")
      )

      toolchain_build!(v, @baked)
    end

    assert {:dry_run, %{confirmed: [_, _, _], next: nil}} = Withdrawal.withdraw()

    # The first result is always read; the budget stops before the second.
    assert {:dry_run, %{confirmed: [first], next: next}} = Withdrawal.withdraw(max_bytes: 1)
    assert next == first.id

    assert {:dry_run, %{confirmed: [second], next: next2}} =
             Withdrawal.withdraw(max_bytes: 1, after: next)

    assert next2 == second.id
    refute second.id == first.id

    assert {:withdrawn, 2, %{confirmed: [_, _], next: _}} =
             Withdrawal.withdraw(dry_run: false, limit: 2)

    assert {:withdrawn, 1, %{confirmed: [_]}} = Withdrawal.withdraw(dry_run: false, limit: 2)
    assert {:withdrawn, 0, _} = Withdrawal.withdraw(dry_run: false)
  end

  test "bad options raise" do
    assert_raise ArgumentError, fn -> Withdrawal.withdraw(limit: 0) end
    assert_raise ArgumentError, fn -> Withdrawal.withdraw(max_bytes: -1) end
    assert_raise ArgumentError, fn -> Withdrawal.withdraw(after: "nope") end
  end

  describe "holds_root?/1" do
    test "finds a root in the literal table, not in the metadata chunks" do
      assert :hit = Withdrawal.holds_root?(beam(FxFwLit, "/work/proj/deps_rpi4/fx/lib"))
      # `__ENV__.file` lives in CInf/Dbgi/Line here too: the clean beam has it.
      assert :clean = Withdrawal.holds_root?(beam(FxFwNone, nil))
    end

    test "inflates a compressed literal table and a gzipped beam" do
      plain = beam(FxFwZ, "/work/proj/deps_rpi4/fx/lib")
      assert :hit = Withdrawal.holds_root?(compress_literals(plain))
      assert :hit = Withdrawal.holds_root?(:zlib.gzip(plain))
      assert :clean = Withdrawal.holds_root?(:zlib.gzip(beam(FxFwZClean, nil)))
    end

    test "a .app is searched whole, a broken beam is an error" do
      assert :hit = Withdrawal.holds_root?("{application,fx,[{env,[{p,\"/work/proj/x\"}]}]}.")
      assert :clean = Withdrawal.holds_root?("{application,fx,[]}.")
      assert {:error, _} = Withdrawal.holds_root?("FOR1" <> <<1::32>> <> "BEAMxx")
    end
  end

  # The beam with its `LitT` table zlib-compressed, as OTP before 28 wrote it.
  defp compress_literals(<<"FOR1", _size::32, "BEAM", body::binary>>) do
    chunks =
      for {id, data} <- split(body, []) do
        data =
          case {id, data} do
            {"LitT", <<0::32, table::binary>>} ->
              <<byte_size(table)::32>> <> :zlib.compress(table)

            _ ->
              data
          end

        pad = rem(4 - rem(byte_size(data), 4), 4)
        <<id::binary, byte_size(data)::32, data::binary, 0::size(pad * 8)>>
      end

    body = IO.iodata_to_binary(["BEAM" | chunks])
    <<"FOR1", byte_size(body)::32, body::binary>>
  end

  defp split(<<>>, acc), do: Enum.reverse(acc)

  defp split(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)
    <<_::binary-size(pad), rest::binary>> = rest
    split(rest, [{id, data} | acc])
  end
end
