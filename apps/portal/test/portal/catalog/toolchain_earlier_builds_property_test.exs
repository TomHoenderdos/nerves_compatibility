defmodule Portal.Catalog.ToolchainEarlierBuildsPropertyTest do
  @moduledoc """
  An earlier build (`Portal.Catalog.ToolchainBuild.EarlierBuilds`) is served
  as a virtual row of the row it hangs off: for random combinations of the
  row's state and the earlier build's own data (all of them, in a seeded
  random order), it is listed, in the same
  list, and its file is fetchable exactly when the same data stored as a
  standalone row of the row's identity and served-ness would be, and the
  row itself is served. Not async: drops the legacy identity index inside
  the sandbox.
  """

  use Portal.DataCase, async: false

  import Portal.PrecompiledFixtures

  alias Portal.Catalog

  @seed {20_261_116, 7, 11}
  @version "0.4.0"
  @live_view %{"version" => "1.1.0", "checksum" => "lv"}
  @needs_check [%{"kind" => "env_all"}]

  defp name, do: "virtual_#{System.unique_integer([:positive])}"

  defp closure(certifi, withheld?) do
    base = %{"certifi" => %{"version" => certifi, "checksum" => "c-#{certifi}"}}
    if withheld?, do: Map.put(base, "phoenix_live_view", @live_view), else: base
  end

  # Every combination, in a seeded random order: few enough to try all.
  defp combinations do
    for row <- [:served, :revoked, :skipped, :withheld, :stale],
        variant <- [:with, :world_phx],
        config <- ["default", "phx_prod"],
        earlier_withheld <- [true, false],
        earlier_stale <- [true, false],
        earlier_inputs <- [nil, @needs_check] do
      %{
        row: row,
        variant: variant,
        config: config,
        earlier_withheld: earlier_withheld,
        earlier_stale: earlier_stale,
        earlier_inputs: earlier_inputs
      }
    end
    |> Enum.shuffle()
  end

  # Config reads recorded (rule 1 next to a `compile_env`), as a named
  # variant must at ingest.
  defp build_opts(c, config) do
    env = if config == "default", do: [], else: overlay_env(config)
    [variant: c.variant, config_variant: config, compile_env: env, compile_env_rule: 1]
  end

  defp earlier_opts(c) do
    opts = build_opts(c, c.config) ++ [deps_lock: closure("2.18.0", c.earlier_withheld)]
    if c.earlier_inputs, do: [compile_inputs: c.earlier_inputs] ++ opts, else: opts
  end

  defp update!(row, set) do
    Repo.query!("UPDATE catalog_toolchain_builds SET #{set} WHERE id = $1", [
      Ecto.UUID.dump!(row.id)
    ])
  end

  # A release that does not know `compile_env_run_id` rebuilt it with its
  # own run id: the mark no longer vouches for its config reads.
  defp stale!(row), do: update!(row, "run_id = 'tc-stale-' || id::text")

  # The served-ness a virtual row inherits from its row.
  defp inherit!(row, :revoked), do: update!(row, "revoked_at = now()")
  defp inherit!(row, :skipped), do: update!(row, "status = 'skipped'")
  defp inherit!(_row, _state), do: :ok

  # The list the build of `certifi` and `config` is in, or nil.
  defp listed(name, certifi, config) do
    with %{"versions" => %{@version => version}} <- Catalog.precompiled_manifest_v2(name) do
      Enum.find(["builds", "builds_with_inputs", "builds_closure"], fn list ->
        Enum.any?(
          version[list] || [],
          &(get_in(&1, ["build", "deps", "certifi", "version"]) == certifi and
              (&1["build"]["config_variant"] || "default") == config)
        )
      end)
    end
  end

  defp fetchable?(row) do
    [%{"sha256" => sha}] = row.file_manifest["ebin"]
    Catalog.published_sha256?(sha)
  end

  defp check(c) do
    [parent_package, standalone_package] = [name(), name()]

    if c.config != "default" do
      for package <- [parent_package, standalone_package] do
        ingest_toolchain_build(
          package,
          @version,
          build_opts(c, "default") ++ [deps_lock: closure("2.10.0", false)]
        )
      end
    end

    # The earlier build, then the rebuild that keeps it on the row.
    earlier = ingest_toolchain_build(parent_package, @version, earlier_opts(c))
    if c.earlier_stale, do: stale!(earlier)

    row =
      ingest_toolchain_build(
        parent_package,
        @version,
        build_opts(c, c.config) ++ [deps_lock: closure("2.19.0", c.row == :withheld)]
      )

    assert [_] = row.earlier_builds
    if c.row in [:withheld, :stale], do: stale!(row)
    inherit!(row, c.row)

    # The same data as a standalone row of the row's served-ness.
    standalone = ingest_toolchain_build(standalone_package, @version, earlier_opts(c))
    if c.earlier_stale, do: stale!(standalone)
    inherit!(standalone, c.row)

    row_listed = listed(parent_package, "2.19.0", c.config)
    assert row_listed != nil == fetchable?(row), inspect(c)

    expected = if row_listed, do: listed(standalone_package, "2.18.0", c.config)
    assert listed(parent_package, "2.18.0", c.config) == expected, inspect(c)

    assert fetchable?(earlier) == (row_listed != nil and fetchable?(standalone)), inspect(c)
    expected
  end

  @tag timeout: 300_000
  test "an earlier build is served iff it would be as a standalone row and its row is served" do
    drop_legacy_identity_index!()
    :rand.seed(:exsss, @seed)

    outcomes = Enum.map(combinations(), &check/1)

    assert nil in outcomes
    assert "builds" in outcomes
    assert "builds_with_inputs" in outcomes
    assert "builds_closure" in outcomes
  end
end
