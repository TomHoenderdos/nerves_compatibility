defmodule NccWorker.Portability.ForeignPrivTest do
  use ExUnit.Case, async: true

  alias NccWorker.KinoFixtures, as: K
  alias NccWorker.Portability
  alias NccWorker.Portability.{Context, ForeignPriv}

  @moduletag :tmp_dir

  defp scope(ctx), do: MapSet.new(Context.closure_of(ctx, ctx.package))
  defp gate(ctx, opts \\ [foreign_priv: true]), do: ForeignPriv.gate(ctx, scope(ctx), opts)

  describe "gate/3 (spec 3.1)" do
    test "opens when all four hold", %{tmp_dir: dir} do
      f = K.project(dir)

      assert %{
               rule: %{id: "kino_js_v1"},
               target: "kino",
               build: build,
               assets: assets,
               dirs: dirs
             } =
               gate(f.ctx)

      assert build == f.kino_build
      assert assets == f.assets
      assert dirs["kino_vega_lite"] == MapSet.new(~w(Kino_VegaLite KinoVegaLite_ChartCell))
      assert dirs["kino"] == MapSet.new(~w(Kino_JS Kino_HTML))
    end

    test "stays closed without the flag, in target mode, or for kino itself", %{tmp_dir: dir} do
      f = K.project(dir)
      assert gate(f.ctx, []) == nil
      assert gate(f.ctx, foreign_priv: "true") == nil
      assert gate(f.ctx, foreign_priv: true, target: "rpi4") == nil
      assert gate(f.ctx, foreign_priv: true, target: "host", host_native: true) == nil
      kino = %{f.ctx | package: "kino"}
      assert ForeignPriv.gate(kino, MapSet.new(["kino"]), foreign_priv: true) == nil
    end

    test "stays closed without kino in the closure, or kino native or not built by mix",
         %{tmp_dir: dir} do
      f = K.project(dir)
      assert ForeignPriv.gate(f.ctx, MapSet.new(["kino_vega_lite"]), foreign_priv: true) == nil
      assert gate(K.project(Path.join(dir, "n"), native: ["kino"]).ctx) == nil
      assert gate(K.project(Path.join(dir, "r"), kino_manager: "rebar3").ctx) == nil
    end

    test "stays closed when kino's build priv links to its sources", %{tmp_dir: dir} do
      assert gate(K.project(dir, link_kino_priv: true).ctx) == nil
    end

    test "stays closed for an unreviewed js.ex or kino release", %{tmp_dir: dir} do
      assert gate(K.project(Path.join(dir, "b"), js: K.js_ex() <> "\n").ctx) == nil
      assert gate(K.project(Path.join(dir, "v"), kino_version: "0.18.2").ctx) == nil
    end

    test "stays closed when another closure app also lists Kino.JS", %{tmp_dir: dir} do
      f =
        K.project(dir,
          writer_modules: ~w(Elixir.Kino.VegaLite Elixir.KinoVegaLite.ChartCell Elixir.Kino.JS)
        )

      assert gate(f.ctx) == nil
    end
  end

  test "stat/2: absent without the flag, on or off with it" do
    assert ForeignPriv.stat([], nil) == nil
    assert ForeignPriv.stat([foreign_priv: false], nil) == nil
    assert ForeignPriv.stat([foreign_priv: true], nil) == "off"
    assert ForeignPriv.stat([foreign_priv: true], %{rule: %{}}) == "on"
  end

  # Ruling 3: a verdict judged without the flag carries no new stat at all.
  test "judge/5 writes trace_stats foreign_priv only with the flag", %{tmp_dir: dir} do
    f = K.project(dir)
    base = [hex_home: f.home, releases: f.releases, built_check: false, nif_waiver: true]

    without = Portability.judge(f.proj, "kino_vega_lite", f.report, [], base)
    refute Map.has_key?(without.observations["trace_stats"], "foreign_priv")
    refute Map.has_key?(without, :foreign_priv)

    with_flag =
      Portability.judge(f.proj, "kino_vega_lite", f.report, [], [foreign_priv: true] ++ base)

    assert with_flag.observations["trace_stats"]["foreign_priv"] == "on"

    # Without the flag the observations are main's: the only key the flag
    # adds is the accepted calls' list.
    refute Map.has_key?(without.observations, "foreign_priv")
    assert Map.keys(with_flag.observations) -- Map.keys(without.observations) == ["foreign_priv"]
    assert Map.keys(without.observations) -- Map.keys(with_flag.observations) == []

    for opts <- [[target: "rpi4"], [target: "host", host_native: true]] do
      v = Portability.judge(f.proj, "kino_vega_lite", f.report, [], opts ++ base)
      refute Map.has_key?(v.observations, "foreign_priv"), inspect(opts)
    end
  end
end
