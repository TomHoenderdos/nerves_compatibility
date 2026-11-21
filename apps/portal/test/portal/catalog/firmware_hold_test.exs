defmodule Portal.Catalog.FirmwareHoldTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, SystemResult}

  require Ash.Query

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @probe "compile-time probe revoked (own)"
  @plugin "rebar3 plugin revoked"

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

      # The other targets of the run are not held.
      assert is_nil(result_of(new, "nerves_system_x86_64").unpublished_at)
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

      assert undo!(@probe, at) == 2
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

    test "a revocation of another target holds only that target" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(result_of(old, "nerves_system_x86_64"), @probe)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert is_nil(rpi4_of(new).unpublished_at)
      assert result_of(new, "nerves_system_x86_64").unpublished_reason == @probe
    end

    test "a host result is not held" do
      old = run!("1.4.0", "2026-11-01T10:00:00Z", "old-beam")
      _ = revoke!(result_of(old, "host"), @probe)

      new = run!("1.4.0", "2026-11-02T10:00:00Z", "new-beam")

      assert is_nil(result_of(new, "host").unpublished_at)
    end
  end
end
