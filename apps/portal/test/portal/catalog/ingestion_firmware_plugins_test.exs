defmodule Portal.Catalog.IngestionFirmwarePluginsTest do
  # Ingests into the shared catalog.
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, SystemResult}

  require Ash.Query

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])
  @sha String.duplicate("a", 64)
  @release %{
    "name" => "rebar3_hex",
    "version" => "7.0.8",
    "sha256" => @sha,
    "owners" => ["yamerl"]
  }

  # A run of jason 1.4.0 whose rpi4 target carries `plugins` as its
  # `rebar3_plugins` (absent for `:absent`). `scope: "targets"` makes it a
  # partial run of `systems:` only.
  defp run!(plugins, opts \\ []) do
    fixture = @fixture |> File.read!() |> Jason.decode!()
    rpi4 = fixture["systems"]["nerves_system_rpi4"]
    rpi4 = if plugins == :absent, do: rpi4, else: Map.put(rpi4, "rebar3_plugins", plugins)

    systems =
      fixture["systems"]
      |> Map.put("nerves_system_rpi4", rpi4)
      |> Map.take(Keyword.get(opts, :systems, Map.keys(fixture["systems"])))

    result =
      fixture
      |> Map.merge(%{
        "run_id" => "fw-plugins-#{System.unique_integer([:positive])}",
        "package" => %{"name" => "jason", "version" => "1.4.0"},
        "finished_at" => Keyword.get(opts, :at, "2026-11-01T10:00:00Z"),
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
        version: "1.4.0",
        run_id: result["run_id"],
        image_digest: "sha256:precompiled",
        files_dir: System.tmp_dir!(),
        scan_request_id: nil,
        log: "log"
      })

    run
  end

  defp rpi4_of(run) do
    SystemResult
    |> Ash.Query.filter(run_id == ^run.id and system_pkg == "nerves_system_rpi4")
    |> Ash.read_one!(domain: Catalog)
  end

  test "stores a firmware target's rebar3 plugin record whole" do
    unread = %{"name" => "rebar3_odd", "version" => nil, "sha256" => nil, "owners" => ["x"]}
    run = run!([@release, unread])
    assert rpi4_of(run).rebar3_plugins == [@release, unread]
  end

  test "an empty record is kept: the target ran no plugin" do
    assert rpi4_of(run!([])).rebar3_plugins == []
  end

  test "a target without a record stores none" do
    assert rpi4_of(run!(:absent)).rebar3_plugins == nil
  end

  test "a malformed entry stores no record at all, and the ingest still succeeds" do
    for bad <- [
          [Map.put(@release, "version", 7)],
          [Map.delete(@release, "owners")],
          [Map.put(@release, "owners", [1])],
          [Map.put(@release, "sha256", "not hex")],
          [Map.put(@release, "name", "")],
          ["rebar3_hex"],
          %{"rebar3_hex" => "7.0.8"}
        ] do
      log = capture_log(fn -> assert rpi4_of(run!(bad)).rebar3_plugins == nil end)
      assert log =~ "rebar3_plugins malformed"
    end
  end

  test "extra keys inside a well-formed entry are stripped" do
    run = run!([Map.put(@release, "extra", "x")])
    assert rpi4_of(run).rebar3_plugins == [@release]
  end

  test "a record longer than the bound stores none rather than part of it" do
    many =
      for i <- 1..(SystemResult.max_plugin_releases() + 1),
          do: Map.put(@release, "version", "1.0.#{i}")

    log = capture_log(fn -> assert rpi4_of(run!(many)).rebar3_plugins == nil end)
    assert log =~ "rebar3_plugins malformed"
  end

  test "a carried copy keeps the record" do
    _full = run!([@release])
    partial = run!(:absent, scope: "targets", systems: ["host"], at: "2026-11-02T10:00:00Z")

    copy = rpi4_of(partial)
    assert copy.carried_from_run_id
    assert copy.rebar3_plugins == [@release]
  end
end
