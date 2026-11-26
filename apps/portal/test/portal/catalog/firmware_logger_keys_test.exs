defmodule Portal.Catalog.FirmwareLoggerKeysTest do
  # Stream S11: a firmware build whose `compile_env` is not a trace's is
  # published with the compile-time config its files depend on that its
  # `.app` does not list: Logger's keys, which every `Logger` macro reads,
  # and the keys the package's own code read in a toolchain build of the same
  # version. Each item carries the value the builder's compile read, which
  # is what a user's Mix VM with no config of it reads (review B1, B2). Every
  # test checks the published items with the client's own comparison
  # (`Portal.Test.ClientCompileEnv`) in this VM, which has `:logger` and
  # `:elixir` loaded as a user's has.
  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures
  import Portal.PinnedFixtures, only: [ingest_firmware: 3, pins: 1, unique: 0]

  alias Portal.Catalog
  alias Portal.Test.ClientCompileEnv

  @unset :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
  @own %{"app" => "jason", "path" => ["decoding_integer_digit_limit"], "value" => @unset}
  @keys ~w(compile_time_purge_matching always_evaluate_messages compile_time_purge_level)

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "result.json"])

  # The fixture run, on the firmware image's Elixir minor (every served
  # firmware build is on 1.20).
  defp result(rpi4) do
    @fixture
    |> File.read!()
    |> Jason.decode!()
    |> Map.put("toolchain", %{"elixir" => "1.20.5", "erlang" => "29"})
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

  defp rpi4_env(result),
    do: rpi4_entry(result) |> Map.fetch!("build") |> Map.fetch!("compile_env")

  defp keys(env), do: Enum.map(env, &{&1["app"], &1["path"]})

  defp logger_keys, do: for(key <- @keys, do: {"logger", [key]})

  # What a user's project with this config compiles with: the client's
  # comparison, run with `config` put into this VM for the call.
  defp misses_with(items, config) do
    saved = for {app, key, _} <- config, do: {app, key, Application.fetch_env(app, key)}
    for {app, key, value} <- config, do: Application.put_env(app, key, value)

    try do
      ClientCompileEnv.misses(items)
    after
      for {app, key, before} <- saved do
        case before do
          {:ok, value} -> Application.put_env(app, key, value)
          :error -> Application.delete_env(app, key)
        end
      end
    end
  end

  setup do
    previous =
      for key <- [:firmware_logger_keys, :firmware_own_config_keys],
          do: {key, Application.get_env(:portal, key)}

    on_exit(fn -> Enum.each(previous, &restore/1) end)
  end

  defp restore({key, nil}), do: Application.delete_env(:portal, key)
  defp restore({key, value}), do: Application.put_env(:portal, key, value)

  # Review R1: published unset, `compile_time_purge_matching` and
  # `always_evaluate_messages` missed every client, whose Mix VM loads
  # `:logger` with its `.app` env.
  test "an untraced firmware result lists Logger's keys with the values a project with no config reads" do
    result = ingest_with_artifact(result(%{"compile_env" => [@own]}))
    env = rpi4_env(result)

    assert keys(env) == [{"jason", ["decoding_integer_digit_limit"]} | logger_keys()]
    assert ClientCompileEnv.misses(env) == []

    purge = [[level_lower_than: :info]]

    assert [%{"path" => ["compile_time_purge_matching"]}] =
             misses_with(env, [{:logger, :compile_time_purge_matching, purge}])

    assert [%{"path" => ["compile_time_purge_level"]}] =
             misses_with(env, [{:logger, :compile_time_purge_level, :info}])
  end

  test "a result whose trace recorded its config reads is published as stored" do
    traced = [@own]
    result = ingest_with_artifact(result(%{"compile_env" => traced, "compile_inputs" => []}))
    assert rpi4_env(result) == traced
  end

  test "a key the result already lists is not listed again" do
    set = %{
      "app" => "logger",
      "path" => ["compile_time_purge_matching"],
      "value" => "g2gCdwJva20AAAAA"
    }

    result = ingest_with_artifact(result(%{"compile_env" => [set]}))

    assert rpi4_env(result) |> Enum.filter(&(&1["path"] == ["compile_time_purge_matching"])) == [
             set
           ]
  end

  test "a result whose compile_env could not be read is still not listed" do
    result = ingest_with_artifact(result(%{"compile_env" => nil}))
    assert rpi4_entry(result) == nil
  end

  test "both switches at 0 publish the stored list alone" do
    Application.put_env(:portal, :firmware_logger_keys, false)
    Application.put_env(:portal, :firmware_own_config_keys, false)
    result = ingest_with_artifact(result(%{"compile_env" => [@own]}))
    assert rpi4_env(result) == [@own]
  end

  test "an untraced pinned firmware build lists them; a traced one does not" do
    untraced = unique()
    {:ok, _row} = ingest_firmware(untraced, pins(untraced), firmware: %{"compile_inputs" => nil})

    assert %{"builds_closure" => [%{"build" => build}]} =
             Catalog.precompiled_manifest_v2(untraced)["versions"]["1.0.0"]

    assert keys(build["compile_env"]) == logger_keys()
    assert ClientCompileEnv.misses(build["compile_env"]) == []

    traced = unique()
    {:ok, _row} = ingest_firmware(traced, pins(traced), [])

    assert %{"builds_closure" => [%{"build" => build}]} =
             Catalog.precompiled_manifest_v2(traced)["versions"]["1.0.0"]

    assert build["compile_env"] == []
  end

  describe "the package's own compile-time config reads" do
    defp read(owner, app, key),
      do: %{
        "owner" => owner,
        "mfa" => "application:get_env/3",
        "arg" => %{"app" => app, "key" => key}
      }

    defp item(app, key, value \\ @unset), do: %{"app" => app, "path" => [key], "value" => value}

    defp toolchain!(name, version, reads, env, opts \\ []) do
      defaults = [
        elixir: "1.20.3",
        otp: "29",
        toolchain: "1.20/29",
        compile_env: env,
        compile_env_rule: 1,
        compile_observations: %{"config_reads" => reads}
      ]

      ingest_toolchain_build(name, version, Keyword.merge(defaults, opts))
    end

    test "a key of an app Mix does not preload is listed unset; a user who sets it misses" do
      toolchain!(
        "jason",
        "1.4.1",
        [read("jason", "fx_cfg_app", "precision"), read("decimal", "fx_cfg_app", "rounding")],
        [item("fx_cfg_app", "precision"), item("fx_cfg_app", "rounding")]
      )

      result = ingest_with_artifact(result(%{"compile_env" => [@own]}))
      env = rpi4_env(result)

      assert keys(env) ==
               [{"jason", ["decoding_integer_digit_limit"]} | logger_keys()] ++
                 [{"fx_cfg_app", ["precision"]}]

      assert ClientCompileEnv.misses(env) == []
      assert [%{"app" => "fx_cfg_app"}] = misses_with(env, [{:fx_cfg_app, :precision, 28}])
    end

    # Review R2: with `NCC_FIRMWARE_LOGGER_KEYS=0` the package's own Logger
    # reads brought the Logger items back as unset, and `elixir ansi_enabled`
    # was published unset against the user's recorded value.
    test "a preloaded app's key keeps the value R5 recorded; the logger switch drops own Logger keys" do
      ansi = item("elixir", "ansi_enabled", ClientCompileEnv.value("elixir", "ansi_enabled"))
      level = item("logger", "compile_time_purge_level")

      toolchain!(
        "jason",
        "1.4.1",
        [
          read("jason", "elixir", "ansi_enabled"),
          read("jason", "logger", "compile_time_purge_level")
        ],
        [ansi, level]
      )

      Application.put_env(:portal, :firmware_logger_keys, false)
      env = rpi4_env(ingest_with_artifact(result(%{"compile_env" => []})))

      assert env == [ansi]
      assert ClientCompileEnv.misses(env) == []
    end

    test "a preloaded app's key whose recorded values differ at the build's Elixir minor is not listed" do
      toolchain!("jason", "1.4.1", [read("jason", "ex_unit", "assert_receive_timeout")], [
        item("ex_unit", "assert_receive_timeout")
      ])

      toolchain!(
        "jason",
        "1.4.1",
        [read("jason", "ex_unit", "assert_receive_timeout")],
        [
          item(
            "ex_unit",
            "assert_receive_timeout",
            ClientCompileEnv.value("elixir", "dbg_callback")
          )
        ],
        builder_version: 2
      )

      toolchain!(
        "jason",
        "1.4.1",
        [read("jason", "elixir", "dbg_callback")],
        [item("elixir", "dbg_callback", ClientCompileEnv.value("elixir", "dbg_callback"))],
        elixir: "1.19.5",
        otp: "28",
        toolchain: "1.19/28"
      )

      env = rpi4_env(ingest_with_artifact(result(%{"compile_env" => []})))
      assert keys(env) == logger_keys()
    end

    # Review N2: a trace names a read's owner by its app name.
    test "a read owned by the package's app name counts, when it differs from the Hex name" do
      name = unique()

      ingest_toolchain_build(name, "1.0.0",
        elixir: "1.20.3",
        otp: "29",
        toolchain: "1.20/29",
        compile_env: [item("fx_cfg_app", "k")],
        compile_env_rule: 1,
        compile_observations: %{"config_reads" => [read("other_app", "fx_cfg_app", "k")]},
        app_file: "other_app"
      )

      {:ok, _row} = ingest_firmware(name, pins(name), firmware: %{"compile_inputs" => nil})

      assert %{"builds_closure" => [%{"build" => build}]} =
               Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]

      assert keys(build["compile_env"]) == logger_keys() ++ [{"fx_cfg_app", ["k"]}]
    end

    test "another version's reads, an unmarked build's and a dependency's reads are not" do
      toolchain!("jason", "1.4.0", [read("jason", "fx_cfg_app", "precision")], [
        item("fx_cfg_app", "precision")
      ])

      toolchain!(
        "jason",
        "1.4.1",
        [read("jason", "fx_cfg_app", "types")],
        [item("fx_cfg_app", "types")],
        compile_env_rule: nil
      )

      result = ingest_with_artifact(result(%{"compile_env" => []}))
      assert keys(rpi4_env(result)) == logger_keys()
    end

    # Review N1: without nerves_pack the builder's firmware config sets only
    # `:nerves`'s keys.
    test "only a key of the builder's own :nerves config is kept out" do
      reads =
        for {app, key} <- [{"nerves", "firmware"}, {"nerves_runtime", "kv_backend"}],
            do: read("jason", app, key)

      toolchain!("jason", "1.4.1", reads, [
        item("nerves", "firmware"),
        item("nerves_runtime", "kv_backend")
      ])

      env = rpi4_env(ingest_with_artifact(result(%{"compile_env" => []})))
      assert keys(env) == logger_keys() ++ [{"nerves_runtime", ["kv_backend"]}]
    end

    test "a traced result is published as stored" do
      toolchain!("jason", "1.4.1", [read("jason", "fx_cfg_app", "precision")], [
        item("fx_cfg_app", "precision")
      ])

      traced = ingest_with_artifact(result(%{"compile_env" => [], "compile_inputs" => []}))
      assert rpi4_env(traced) == []
    end

    test "NCC_FIRMWARE_OWN_CONFIG_KEYS=0 lists none of them" do
      toolchain!("jason", "1.4.1", [read("jason", "fx_cfg_app", "precision")], [
        item("fx_cfg_app", "precision")
      ])

      Application.put_env(:portal, :firmware_own_config_keys, false)
      env = rpi4_env(ingest_with_artifact(result(%{"compile_env" => []})))
      assert keys(env) == logger_keys()
    end

    test "an untraced pinned firmware build of the version lists them too" do
      name = unique()

      toolchain!(name, "1.0.0", [read(name, "fx_cfg_app", "precision")], [
        item("fx_cfg_app", "precision")
      ])

      {:ok, _row} = ingest_firmware(name, pins(name), firmware: %{"compile_inputs" => nil})

      assert %{"builds_closure" => [%{"build" => build}]} =
               Catalog.precompiled_manifest_v2(name)["versions"]["1.0.0"]

      assert keys(build["compile_env"]) == logger_keys() ++ [{"fx_cfg_app", ["precision"]}]
      assert ClientCompileEnv.misses(build["compile_env"]) == []
    end
  end
end
