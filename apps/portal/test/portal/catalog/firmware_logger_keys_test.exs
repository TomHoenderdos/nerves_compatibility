defmodule Portal.Catalog.FirmwareLoggerKeysTest do
  # Stream S11: every `Logger` macro reads `:logger`'s compile-time purge
  # keys with `Application.get_env/3` while the caller compiles, and no
  # `.app` lists them. A firmware build whose `compile_env` is not a trace's
  # is published with them, unset as the builder's compile read them, so a
  # client whose config purges calls misses instead of taking beams that
  # still make them.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import Portal.PinnedFixtures, only: [ingest_firmware: 3, pins: 1, unique: 0]

  alias Portal.Catalog

  @unset :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  @own %{"app" => "jason", "path" => ["decoding_integer_digit_limit"], "value" => @unset}
  @keys ~w(compile_time_purge_matching compile_time_purge_level always_evaluate_messages)
  @logger for key <- @keys, do: %{"app" => "logger", "path" => [key], "value" => @unset}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  defp result(rpi4) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("deps_lock", %{"decimal" => %{"version" => "2.1.1", "checksum" => "abc"}})
    |> Map.put("package_checksum", "outer")
    |> update_in(["systems", "nerves_system_rpi4"], &Map.merge(&1, rpi4))
  end

  defp rpi4_entry(result) do
    version = result["package"]["version"]
    lists = Catalog.precompiled_manifest_v2(result["package"]["name"])["versions"][version]

    ~w(builds builds_with_inputs)
    |> Enum.flat_map(&List.wrap(lists[&1]))
    |> Enum.find(&(&1["target"] == "nerves_system_rpi4"))
  end

  defp rpi4_build(result), do: Map.fetch!(rpi4_entry(result), "build")

  setup do
    previous = Application.get_env(:portal, :firmware_logger_keys)
    on_exit(fn -> restore(previous) end)
  end

  defp restore(nil), do: Application.delete_env(:portal, :firmware_logger_keys)
  defp restore(value), do: Application.put_env(:portal, :firmware_logger_keys, value)

  test "an untraced firmware result lists the logger keys, unset, after its own items" do
    result = ingest_with_artifact(result(%{"compile_env" => [@own]}))
    assert rpi4_build(result)["compile_env"] == [@own | @logger]
  end

  test "a result whose trace recorded its config reads is published as stored" do
    traced = [@own, hd(@logger)]
    result = ingest_with_artifact(result(%{"compile_env" => traced, "compile_inputs" => []}))
    assert rpi4_build(result)["compile_env"] == traced
  end

  test "a key the result already lists is not listed again" do
    set = %{hd(@logger) | "value" => "g2gCdwJva20AAAAA"}
    result = ingest_with_artifact(result(%{"compile_env" => [set]}))
    assert rpi4_build(result)["compile_env"] == [set | tl(@logger)]
  end

  test "a result whose compile_env could not be read is still not listed" do
    result = ingest_with_artifact(result(%{"compile_env" => nil}))
    assert rpi4_entry(result) == nil
  end

  test "NCC_FIRMWARE_LOGGER_KEYS=0 publishes the stored list alone" do
    Application.put_env(:portal, :firmware_logger_keys, false)
    result = ingest_with_artifact(result(%{"compile_env" => [@own]}))
    assert rpi4_build(result)["compile_env"] == [@own]
  end

  test "an untraced pinned firmware build lists them; a traced one does not" do
    untraced = unique()

    {:ok, _row} =
      ingest_firmware(untraced, pins(untraced), firmware: %{"compile_inputs" => nil})

    assert %{"builds_closure" => [%{"build" => build}]} =
             Catalog.precompiled_manifest_v2(untraced)["versions"]["1.0.0"]

    assert build["compile_env"] == @logger

    traced = unique()
    {:ok, _row} = ingest_firmware(traced, pins(traced), [])

    assert %{"builds_closure" => [%{"build" => build}]} =
             Catalog.precompiled_manifest_v2(traced)["versions"]["1.0.0"]

    assert build["compile_env"] == []
  end
end
