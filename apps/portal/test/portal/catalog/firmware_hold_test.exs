defmodule Portal.Catalog.FirmwareHoldTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, SystemResult}
  alias Portal.Precompiled.{Holds, PluginWatch}

  import Portal.PrecompiledFixtures, only: [plugin_registry: 1]

  require Ash.Query

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @probe "compile-time probe revoked (own)"
  @plugin "rebar3 plugin revoked"
  # A reason whose class is per system: a closure's taint.
  @taint "firmware withheld: closure toolchain refusal (S8 1b: taint)"
  @judge "firmware judge refusal"

  defp sha(bytes), do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower)

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "fw-hold-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp manifest(bytes) do
    %{
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
  end

  # A run of jason `version` finished at `at` whose rpi4 target publishes
  # `bytes`. `scope: "targets"` makes it a partial run of `systems:` only;
  # `rpi4:` merges into the rpi4 target's result.
  defp run!(version, at, bytes, opts \\ []) do
    dir = tmp_dir()
    File.write!(Path.join(dir, sha(bytes)), bytes)
    fixture = @fixture |> File.read!() |> Jason.decode!()

    rpi4 =
      fixture
      |> get_in(["systems", "nerves_system_rpi4"])
      |> Map.put("compile_env", [])
      |> Map.put("beam_scan", %{"footprint" => %{"file_manifest" => manifest(bytes)}})
      |> Map.put("build_root", %{"status" => "pass", "reason" => nil, "observations" => []})
      |> Map.merge(Keyword.get(opts, :rpi4, %{}))
      |> put_judge(Keyword.get(opts, :judge))

    systems =
      fixture["systems"]
      |> Map.put("nerves_system_rpi4", rpi4)
      |> Map.take(Keyword.get(opts, :systems, Map.keys(fixture["systems"])))

    result =
      fixture
      |> Map.merge(%{
        "run_id" => "fw-hold-#{version}-#{System.unique_integer([:positive])}",
        "package" => %{"name" => "jason", "version" => version},
        "deps_lock" => %{},
        "package_checksum" => "outer",
        "finished_at" => at,
        "systems" => systems
      })
      |> then(fn r ->
        case Keyword.get(opts, :scope) do
          nil -> r
          scope -> Map.put(r, "scope", scope)
        end
      end)

    {:ok, run} =
      Ingestion.ingest(result, %{
        package: "jason",
        version: version,
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: dir,
        scan_request_id: nil,
        log: "log"
      })

    run
  end

  # The worker's verdict: a "skipped" one has withheld the target's files.
  defp put_judge(rpi4, nil), do: rpi4

  defp put_judge(rpi4, %{"status" => "skipped"} = judge),
    do: rpi4 |> Map.put("firmware_judge", judge) |> Map.put("beam_scan", %{"footprint" => %{}})

  defp put_judge(rpi4, judge), do: Map.put(rpi4, "firmware_judge", judge)

  defp verdict(status, reason \\ nil, classes \\ []),
    do: %{"status" => status, "reason" => reason, "classes" => classes}

  defp result_of(run, system) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == ^system)
    |> Ash.read_one!(domain: Catalog)
  end

  defp rpi4_of(run), do: result_of(run, "nerves_system_rpi4")

  defp served_rpi4?(version) do
    case Catalog.precompiled_manifest_v2("jason") do
      nil ->
        false

      %{"versions" => versions} ->
        versions
        |> Map.get(version, %{})
        |> Map.get("builds", [])
        |> Enum.any?(&(&1["target"] == "nerves_system_rpi4"))
    end
  end

  # What a revocation snippet does (`otp-probe-r21-revoke.exs`): one
  # timestamp and reason for every row it takes.
  defp revoke!(result, reason) do
    at = NaiveDateTime.utc_now()

    Repo.query!(
      "UPDATE catalog_system_results SET unpublished_at = $1, unpublished_reason = $2 " <>
        "WHERE id = $3",
      [at, reason, Ecto.UUID.dump!(result.id)]
    )

    at
  end

  # And its undo: every row with that reason and timestamp.
  defp undo!(reason, at) do
    %{num_rows: n} =
      Repo.query!(
        "UPDATE catalog_system_results SET unpublished_at = NULL, unpublished_reason = NULL " <>
          "WHERE unpublished_reason = $1 AND unpublished_at = $2",
        [reason, at]
      )

    n
  end

  defp same_instant?(%DateTime{} = held, %NaiveDateTime{} = at),
    do: DateTime.to_naive(held) == at

  describe "a revocation of a firmware target's build" do
    test "holds a new run's build of the same version and target, with its reason and time" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      at = revoke!(rpi4_of(old), @probe)
      refute served_rpi4?("1.4.0")

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      held = rpi4_of(new)
      assert held.status == :pass
      assert held.unpublished_reason == @probe
      assert same_instant?(held.unpublished_at, at)
      refute served_rpi4?("1.4.0")

      # A probe is in the package's own code: the run's other firmware
      # target is held too (review S10), its host result never.
      assert result_of(new, "nerves_system_x86_64").unpublished_reason == @probe
      assert is_nil(result_of(new, "host").unpublished_at)
    end

    test "holds for a plugin revocation and for any other judge reason" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      at = revoke!(rpi4_of(old), @plugin)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert rpi4_of(new).unpublished_reason == @plugin
      assert same_instant?(rpi4_of(new).unpublished_at, at)
    end

    test "the revocation's undo puts the new run's build back with the old one" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      at = revoke!(rpi4_of(old), @probe)
      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      # The old build, and the new run's rpi4 and x86_64 (version-wide).
      assert undo!(@probe, at) == 3
      assert is_nil(rpi4_of(old).unpublished_at)
      assert is_nil(rpi4_of(new).unpublished_at)
      assert served_rpi4?("1.4.0")

      # Undone, it holds nothing any more.
      newer = run!("1.4.0", "2026-11-03T10:00:00Z", "newer-beam")
      assert is_nil(rpi4_of(newer).unpublished_at)
    end

    test "does not hold another version" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(rpi4_of(old), @probe)

      other = run!("1.4.1", "2026-11-02T10:00:00Z", "other-beam")

      assert is_nil(rpi4_of(other).unpublished_at)
      assert served_rpi4?("1.4.1")
    end

    test "holds a partial run that rebuilds the target" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      at = revoke!(rpi4_of(old), @probe)

      partial =
        run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam",
          scope: "targets",
          systems: ["nerves_system_rpi4"]
        )

      assert rpi4_of(partial).unpublished_reason == @probe
      assert same_instant?(rpi4_of(partial).unpublished_at, at)
      assert is_nil(rpi4_of(partial).carried_from_run_id)
    end

    test "takes the newest revocation when the target has several" do
      first = run!("1.4.0", "2026-11-01T10:00:00Z", "first-beam")
      second = run!("1.4.0", "2026-11-01T12:00:00Z", "second-beam")
      _ = revoke!(rpi4_of(first), @probe)
      at = revoke!(rpi4_of(second), @plugin)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert rpi4_of(new).unpublished_reason == @plugin
      assert same_instant?(rpi4_of(new).unpublished_at, at)
      assert [%{"reason" => @probe}] = rpi4_of(new).other_holds
    end

    test "holds a target whose new build fails too, as the rule-2 hold does" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(rpi4_of(old), @probe)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam", rpi4: %{"status" => "fail"})

      assert rpi4_of(new).status == :fail
      assert rpi4_of(new).unpublished_reason == @probe
    end
  end

  describe "withdrawals a new run judges again" do
    test "a baked build path or a newer refusal's withdrawal does not hold" do
      for reason <- [SystemResult.baked_build_path(), SystemResult.superseded_by_refusal()] do
        version = "1.5.#{System.unique_integer([:positive])}"
        old = run!(version, "2026-11-01T10:00:00Z", "old-beam-#{version}")
        _ = revoke!(rpi4_of(old), reason)

        new = run!(version, "2026-11-02T10:00:00Z", "new-beam-#{version}")

        assert is_nil(rpi4_of(new).unpublished_at), reason
        assert is_nil(rpi4_of(new).unpublished_reason), reason
      end
    end

    test "a withdrawal with no reason does not hold" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(rpi4_of(old), nil)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert is_nil(rpi4_of(new).unpublished_at)
    end

    test "a per-system reason on another target holds only that target" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(result_of(old, "nerves_system_x86_64"), @taint)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert is_nil(rpi4_of(new).unpublished_at)
      assert result_of(new, "nerves_system_x86_64").unpublished_reason == @taint
    end

    # Review S10: a probe or a plugin is in the package's own code, so it
    # is in a build for any system, also one the version was not revoked on.
    test "a probe or plugin revocation on one target holds every target of the version" do
      for reason <- [@probe, @plugin, "otp application probe revoked"] do
        version = "1.7.#{System.unique_integer([:positive])}"
        old = run!(version, "2026-11-01T10:00:00Z", "old-#{version}")
        at = revoke!(result_of(old, "nerves_system_x86_64"), reason)

        new = run!(version, "2026-11-02T10:00:00Z", "new-#{version}")

        assert rpi4_of(new).unpublished_reason == reason, reason
        assert same_instant?(rpi4_of(new).unpublished_at, at)
      end
    end

    test "a host result is not held" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(result_of(old, "host"), @probe)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert is_nil(result_of(new, "host").unpublished_at)
    end
  end

  # Review B1: the judge's own refusal holds as a judge-class revocation
  # does. Only the target's own traced pass is served over it.
  describe "a firmware judge refusal" do
    # Every way a target ends unjudged in the worker (`NccWorker.FirmwareInputs`).
    @unjudged [
      "firmware judge budget spent",
      "closure differs from the run's",
      "Nerves env exited 1",
      "run budget exhausted",
      "the traced compile's beams differ from the published ones",
      "compile-time host read: os:getenv/1 (HOME)",
      "no inputs"
    ]

    test "holds every later run of the target that is no judge pass, whatever the cause" do
      refused =
        run!("1.4.0", "2026-11-01T10:00:00Z", "refused",
          judge: verdict("skipped", "rebar3 build runs plugins", ["plugins_hooks"])
        )

      refusal = rpi4_of(refused)
      assert is_nil(refusal.unpublished_at)
      refute served_rpi4?("1.4.0")

      # Every unjudged cause, and the judge off (no verdict at all).
      later = Enum.map(@unjudged, &verdict("unjudged", &1)) ++ [nil]

      for {judge, i} <- Enum.with_index(later) do
        run = run!("1.4.0", "2026-11-02T1#{i}:00:00Z", "later-#{i}", judge: judge)

        held = rpi4_of(run)
        assert held.unpublished_reason == @judge, inspect(judge)
        assert held.unpublished_at == refusal.inserted_at
        refute served_rpi4?("1.4.0"), inspect(judge)
      end
    end

    test "a later traced pass of the target is served" do
      _ =
        run!("1.4.0", "2026-11-01T10:00:00Z", "refused",
          judge: verdict("skipped", "x", ["probe"])
        )

      pass = run!("1.4.0", "2026-11-02T10:00:00Z", "pass", judge: verdict("pass"))

      assert is_nil(rpi4_of(pass).unpublished_at)
      assert served_rpi4?("1.4.0")
    end

    test "a later run's own refusal joins the holds of the next run" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a", judge: verdict("skipped", "x", ["probe"]))
      b = run!("1.4.0", "2026-11-02T10:00:00Z", "b", judge: verdict("skipped", "y", ["probe"]))
      c = run!("1.4.0", "2026-11-03T10:00:00Z", "c")

      assert rpi4_of(c).unpublished_reason == @judge
      assert rpi4_of(c).unpublished_at == rpi4_of(b).inserted_at

      assert [%{"reason" => @judge, "at" => older}] = rpi4_of(c).other_holds
      assert older == rpi4_of(a).inserted_at |> DateTime.to_naive() |> NaiveDateTime.to_iso8601()
    end

    test "a probe or plugin refusal holds every system of the version; a taint only its own" do
      _ =
        run!("1.4.0", "2026-11-01T10:00:00Z", "a",
          judge: verdict("skipped", "rebar3 build runs plugins", ["plugins_hooks"])
        )

      later = run!("1.4.0", "2026-11-02T10:00:00Z", "b")
      assert result_of(later, "nerves_system_x86_64").unpublished_reason == @judge

      _ =
        run!("1.5.0", "2026-11-01T10:00:00Z", "c",
          judge:
            verdict(
              "skipped",
              "closure dependency observed the host: d (rebar3 build runs pre_hooks)",
              ["taint"]
            )
        )

      other = run!("1.5.0", "2026-11-02T10:00:00Z", "d")
      assert rpi4_of(other).unpublished_reason == @judge
      assert is_nil(result_of(other, "nerves_system_x86_64").unpublished_at)
    end

    test "a refusal in a revoked run holds nothing" do
      refused =
        run!("1.4.0", "2026-11-01T10:00:00Z", "a", judge: verdict("skipped", "x", ["probe"]))

      Repo.query!("UPDATE catalog_runs SET revoked_at = now() WHERE id = $1", [
        Ecto.UUID.dump!(refused.id)
      ])

      later = run!("1.4.0", "2026-11-02T10:00:00Z", "b")
      assert is_nil(rpi4_of(later).unpublished_at)
    end

    # The sweep side of the rule: a later build that is no judge pass,
    # ingested before the refusal arrived (a late remote lease), is
    # withdrawn by the refusal's ingest; a later pass is not.
    test "withdraws a later build that is no judge pass, ingested before the refusal" do
      early = run!("1.4.0", "2026-11-03T10:00:00Z", "early")
      pass = run!("1.4.0", "2026-11-04T10:00:00Z", "pass", judge: verdict("pass"))

      refused =
        run!("1.4.0", "2026-11-02T10:00:00Z", "a", judge: verdict("skipped", "x", ["probe"]))

      assert rpi4_of(early).unpublished_reason == @judge
      assert rpi4_of(early).unpublished_at == rpi4_of(refused).inserted_at
      assert is_nil(rpi4_of(pass).unpublished_at)
    end

    # Review S5: the judge's withdrawals have a reason of their own, so an
    # undo of R2's (`newer build path refusal`) never puts them back.
    test "its withdrawals of older builds carry the judge's reason, not R2's" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old")

      refused =
        run!("1.4.0", "2026-11-02T10:00:00Z", "a", judge: verdict("skipped", "x", ["probe"]))

      assert rpi4_of(old).unpublished_reason == @judge
      assert rpi4_of(old).unpublished_at == rpi4_of(refused).inserted_at
      refute rpi4_of(old).unpublished_reason == SystemResult.superseded_by_refusal()
    end

    test "an undo cannot release it: the refusal withdraws the rows again" do
      _ = run!("1.4.0", "2026-11-01T10:00:00Z", "old")

      refused =
        run!("1.4.0", "2026-11-02T10:00:00Z", "a", judge: verdict("skipped", "x", ["probe"]))

      later = run!("1.4.0", "2026-11-03T10:00:00Z", "b")
      at = DateTime.to_naive(rpi4_of(refused).inserted_at)

      assert {:ok, _counts} = Holds.undo(@judge, at)
      assert rpi4_of(later).unpublished_reason == @judge
      refute served_rpi4?("1.4.0")
    end
  end

  # Review S3 and S4: a row carries every hold it was given; an undo
  # releases only its own, keeps what else holds, and re-runs the
  # superseding refusals.
  describe "Holds.undo/2" do
    test "a row held twice stays withdrawn until both holds are undone" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      b = run!("1.4.0", "2026-11-01T12:00:00Z", "b")
      probe_at = revoke!(rpi4_of(a), @probe)
      taint_at = revoke!(rpi4_of(b), @taint)
      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new")

      assert rpi4_of(new).unpublished_reason == @taint
      assert [%{"reason" => @probe}] = rpi4_of(new).other_holds

      # `new` keeps its probe hold; `b`, released, is held again by the
      # probe revocation of the version (re-derived, below).
      assert {:ok, %{released: 0, kept: 2}} = Holds.undo(@taint, taint_at)
      assert rpi4_of(new).unpublished_reason == @probe
      assert same_instant?(rpi4_of(new).unpublished_at, probe_at)
      assert rpi4_of(new).other_holds in [nil, []]
      assert rpi4_of(b).unpublished_reason == @probe

      # a, b, and the new run's rpi4 and x86_64 (the probe is version-wide).
      assert {:ok, %{released: 4, kept: 0}} = Holds.undo(@probe, probe_at)
      assert Enum.all?([a, b, new], &is_nil(rpi4_of(&1).unpublished_at))
      assert served_rpi4?("1.4.0")
    end

    test "a bare undo of one hold of a row that has another fails, and serves nothing" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      b = run!("1.4.0", "2026-11-01T12:00:00Z", "b")
      _ = revoke!(rpi4_of(a), @probe)
      taint_at = revoke!(rpi4_of(b), @taint)
      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new")

      assert_raise Postgrex.Error, ~r/catalog_system_results_holds_withdrawn/, fn ->
        undo!(@taint, taint_at)
      end

      assert rpi4_of(new).unpublished_reason == @taint
    end

    test "re-runs the superseding refusals: a released row a newer refusal covers stays withdrawn" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      at = revoke!(rpi4_of(a), @taint)
      # A newer refusal, which skipped the already withdrawn row.
      _ = run!("1.4.0", "2026-11-02T10:00:00Z", "r", judge: verdict("skipped", "x", ["taint"]))
      assert rpi4_of(a).unpublished_reason == @taint

      assert {:ok, _} = Holds.undo(@taint, at)
      assert rpi4_of(a).unpublished_reason == @judge
    end

    test "re-applies a hold the released row never recorded" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      b = run!("1.4.0", "2026-11-01T12:00:00Z", "b")
      taint_at = revoke!(rpi4_of(a), @taint)
      # A later probe revocation of another row skipped the withdrawn one.
      probe_at = revoke!(rpi4_of(b), @probe)

      assert {:ok, _} = Holds.undo(@taint, taint_at)
      assert rpi4_of(a).unpublished_reason == @probe
      assert same_instant?(rpi4_of(a).unpublished_at, probe_at)
    end

    # The R2 undo (`FirmwareBuildPathWithdrawal.undo/1`) releases only its
    # own withdrawal too: a row another hold keeps stays out.
    test "the build path withdrawal's undo keeps a row's other holds" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      at = ~N[2026-11-15 17:23:55.529839]

      Repo.query!(
        "UPDATE catalog_system_results SET unpublished_at = $2, unpublished_reason = $3, " <>
          "other_holds = $4 WHERE id = $1",
        [
          Ecto.UUID.dump!(rpi4_of(a).id),
          at,
          SystemResult.baked_build_path(),
          [%{"reason" => @taint, "at" => "2026-11-21T10:00:00.000000"}]
        ]
      )

      assert {:restored, 0} = Portal.Precompiled.FirmwareBuildPathWithdrawal.undo(at)
      assert rpi4_of(a).unpublished_reason == @taint
      assert rpi4_of(a).other_holds in [nil, []]
    end

    test "lists a reason's holds by timestamp, with the rows each holds" do
      a = run!("1.4.0", "2026-11-01T10:00:00Z", "a")
      b = run!("1.4.0", "2026-11-01T12:00:00Z", "b")
      at = revoke!(rpi4_of(a), @taint)
      _ = revoke!(rpi4_of(b), @probe)
      _ = run!("1.4.0", "2026-11-02T10:00:00Z", "new")

      assert [{listed, 2}] = Holds.list(@taint)
      assert NaiveDateTime.compare(listed, at) == :eq
    end
  end

  # The plugin watch (stream S5) covers firmware results too: each passing
  # target's `rebar3_plugins` is recorded under its run, and `mix firmware`
  # ran them without the worker's pin check, so a release that is not a
  # reviewed one, with the reviewed checksum, withholds the target whatever
  # the watch holds.
  describe "the rebar3 plugin watch" do
    @reviewed_hex Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Map.keys() |> Enum.sort()

    defp plugin(name, version, sha),
      do: %{"name" => name, "version" => version, "sha256" => sha, "owners" => ["dep"]}

    defp pinned_hex do
      {version, sha} =
        Compatibility.RebarPlugins.pins()["rebar3_hex"] |> Enum.max_by(&elem(&1, 0))

      plugin("rebar3_hex", version, sha)
    end

    setup do
      PluginWatch.refresh(plugin_registry([{"rebar3_hex", @reviewed_hex}]))
      :ok
    end

    test "a target that ran only reviewed releases is served while the watch is clean" do
      _ = run!("1.4.0", "2026-11-01T10:00:00Z", "a", rpi4: %{"rebar3_plugins" => [pinned_hex()]})
      assert served_rpi4?("1.4.0")

      PluginWatch.refresh(plugin_registry([{"rebar3_hex", @reviewed_hex ++ ["99.0.0"]}]))
      refute served_rpi4?("1.4.0")
    end

    test "a release outside the review, or another tarball of a reviewed one, withholds it" do
      for {record, version} <- [
            {[plugin("rebar3_dirs", "0.1.0", String.duplicate("a", 64))], "1.5.0"},
            {[%{pinned_hex() | "sha256" => String.duplicate("b", 64)}], "1.5.1"},
            {[%{pinned_hex() | "version" => nil, "sha256" => nil}], "1.5.2"}
          ] do
        _ =
          run!(version, "2026-11-01T10:00:00Z", "x-" <> version,
            rpi4: %{"rebar3_plugins" => record}
          )

        refute served_rpi4?(version), inspect(record)
      end
    end

    # Review R3, the reviewer's T11: ingest stores no record for these (all
    # or nothing), and the watch must not read that as "no plugin": it marks
    # the run withheld, as S5 marks a toolchain build's (review S5 R3).
    test "a record over the bound, malformed, or not a list fails closed" do
      many = for i <- 1..65, do: plugin("rebar3_x#{i}", "1.0.#{i}", String.duplicate("a", 64))

      for {record, version} <- [
            {many, "1.6.0"},
            {[%{pinned_hex() | "sha256" => "not hex"}], "1.6.1"},
            {[Map.delete(pinned_hex(), "owners")], "1.6.2"},
            {%{"rebar3_hex" => "7.0.8"}, "1.6.3"},
            {"rebar3_hex", "1.6.4"}
          ] do
        run =
          run!(version, "2026-11-01T10:00:00Z", "m-" <> version,
            rpi4: %{"rebar3_plugins" => record}
          )

        assert rpi4_of(run).rebar3_plugins == nil, inspect(record, limit: 3)
        refute served_rpi4?(version), inspect(record, limit: 3)
      end
    end

    test "a target that ran no plugin is served" do
      _ = run!("1.4.0", "2026-11-01T10:00:00Z", "a", rpi4: %{"rebar3_plugins" => []})
      assert served_rpi4?("1.4.0")
    end
  end
end
