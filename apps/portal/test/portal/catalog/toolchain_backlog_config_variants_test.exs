defmodule Portal.Catalog.ToolchainBacklogConfigVariantsTest do
  # Not async: swaps the `Portal.Toolchains` application env, and recreates
  # the legacy identity index inside the sandbox transaction.
  use Portal.DataCase, async: false

  require Ash.Query

  import Portal.PrecompiledFixtures

  alias Compatibility.ConfigVariants
  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Package, ToolchainBuild}

  @pure %{"nif_language" => nil, "port_languages" => [], "compatibility_basis" => "pure_elixir"}
  @day 86_400
  @lv4 ~w(debug_attributes debug_heex_annotations enable_expensive_runtime_checks root_tag_attribute)

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      previous
      |> Keyword.merge(
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
      |> Keyword.delete(:config_variants)
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    :ok
  end

  defp run!(name, version) do
    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => version, "native_components" => @pure},
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          run_id: "run-#{name}-#{version}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!(),
          package: name,
          version: version
        }
      )

    :ok
  end

  defp downloads!(name, recent) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{hex_downloads_recent: recent})
    |> Ash.update!(domain: Catalog)
  end

  # The `compile_env` of a build that read each of `keys` of
  # `:phoenix_live_view`, all unset.
  defp lv_env(keys) do
    unset =
      :error |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

    for key <- keys, do: %{"app" => "phoenix_live_view", "path" => [key], "value" => unset}
  end

  # `marked: true` gives the row the R5 mark: rule 1 next to a `compile_env`
  # (the given one, else `[]`), written by the row's own run. A recorded
  # optional-deps report, so the backlog never asks the registry about it.
  defp row!(name, version, status, opts) do
    package = Package |> Ash.Query.filter(name == ^name) |> Ash.read_one!(domain: Catalog)
    marked? = Keyword.get(opts, :marked, false)
    config_variant = Keyword.get(opts, :config_variant, "default")

    row =
      ToolchainBuild
      |> Ash.Changeset.for_create(:create, %{
        package_id: package.id,
        version: version,
        toolchain: "1.19/28",
        builder_version: 1,
        variant: Keyword.get(opts, :variant, :with),
        config_variant: config_variant,
        status: status,
        deps_lock: Keyword.get(opts, :deps_lock, %{}),
        optional_deps: %{"added" => []},
        compile_env_rule: if(marked?, do: 1),
        compile_env: if(marked?, do: Keyword.get(opts, :compile_env, [])),
        run_id: "tc-#{name}-#{version}-#{config_variant}",
        finished_at: ago(Keyword.get(opts, :finished_days_ago, 30) * @day)
      })
      |> Ash.create!(domain: Catalog)

    if Keyword.get(opts, :revoked, false) do
      row |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    else
      row
    end
  end

  # A marked row of a named config variant that recorded its overlay.
  defp named_row!(name, version, config_variant, status, opts \\ []) do
    {:ok, items} = ConfigVariants.overlay(config_variant)

    env =
      for {app, key, value} <- items,
          do: %{"app" => "#{app}", "path" => ["#{key}"], "value" => ConfigVariants.encode(value)}

    row!(
      name,
      version,
      status,
      Keyword.merge(opts, marked: true, compile_env: env, config_variant: config_variant)
    )
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp named(rows) do
    rows
    |> Enum.reject(&(&1.config_variant == "default"))
    |> Enum.map(&{&1.package, &1.version, &1.config_variant})
  end

  defp with_toolchains_config(overrides, fun) do
    original = Application.get_env(:portal, Portal.Toolchains)
    Application.put_env(:portal, Portal.Toolchains, Keyword.merge(original, overrides))

    try do
      fun.()
    after
      Application.put_env(:portal, Portal.Toolchains, original)
    end
  end

  test "the gate: no named candidate while the legacy index exists (a rollback)" do
    recreate_legacy_identity_index!()
    run!("lvpkg", "1.0.0")
    row!("lvpkg", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
    assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == []
    assert Catalog.toolchain_counts()["1.19/28"].backlog == 0
  end

  describe "with the legacy index gone" do
    setup do
      drop_legacy_identity_index!()
      :ok
    end

    test "a LiveView-closure default wants all three; a non-reading package none" do
      for p <- ["lvpkg", "plain"], do: run!(p, "1.0.0")
      row!("lvpkg", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))

      row!("plain", "1.0.0", :pass,
        marked: true,
        compile_env: [%{"app" => "jason", "path" => ["x"], "value" => "e"}]
      )

      backlog = Catalog.toolchain_backlog("1.19/28", 1, 50)

      assert named(backlog) ==
               [
                 {"lvpkg", "1.0.0", "phx_prod"},
                 {"lvpkg", "1.0.0", "phx_test"},
                 {"lvpkg", "1.0.0", "phx_dev"}
               ]

      assert Enum.all?(backlog, &(&1.variant == :with and &1.refresh == false))
    end

    test "only a marked, served default pass yields variants" do
      for v <- ~w(1.0.0 1.1.0 1.2.0 1.3.0 1.4.0 1.5.0 1.6.0), do: run!("lvq", v)
      row!("lvq", "1.0.0", :pass, marked: false, compile_env: lv_env(@lv4))
      row!("lvq", "1.1.0", :skipped, marked: true, compile_env: lv_env(@lv4))
      row!("lvq", "1.2.0", :pass, marked: true, compile_env: lv_env(@lv4), revoked: true)
      row!("lvq", "1.3.0", :pass, marked: true, compile_env: lv_env(@lv4))
      # A closure the withheld list cannot judge: not served.
      row!("lvq", "1.4.0", :pass, marked: true, compile_env: lv_env(@lv4), deps_lock: nil)
      row!("lvq", "1.5.0", :fail, marked: true, compile_env: lv_env(@lv4))
      # Only a named row of its own, no default.
      named_row!("lvq", "1.6.0", "phx_prod", :pass)

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50))
             |> Enum.map(&elem(&1, 1))
             |> Enum.uniq() == ["1.3.0"]
    end

    test "a default marked by another run yields no variants" do
      run!("lvo", "1.0.0")
      row = row!("lvo", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET compile_env_run_id = 'other' WHERE id = $1",
        [Ecto.UUID.dump!(row.id)]
      )

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == []
    end

    test "variants come per optional-deps variant of the default" do
      run!("lvw", "1.0.0")
      row!("lvw", "1.0.0", :pass, marked: true, compile_env: lv_env(["root_tag_attribute"]))

      row!("lvw", "1.0.0", :pass,
        marked: true,
        variant: :without,
        compile_env: lv_env(["root_tag_attribute"])
      )

      assert Catalog.toolchain_backlog("1.19/28", 1, 50)
             |> Enum.reject(&(&1.config_variant == "default"))
             |> Enum.map(&{&1.variant, &1.config_variant})
             |> Enum.sort() ==
               [{:with, "phx_prod"}, {:without, "phx_prod"}]
    end

    test "a live named row removes its candidate; a day-old error reopens it" do
      run!("lvr", "1.0.0")
      row!("lvr", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
      named_row!("lvr", "1.0.0", "phx_prod", :pass)
      named_row!("lvr", "1.0.0", "phx_test", :error, finished_days_ago: 2)

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) ==
               [{"lvr", "1.0.0", "phx_test"}, {"lvr", "1.0.0", "phx_dev"}]
    end

    test "a fresh error, a recent fail or a revoked named row keeps it out" do
      run!("lvx", "1.0.0")
      row!("lvx", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
      named_row!("lvx", "1.0.0", "phx_prod", :error, finished_days_ago: 0)
      named_row!("lvx", "1.0.0", "phx_test", :fail, finished_days_ago: 2)
      named_row!("lvx", "1.0.0", "phx_dev", :pass, revoked: true)

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == []
    end

    test "a named row of another optional-deps variant is not live for this one" do
      run!("lvy", "1.0.0")
      row!("lvy", "1.0.0", :pass, marked: true, compile_env: lv_env(["root_tag_attribute"]))
      named_row!("lvy", "1.0.0", "phx_prod", :pass, variant: :without)

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == [{"lvy", "1.0.0", "phx_prod"}]
    end

    test "named after every default, before every refresh" do
      for p <- ["new", "lvs", "stale"], do: run!(p, "1.0.0")
      downloads!("new", 10)
      downloads!("lvs", 1_000_000)
      downloads!("stale", 5_000_000)
      row!("lvs", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
      row!("stale", "1.0.0", :pass, marked: false, finished_days_ago: 8)

      kinds =
        Catalog.toolchain_backlog("1.19/28", 1, 50)
        |> Enum.map(&{&1.package, &1.config_variant != "default", &1.refresh})

      assert [{"new", false, false} | rest] = kinds
      assert Enum.take(rest, 3) == List.duplicate({"lvs", true, false}, 3)
      assert List.last(kinds) == {"stale", false, true}
      assert length(kinds) == 5
    end

    test "NCC_CONFIG_VARIANTS narrows the set and re-ranks" do
      run!("lvt", "1.0.0")
      row!("lvt", "1.0.0", :pass, marked: true, compile_env: lv_env(["root_tag_attribute"]))

      assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == [{"lvt", "1.0.0", "phx_prod"}]

      with_toolchains_config([config_variants: ["phx_test"]], fn ->
        assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == [
                 {"lvt", "1.0.0", "phx_test"}
               ]
      end)

      with_toolchains_config([config_variants: []], fn ->
        assert named(Catalog.toolchain_backlog("1.19/28", 1, 50)) == []
        assert Catalog.toolchain_counts()["1.19/28"].backlog == 0
      end)
    end

    test "the SQL and ConfigVariants.wanted/2 agree on every subset of the overlay keys" do
      keys =
        ConfigVariants.names()
        |> Enum.flat_map(fn n ->
          {:ok, o} = ConfigVariants.overlay(n)
          o
        end)
        |> Enum.map(fn {app, key, _} -> {"#{app}", "#{key}"} end)
        |> Enum.uniq()

      subsets =
        for mask <- 0..(Bitwise.bsl(1, length(keys)) - 1) do
          for {k, i} <- Enum.with_index(keys), Bitwise.band(mask, Bitwise.bsl(1, i)) != 0, do: k
        end

      # One run makes the package; named candidates need only the default row.
      run!("sub", "0.0.0")

      for {subset, i} <- Enum.with_index(subsets) do
        env = for {app, key} <- subset, do: %{"app" => app, "path" => [key], "value" => "e"}
        row!("sub", "0.0.#{i}", :pass, marked: true, compile_env: env)
      end

      for enabled <- [ConfigVariants.names(), ["phx_test", "phx_dev"], ["phx_dev"]] do
        with_toolchains_config([config_variants: enabled], fn ->
          got =
            Catalog.toolchain_backlog("1.19/28", 1, 10_000)
            |> Enum.filter(&(&1.package == "sub" and &1.config_variant != "default"))
            |> Enum.group_by(& &1.version, & &1.config_variant)

          for {subset, i} <- Enum.with_index(subsets) do
            assert Map.get(got, "0.0.#{i}", []) == ConfigVariants.wanted(subset, enabled),
                   inspect({enabled, subset})
          end
        end)
      end
    end

    test "the admin count includes named candidates" do
      run!("lvu", "1.0.0")
      row!("lvu", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
      assert Catalog.toolchain_counts()["1.19/28"].backlog == 3
    end

    test "the release-download ranking leaves named candidates out" do
      run!("lvv", "1.0.0")
      downloads!("lvv", 100)
      row!("lvv", "1.0.0", :pass, marked: true, compile_env: lv_env(@lv4))
      assert Catalog.toolchain_backlog_to_rank(10, 10) == []
    end
  end
end
