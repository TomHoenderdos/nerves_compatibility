defmodule NccWorker.Portability.ForeignPrivSettleTest do
  use ExUnit.Case, async: true

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.KinoFixtures, as: K
  alias NccWorker.Portability
  alias NccWorker.Portability.{Context, ForeignPriv}

  @moduletag :tmp_dir

  @vl "Kino_VegaLite"
  @chart "KinoVegaLite_ChartCell"
  @rm_rf %{
    "module" => "Elixir.Kino.JS",
    "function" => "MACRO-__before_compile__",
    "arity" => 2,
    "file" => "lib/kino/js.ex",
    "line" => 368
  }

  defp open(f) do
    scope = MapSet.new(Context.closure_of(f.ctx, f.ctx.package))
    %{f.ctx | foreign_priv: ForeignPriv.gate(f.ctx, scope, foreign_priv: true)}
  end

  # Copies the fixture archive of `d` into kino's priv; its file name.
  defp place(f, d, otp \\ "otp28") do
    src = K.archive(otp, d)
    File.mkdir_p!(Path.join(f.assets, d))
    File.cp!(src, Path.join([f.assets, d, Path.basename(src)]))
    Path.basename(src)
  end

  defp item(call, d, name, ts \\ 150),
    do: %{
      "call" => call,
      "dir" => d,
      "path" => "priv/assets/#{d}/#{name}",
      "hash" => Path.basename(name, ".tar.gz"),
      "ts" => ts
    }

  defp archive(owner, d, name, ts \\ 150),
    do: {owner, {:observe, "foreign_priv", item("archive", d, name, ts)}}

  defp stream(owner, d, name, ts \\ 151),
    do: {owner, {:observe, "foreign_priv", item("stream", d, name, ts)}}

  defp refusals(decided), do: for({owner, {:refuse, why}} <- decided, do: {owner, why})

  test "both archives settle into entries, and their directories are left out of kino's check",
       %{tmp_dir: dir} do
    f = K.project(dir)
    a = place(f, @vl)
    b = place(f, @chart)

    decided = [
      archive("kino_vega_lite", @vl, a),
      stream("kino_vega_lite", @vl, a),
      archive("kino_vega_lite", @chart, b)
    ]

    assert {^decided, %{entries: %{"kino_vega_lite" => entries}, exclude: exclude}} =
             ForeignPriv.settle(decided, open(f))

    assert exclude == ["priv/assets/#{@chart}", "priv/assets/#{@vl}"]
    [chart, vl] = Enum.sort_by(entries, & &1["path"])

    assert chart["path"] == "priv/assets/#{@chart}/" <> b
    assert chart["module"] == "Elixir.KinoVegaLite.ChartCell"
    assert chart["assets_path"] == "lib/assets/chart_cell"

    bytes = File.read!(K.archive("otp28", @vl))

    assert vl == %{
             "app" => "kino",
             "path" => "priv/assets/#{@vl}/" <> a,
             "sha256" => :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
             "size" => byte_size(bytes),
             "mode" => 33_188,
             "module" => "Elixir.Kino.VegaLite",
             "assets_path" => "lib/assets/vega_lite/build"
           }
  end

  test "a closed gate settles nothing and adds nothing", %{tmp_dir: dir} do
    f = K.project(dir)
    decided = [archive("kino_vega_lite", @vl, place(f, @vl))]
    assert ForeignPriv.settle(decided, f.ctx) == {decided, %{entries: %{}, exclude: []}}
  end

  test "kino's own window settles nothing and refuses nothing", %{tmp_dir: dir} do
    # A writer app with no asset beam, so only kino's window has calls.
    f = K.project(dir, writer_modules: ["Elixir.KinoVegaLite.Other"])
    name = String.duplicate("a", 26) <> ".tar.gz"
    File.mkdir_p!(Path.join(f.assets, "Kino_HTML"))
    File.write!(Path.join([f.assets, "Kino_HTML", name]), "x")
    decided = [archive("kino", "Kino_HTML", name, 50), stream("kino", "Kino_HTML", name, 51)]
    assert {^decided, %{entries: %{}, exclude: []}} = ForeignPriv.settle(decided, open(f))
  end

  test "S1: a second archive for one directory, or another window naming it", %{tmp_dir: dir} do
    f = K.project(dir)
    a = place(f, @vl)
    b = place(f, @chart)

    two = [
      archive("kino_vega_lite", @vl, a),
      archive("kino_vega_lite", @vl, a, 160),
      archive("kino_vega_lite", @chart, b)
    ]

    {out, %{entries: entries, exclude: []}} = ForeignPriv.settle(two, open(f))
    assert entries == %{}

    assert [
             {"kino_vega_lite",
              Reasons.foreign_priv_refused() <> "two writers of kino priv/assets/#{@vl}"}
           ] == refusals(out)

    other = [
      archive("kino_vega_lite", @vl, a),
      archive("kino_vega_lite", @chart, b),
      {"kino", {:observe, "foreign_priv", item("rm_rf", @vl, "")}}
    ]

    {out, _} = ForeignPriv.settle(other, open(f))

    assert refusals(out) == [
             {"kino_vega_lite",
              Reasons.foreign_priv_refused() <> "two writers of kino priv/assets/#{@vl}"}
           ]
  end

  test "S2: the directory holds its archive alone, a regular file that is not executable", %{
    tmp_dir: dir
  } do
    for {setup, why} <- [
          {fn d -> File.write!(Path.join(d, "extra.txt"), "x") end,
           "holds more than its archive"},
          {fn d -> d |> File.ls!() |> hd() |> then(&File.chmod!(Path.join(d, &1), 0o755)) end,
           "its archive is not a regular file without an execute bit"}
        ] do
      sub = K.project(Path.join(dir, "c#{System.unique_integer([:positive])}"))
      a = place(sub, @vl)
      b = place(sub, @chart)
      setup.(Path.join(sub.assets, @vl))

      {out, %{entries: entries}} =
        ForeignPriv.settle(
          [archive("kino_vega_lite", @vl, a), archive("kino_vega_lite", @chart, b)],
          open(sub)
        )

      assert entries == %{}

      assert refusals(out) == [
               {"kino_vega_lite",
                Reasons.foreign_priv_refused() <> "kino priv/assets/#{@vl}: " <> why}
             ]
    end
  end

  test "S2: the directory is a link", %{tmp_dir: dir} do
    f = K.project(dir)
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    a = Path.basename(K.archive("otp28", @vl))
    File.cp!(K.archive("otp28", @vl), Path.join(elsewhere, a))
    File.ln_s!(elsewhere, Path.join(f.assets, @vl))
    b = place(f, @chart)

    {out, _} =
      ForeignPriv.settle(
        [archive("kino_vega_lite", @vl, a), archive("kino_vega_lite", @chart, b)],
        open(f)
      )

    assert refusals(out) == [
             {"kino_vega_lite",
              Reasons.foreign_priv_refused() <>
                "kino priv/assets/#{@vl}: is not a directory of its own"}
           ]
  end

  test "S3: a directory of kino's own", %{tmp_dir: dir} do
    f = K.project(dir, kino_modules: ~w(Elixir.Kino.JS Elixir.Kino.VegaLite))
    a = place(f, @vl)
    b = place(f, @chart)

    {out, _} =
      ForeignPriv.settle(
        [archive("kino_vega_lite", @vl, a), archive("kino_vega_lite", @chart, b)],
        open(f)
      )

    assert refusals(out) == [
             {"kino_vega_lite",
              Reasons.foreign_priv_refused() <> "kino priv/assets/#{@vl}: is kino's own"}
           ]
  end

  test "S4: an asset module without its archive, an archive no module of the writer packs",
       %{tmp_dir: dir} do
    f = K.project(dir)
    a = place(f, @vl)
    {out, _} = ForeignPriv.settle([archive("kino_vega_lite", @vl, a)], open(f))

    assert [
             {"kino_vega_lite",
              "foreign priv write refused: Elixir.KinoVegaLite.ChartCell has assets but no archive"}
           ] =
             refusals(out)

    g = K.project(Path.join(dir, "g"))
    a = place(g, @vl)
    b = place(g, @chart)
    gone = String.duplicate("b", 26) <> ".tar.gz"
    File.mkdir_p!(Path.join(g.assets, "Kino_Gone"))
    File.write!(Path.join([g.assets, "Kino_Gone", gone]), "x")

    decided = [
      archive("kino_vega_lite", @vl, a),
      archive("kino_vega_lite", @chart, b),
      archive("kino_vega_lite", "Kino_Gone", gone)
    ]

    {out, _} = ForeignPriv.settle(decided, open(g))

    assert [
             {"kino_vega_lite",
              "foreign priv write refused: kino priv/assets/Kino_Gone: no module of kino_vega_lite packs it"}
           ] = refusals(out)
  end

  test "S5: an archive whose members are not the package's", %{tmp_dir: dir} do
    f = K.project(dir)
    a = place(f, @vl)
    b = place(f, @chart)
    target = Path.join([f.assets, @vl, a])
    {:ok, [{name, bytes}]} = :erl_tar.extract(String.to_charlist(target), [:memory, :compressed])
    File.rm!(target)

    :ok =
      :erl_tar.create(String.to_charlist(target), [{name, bytes <> "// changed"}], [:compressed])

    {out, _} =
      ForeignPriv.settle(
        [archive("kino_vega_lite", @vl, a), archive("kino_vega_lite", @chart, b)],
        open(f)
      )

    assert [{"kino_vega_lite", why}] = refusals(out)

    assert String.starts_with?(
             why,
             Reasons.foreign_priv_refused() <> "kino priv/assets/#{@vl}: archive members differ"
           )
  end

  test "S6: more than 64 archives refuse before any is read", %{tmp_dir: dir} do
    f = K.project(dir)

    many =
      for i <- 1..65,
          do: archive("kino_vega_lite", "Kino_D#{i}", String.duplicate("a", 26) <> ".tar.gz")

    {out, _} = ForeignPriv.settle(many, open(f))

    assert [{"kino_vega_lite", "foreign priv write refused: more than 64 foreign priv files"}] =
             refusals(out)
  end

  test "F4: an open no archive call made, or a second one", %{tmp_dir: dir} do
    f = K.project(dir)
    a = place(f, @vl)
    b = place(f, @chart)
    base = [archive("kino_vega_lite", @vl, a), archive("kino_vega_lite", @chart, b)]

    for extra <- [
          [stream("kino_vega_lite", @vl, a, 140)],
          [stream("kino_vega_lite", @vl, a), stream("kino_vega_lite", @vl, a, 152)]
        ] do
      {out, %{entries: entries}} = ForeignPriv.settle(base ++ extra, open(f))
      assert entries == %{}
      assert [{"kino_vega_lite", why}] = refusals(out)

      assert String.starts_with?(
               why,
               Reasons.foreign_priv_refused() <> "an open of kino priv/assets/#{@vl}/"
             )
    end
  end

  # Ruling 4 (a): the whole judge on a hand-built trace of the real
  # kino_vega_lite 0.1.13 writing its two real archives, with the built
  # check on: kino's digest was taken when its window closed, before them.
  test "judge/5: the writer passes with its archives; without the flag kino's build changed",
       %{tmp_dir: dir} do
    f = K.project(dir)
    {:ok, kino_digest, _} = :ncc_tracer_digest.dir(f.kino_build)
    names = for d <- [@vl, @chart], into: %{}, do: {d, place(f, d)}
    {:ok, writer_digest, _} = :ncc_tracer_digest.dir(f.writer_build)

    events =
      names
      |> Enum.with_index()
      |> Enum.flat_map(fn {{d, name}, i} -> writer_events(f.assets, d, name, 150 + 10 * i) end)

    report = %{
      f.report
      | events: events,
        built: %{"kino" => %{digest: kino_digest}, "kino_vega_lite" => %{digest: writer_digest}}
    }

    opts = [hex_home: f.home, releases: f.releases, built_check: true, nif_waiver: true]

    v = Portability.judge(f.proj, "kino_vega_lite", report, [], [foreign_priv: true] ++ opts)

    assert %{status: :pass, foreign_priv_rule: "kino_js_v1"} = v,
           inspect(v.observations, pretty: true, limit: 60)

    assert v.foreign_priv |> Enum.map(&(&1["path"] |> Path.split() |> Enum.at(2))) |> Enum.sort() ==
             [@chart, @vl]

    assert v.observations["trace_stats"]["foreign_priv"] == "on"
    assert Enum.all?(v.observations["foreign_priv"], &(&1["owner"] == "kino_vega_lite"))
    refute Enum.any?(v.observations["foreign_priv"], &Map.has_key?(&1, "refusal"))

    v0 = Portability.judge(f.proj, "kino_vega_lite", report, [], opts)
    assert v0.status == :skip
    assert "built outside the trace: kino" in v0.observations["problems"]
    refute Map.has_key?(v0, :foreign_priv)
  end

  test "judge/5: a writer whose archives the trace never saw written refuses (S4)", %{
    tmp_dir: dir
  } do
    f = K.project(dir)

    opts = [
      hex_home: f.home,
      releases: f.releases,
      built_check: false,
      nif_waiver: true,
      foreign_priv: true
    ]

    v = Portability.judge(f.proj, "kino_vega_lite", f.report, [], opts)

    assert v.reason ==
             Reasons.foreign_priv_refused() <> "Elixir.Kino.VegaLite has assets but no archive"

    assert v.foreign_priv == nil

    # An app with no asset beam passes with foreign_priv [] and no rule.
    plain = K.project(Path.join(dir, "plain"), writer_modules: ["Elixir.KinoVegaLite.Other"])

    assert %{status: :pass, foreign_priv: [], foreign_priv_rule: nil} =
             Portability.judge(
               plain.proj,
               "kino_vega_lite",
               plain.report,
               [],
               Keyword.merge(opts, hex_home: plain.home, releases: plain.releases)
             )
  end

  defp writer_events(assets, d, name, ts) do
    dir = Path.join(assets, d)
    file = Path.join(dir, name)
    tool = %{"caller_kind" => "toolchain"}

    [
      ev(ts, "file_read", "file:read_link_info/2", dir, @rm_rf, tool),
      ev(
        ts + 1,
        "file_write",
        "file:make_dir/1",
        dir,
        %{@rm_rf | "line" => 369},
        Map.put(tool, "caller", %{
          "module" => "Elixir.File",
          "function" => "do_mkdir_p",
          "arity" => 1
        })
      ),
      ev(
        ts + 2,
        "file_write",
        "file:open/2",
        file,
        %{
          "module" => "Elixir.Kino.JS",
          "function" => "package_assets!",
          "arity" => 2,
          "file" => "lib/kino/js.ex",
          "line" => 435
        },
        tool
      ),
      ev(ts + 3, "file_write", "prim_file:open/2", file, nil, %{})
    ]
  end

  defp ev(ts, channel, mfa, path, user, extra) do
    Map.merge(
      %{
        "ts" => ts,
        "pid" => "<0.300.0>",
        "channel" => channel,
        "mfa" => mfa,
        "arg" => %{"path" => path},
        "extent" => if(user, do: "frame", else: "lineage"),
        "first" => %{"module" => "Elixir.File"},
        "user" => user
      },
      extra
    )
  end
end
