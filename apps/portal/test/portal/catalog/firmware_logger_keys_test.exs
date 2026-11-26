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
    previous =
      for key <- [:firmware_logger_keys, :firmware_own_config_keys],
          do: {key, Application.get_env(:portal, key)}

    on_exit(fn -> Enum.each(previous, &restore/1) end)
  end

  defp restore({key, nil}), do: Application.delete_env(:portal, key)
  defp restore({key, value}), do: Application.put_env(:portal, key, value)

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
    Application.put_env(:portal, :firmware_own_config_keys, false)
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

  # The coordinator's ruling on S11's config_own: every config key the
  # package's own code reads at compile time, as a toolchain build of the
  # same version recorded it (R5: in its `compile_env`, its trace naming the
  # package as the reader), is listed unset on an untraced firmware build of
  # that version: the builder's firmware project sets none of them.
  describe "the package's own compile-time config reads" do
    defp read(owner, app, key),
      do: %{
        "owner" => owner,
        "mfa" => "application:get_env/3",
        "arg" => %{"app" => app, "key" => key}
      }

    defp item(app, key), do: %{"app" => app, "path" => [key], "value" => @unset}

    defp toolchain!(name, version, reads, env, rule \\ 1) do
      ingest_toolchain_build(name, version,
        compile_env: env,
        compile_env_rule: rule,
        compile_observations: %{"config_reads" => reads}
      )
    end

    test "a key its own code read in a toolchain build of the version is listed unset" do
      toolchain!(
        "jason",
        "1.4.1",
        [read("jason", "decimal", "precision"), read("decimal", "decimal", "rounding")],
        [item("decimal", "precision"), item("decimal", "rounding")]
      )

      result = ingest_with_artifact(result(%{"compile_env" => [@own]}))

      assert rpi4_build(result)["compile_env"] ==
               [@own | @logger] ++ [item("decimal", "precision")]
    end

    test "another version's reads, an unmarked build's and a dependency's reads are not" do
      toolchain!("jason", "1.4.0", [read("jason", "decimal", "precision")], [
        item("decimal", "precision")
      ])

      toolchain!("jason", "1.4.1", [read("jason", "mime", "types")], [item("mime", "types")], nil)

      result = ingest_with_artifact(result(%{"compile_env" => []}))
      assert rpi4_build(result)["compile_env"] == @logger
    end

    test "a key the builder's firmware config sets, or the result lists, is not listed again" do
      set = %{item("decimal", "precision") | "value" => "g2gCdwJva20AAAAA"}

      reads =
        for {app, key} <- [
              {"nerves_runtime", "kv_backend"},
              {"nerves", "firmware"},
              {"logger", "default_handler"},
              {"decimal", "precision"}
            ],
            do: read("jason", app, key)

      toolchain!(
        "jason",
        "1.4.1",
        reads,
        Enum.map(reads, &item(&1["arg"]["app"], &1["arg"]["key"]))
      )

      result = ingest_with_artifact(result(%{"compile_env" => [set]}))
      assert rpi4_build(result)["compile_env"] == [set | @logger]
    end

    test "a traced result is published as stored" do
      toolchain!("jason", "1.4.1", [read("jason", "decimal", "precision")], [
        item("decimal", "precision")
      ])

      traced = ingest_with_artifact(result(%{"compile_env" => [], "compile_inputs" => []}))
      assert rpi4_build(traced)["compile_env"] == []
    end

    test "NCC_FIRMWARE_OWN_CONFIG_KEYS=0 lists none of them" do
      toolchain!("jason", "1.4.1", [read("jason", "decimal", "precision")], [
        item("decimal", "precision")
      ])

      Application.put_env(:portal, :firmware_own_config_keys, false)
      untraced = ingest_with_artifact(result(%{"compile_env" => []}))
      assert rpi4_build(untraced)["compile_env"] == @logger
    end

    test "an untraced pinned firmware build of the version lists them too" do
      name = unique()

      toolchain!(name, "1.0.0", [read(name, "decimal", "precision")], [
        item("decimal", "precision")
      ])

      {:ok, _row} = ingest_firmware(name, pins(name), firmware: %{"compile_inputs" => nil})

      assert %{"builds_closure" => [%{"build" => build}]} =
               Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]

      assert build["compile_env"] == @logger ++ [item("decimal", "precision")]
    end
  end
end
