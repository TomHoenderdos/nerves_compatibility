defmodule Compatibility.ForeignPrivTest do
  use ExUnit.Case, async: true

  alias Compatibility.ForeignPriv
  alias Compatibility.Portability, as: Reasons

  @fixtures Path.expand("../fixtures/kino_assets", __DIR__)
  @js_sha "e65c8f611e5e7a55a7088345ef7e3029348655b94874bca4222cd9f78f3289c6"
  @h "uxwh53kfq2wszgf23hqwgkuiza"
  @beams MapSet.new(["ebin/Elixir.Kino.VegaLite.beam", "ebin/Elixir.KinoVegaLite.ChartCell.beam"])

  defp js, do: File.read!(Path.join(@fixtures, "kino-0.19.1-js.ex"))

  # An outer Hex tarball whose contents.tar.gz holds `files` (`path => bytes`).
  defp hex_tarball(files) do
    contents = for {path, bytes} <- files, do: {String.to_charlist(path), bytes}
    gz = Path.join(System.tmp_dir!(), "fp-contents-#{System.unique_integer([:positive])}.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])
    outer = Path.join(System.tmp_dir!(), "fp-outer-#{System.unique_integer([:positive])}.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"metadata.config", ~s({<<"name">>,<<"kino">>}.\n)},
        {~c"contents.tar.gz", File.read!(gz)}
      ])

    bytes = File.read!(outer)
    File.rm!(gz)
    File.rm!(outer)
    bytes
  end

  defp entry(over \\ %{}) do
    Map.merge(
      %{
        "app" => "kino",
        "path" => "priv/assets/Kino_VegaLite/#{@h}.tar.gz",
        "sha256" => String.duplicate("0", 64),
        "size" => 10,
        "mode" => 33_188,
        "module" => "Elixir.Kino.VegaLite",
        "assets_path" => "lib/assets/vega_lite/build"
      },
      over
    )
  end

  test "dir_name/1 is the directory Kino.JS packs a module's assets in" do
    assert ForeignPriv.dir_name("Elixir.Kino.VegaLite") == "Kino_VegaLite"
    assert ForeignPriv.dir_name(KinoVegaLite.ChartCell) == "KinoVegaLite_ChartCell"
    assert ForeignPriv.dir_name("Elixir.A") == "A"
    assert ForeignPriv.dir_name("kino_erlang_module") == nil
    assert ForeignPriv.dir_name("Elixir.") == nil
    assert ForeignPriv.dir_name(nil) == nil
  end

  test "the reviewed table holds kino 0.19.1's js.ex and nothing else" do
    assert %{id: "kino_js_v1", target: "kino", version: "0.19.1", js_sha256: @js_sha} =
             ForeignPriv.reviewed("0.19.1", js())

    assert ForeignPriv.reviewed("0.19.0", js()) == nil
    assert ForeignPriv.reviewed("0.19.1", js() <> "\n") == nil
    assert ForeignPriv.reviewed(nil, js()) == nil

    assert ForeignPriv.rule("kino_js_v1").rm_rf ==
             {"Elixir.Kino.JS", "MACRO-__before_compile__", 2, 368}

    assert ForeignPriv.rule("kino_js_v1").mkdir_p ==
             {"Elixir.Kino.JS", "MACRO-__before_compile__", 2, 369}

    assert ForeignPriv.rule("kino_js_v1").archive == {"Elixir.Kino.JS", "package_assets!", 2, 435}
    assert ForeignPriv.rule("kino_js_v2") == nil
    assert ForeignPriv.rule(nil) == nil
  end

  test "reviewed_tarball/2 reads lib/kino/js.ex from a Hex tarball" do
    assert %{id: "kino_js_v1"} =
             ForeignPriv.reviewed_tarball("0.19.1", hex_tarball(%{"lib/kino/js.ex" => js()}))

    assert ForeignPriv.reviewed_tarball("0.19.1", hex_tarball(%{"mix.exs" => "x"})) == nil
    assert ForeignPriv.reviewed_tarball("0.19.1", "not a tarball") == nil
    assert ForeignPriv.reviewed_tarball("0.19.1", nil) == nil
  end

  test "parse_path/1 takes only priv/assets/<D>/<26 base32>.tar.gz" do
    assert {:ok, "Kino_VegaLite", @h} =
             ForeignPriv.parse_path("priv/assets/Kino_VegaLite/#{@h}.tar.gz")

    assert ForeignPriv.archive_path("Kino_VegaLite", @h) ==
             "priv/assets/Kino_VegaLite/#{@h}.tar.gz"

    a25 = String.duplicate("a", 25)

    for bad <- [
          "priv/assets/Kino_VegaLite/#{a25}.tar.gz",
          "priv/assets/Kino_VegaLite/#{a25}aa.tar.gz",
          "priv/assets/Kino_VegaLite/#{a25}1.tar.gz",
          "priv/assets/kino_VegaLite/#{@h}.tar.gz",
          "priv/assets/Kino.VegaLite/#{@h}.tar.gz",
          "priv/assets/Kino_VegaLite/#{@h}.tar",
          "priv/assets/../ebin/#{@h}.tar.gz",
          "priv/assets/Kino_VegaLite/sub/#{@h}.tar.gz",
          "/priv/assets/Kino_VegaLite/#{@h}.tar.gz",
          "priv/assets/Kino_VegaLite/#{@h}.tar.gz\n",
          nil
        ] do
      assert ForeignPriv.parse_path(bad) == :error, inspect(bad)
    end
  end

  test "check_entries/3 passes a well-formed list and refuses each malformed shape" do
    assert ForeignPriv.check_entries(nil, nil, @beams) == :ok
    assert ForeignPriv.check_entries([], nil, @beams) == :ok
    assert ForeignPriv.check_entries([entry()], "kino_js_v1", @beams) == :ok

    chart = "priv/assets/KinoVegaLite_ChartCell/#{@h}.tar.gz"

    two_dirs = [
      entry(),
      entry(%{"path" => chart, "module" => "Elixir.KinoVegaLite.ChartCell"})
    ]

    assert ForeignPriv.check_entries(two_dirs, "kino_js_v1", @beams) == :ok

    gone = "priv/assets/KinoVegaLite_Gone/#{@h}.tar.gz"

    cases = [
      {[entry()], nil, "unknown foreign priv rule"},
      {[entry()], "kino_js_v2", "unknown foreign priv rule"},
      {[], "kino_js_v1", "a foreign priv rule without entries"},
      {%{}, "kino_js_v1", "foreign_priv is not a list"},
      {List.duplicate(entry(), 65), "kino_js_v1", "more than 64 foreign priv files"},
      {[entry(%{"app" => "kino_db"})], "kino_js_v1", "foreign priv entry for another app"},
      {[entry(%{"path" => "priv/assets/Kino_VegaLite/x.tar.gz"})], "kino_js_v1",
       "malformed foreign priv path"},
      {[entry(%{"sha256" => "XYZ"})], "kino_js_v1", "malformed foreign priv entry"},
      {[entry(%{"size" => -1})], "kino_js_v1", "malformed foreign priv entry"},
      {[entry(%{"mode" => 33_261})], "kino_js_v1", "malformed foreign priv entry"},
      {[entry(%{"assets_path" => nil})], "kino_js_v1", "malformed foreign priv entry"},
      {[entry(%{"module" => "Elixir.Kino.Other"})], "kino_js_v1",
       "priv/assets/Kino_VegaLite is not the directory of Elixir.Kino.Other"},
      {[entry(%{"path" => gone, "module" => "Elixir.KinoVegaLite.Gone"})], "kino_js_v1",
       "Elixir.KinoVegaLite.Gone has no beam in the build"},
      {[entry(), entry(%{"sha256" => String.duplicate("1", 64)})], "kino_js_v1",
       "two entries for priv/assets/Kino_VegaLite"},
      {[entry(%{"size" => 10 * 1024 * 1024 + 1})], "kino_js_v1",
       "more than 10 MiB of foreign priv files"},
      {["not a map"], "kino_js_v1", "malformed foreign priv entry"}
    ]

    for {entries, rule, why} <- cases do
      assert {:error, reason} = ForeignPriv.check_entries(entries, rule, @beams)
      assert reason =~ why, inspect({Enum.take(List.wrap(entries), 1), rule, reason})
    end
  end

  test "manifest_entry/1 keeps what a manifest lists" do
    assert ForeignPriv.manifest_entry(entry()) ==
             Map.take(entry(), ["app", "path", "sha256", "size", "mode"])
  end

  test "the two refusals are trace refusals; only the read withdraws" do
    assert Reasons.refusal?(Reasons.foreign_priv_refused() <> "two writers of kino priv/assets/X")
    assert Reasons.refusal?(Reasons.foreign_priv_read() <> "file:read_file/1 /x")
    assert Reasons.withdraws?(Reasons.foreign_priv_read() <> "file:read_file/1 /x")

    refute Reasons.withdraws?(
             Reasons.foreign_priv_refused() <> "two writers of kino priv/assets/X"
           )
  end
end
