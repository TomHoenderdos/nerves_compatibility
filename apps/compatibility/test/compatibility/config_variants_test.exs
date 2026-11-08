defmodule Compatibility.ConfigVariantsTest do
  use ExUnit.Case, async: true

  alias Compatibility.ConfigVariants

  @lv ~w(root_tag_attribute debug_heex_annotations debug_attributes enable_expensive_runtime_checks)

  defp reads(app, keys), do: for(k <- keys, do: {app, k})

  # The value encoding a client decodes (client golden `enc/1`).
  defp enc(term),
    do: Base.url_encode64(:erlang.term_to_binary(term, [:deterministic]), padding: false)

  test "three named variants besides default, in rank order, pinned to phx_new 1.8.16" do
    assert ConfigVariants.default() == "default"
    assert ConfigVariants.names() == ["phx_prod", "phx_test", "phx_dev"]
    assert length(ConfigVariants.names()) <= 3
    assert ConfigVariants.phx_new_version() == "1.8.16"
    assert ConfigVariants.known?("default") and ConfigVariants.known?("phx_dev")
    refute ConfigVariants.known?("phx_staging") or ConfigVariants.known?(nil)
  end

  test "the overlays are phx_new 1.8.16's phoenix and LiveView keys per env" do
    assert {:ok, []} = ConfigVariants.overlay("default")
    assert :error = ConfigVariants.overlay("nope")

    assert {:ok, prod} = ConfigVariants.overlay("phx_prod")

    assert Enum.sort(prod) == [
             {:phoenix, :json_library, Jason},
             {:phoenix_live_view, :root_tag_attribute, "phx-r"}
           ]

    assert {:ok, test} = ConfigVariants.overlay("phx_test")

    assert Enum.sort(test) ==
             Enum.sort(
               prod ++
                 [
                   {:phoenix, :plug_init_mode, :runtime},
                   {:phoenix, :sort_verified_routes_query_params, true},
                   {:phoenix_live_view, :enable_expensive_runtime_checks, true}
                 ]
             )

    assert {:ok, dev} = ConfigVariants.overlay("phx_dev")

    assert Enum.sort(dev) ==
             Enum.sort(
               prod ++
                 [
                   {:phoenix, :plug_init_mode, :runtime},
                   {:phoenix, :stacktrace_depth, 20},
                   {:phoenix_live_view, :debug_attributes, true},
                   {:phoenix_live_view, :debug_heex_annotations, true},
                   {:phoenix_live_view, :enable_expensive_runtime_checks, true}
                 ]
             )
  end

  test "encode/1 is the compile_env value of {:ok, v}" do
    assert ConfigVariants.encode("phx-r") == enc({:ok, "phx-r"})
    assert ConfigVariants.encode(Jason) == enc({:ok, Jason})
  end

  test "reads/1 takes app and first path element of every item" do
    env = [
      %{"app" => "phoenix_live_view", "path" => ["root_tag_attribute"], "value" => "x"},
      %{"app" => "fx", "path" => ["a", "b"], "value" => "x"},
      %{"app" => "fx", "path" => [], "value" => "x"}
    ]

    assert ConfigVariants.reads(env) == [{"phoenix_live_view", "root_tag_attribute"}, {"fx", "a"}]
    assert ConfigVariants.reads(nil) == []
  end

  test "wanted/2: R7's table, with LiveView's closure-wide reads" do
    # Every LiveView-closure build records all four keys (closure-wide reads).
    assert ConfigVariants.wanted(reads("phoenix_live_view", @lv)) ==
             ["phx_prod", "phx_test", "phx_dev"]

    # The spec's component library: the three HEEx keys only.
    assert ConfigVariants.wanted(
             reads(
               "phoenix_live_view",
               ~w(root_tag_attribute debug_heex_annotations debug_attributes)
             )
           ) == ["phx_prod", "phx_dev"]

    assert ConfigVariants.wanted(reads("phoenix_live_view", ["root_tag_attribute"])) == [
             "phx_prod"
           ]

    assert ConfigVariants.wanted(reads("phoenix", ["plug_init_mode"])) == ["phx_test"]
    assert ConfigVariants.wanted([{"jason", "decoding_integer_digit_limit"}]) == []
    assert ConfigVariants.wanted([]) == []
  end

  test "wanted/2 ranks only the enabled variants" do
    lv = reads("phoenix_live_view", ["root_tag_attribute"])
    assert ConfigVariants.wanted(lv, ["phx_test", "phx_dev"]) == ["phx_test"]
    assert ConfigVariants.wanted(lv, []) == []
  end

  test "rows/1 flattens the enabled overlays for the backlog SQL" do
    rows = ConfigVariants.rows(["phx_prod", "phx_dev"])

    assert {"phx_prod", 1, "phoenix_live_view", "root_tag_attribute",
            "phoenix_live_view root_tag_attribute " <> v} =
             Enum.find(rows, &match?({"phx_prod", _, "phoenix_live_view", _, _}, &1))

    assert v == enc({:ok, "phx-r"})

    assert Enum.all?(rows, fn {name, rank, _, _, _} ->
             {name, rank} in [{"phx_prod", 1}, {"phx_dev", 2}]
           end)
  end

  test "overlay_recorded/2 wants every recorded overlay key at the overlay's value" do
    ok = [
      %{
        "app" => "phoenix_live_view",
        "path" => ["root_tag_attribute"],
        "value" => enc({:ok, "phx-r"})
      },
      %{"app" => "phoenix_live_view", "path" => ["debug_attributes"], "value" => enc(:error)}
    ]

    assert :ok = ConfigVariants.overlay_recorded("phx_prod", ok)

    assert {:error, "config variant did not record its overlay"} =
             ConfigVariants.overlay_recorded("phx_prod", [])

    wrong = [
      %{"app" => "phoenix_live_view", "path" => ["root_tag_attribute"], "value" => enc(:error)}
    ]

    assert {:error,
            "config variant recorded phoenix_live_view root_tag_attribute with another value"} =
             ConfigVariants.overlay_recorded("phx_prod", wrong)

    assert {:error, "config variant did not record its overlay"} =
             ConfigVariants.overlay_recorded("phx_prod", nil)
  end

  @tag :tmp_dir
  test "render/1 is a config file Config.Reader reads back to the overlay", %{tmp_dir: dir} do
    for name <- ConfigVariants.names() do
      {:ok, overlay} = ConfigVariants.overlay(name)
      path = Path.join(dir, "#{name}.exs")
      File.write!(path, ConfigVariants.render(overlay))
      config = Config.Reader.read!(path, env: :prod)

      for {app, key, value} <- overlay do
        assert config[app][key] == value, "#{name} #{app} #{key}"
      end

      assert Enum.sort(Keyword.keys(config)) ==
               overlay |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort()
    end
  end
end
