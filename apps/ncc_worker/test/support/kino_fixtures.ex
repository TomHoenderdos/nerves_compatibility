defmodule NccWorker.KinoFixtures do
  @moduledoc """
  The real kino_vega_lite 0.1.13 build and kino 0.19.1's `lib/kino/js.ex`
  (`apps/compatibility/test/fixtures/kino_assets`, made by its `regen.sh`),
  and a project laid out as a traced toolchain build leaves one: kino and
  kino_vega_lite under `deps/` and `_build/host/lib`, their verified Hex
  tarballs in a Hex cache, for the foreign priv judge's tests.
  """

  alias NccWorker.Portability.Context
  alias NccWorker.Tracer.Report

  @dir Path.expand("../../../compatibility/test/fixtures/kino_assets", __DIR__)
  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}

  def dir, do: @dir
  def js_ex, do: File.read!(Path.join(@dir, "kino-0.19.1-js.ex.txt"))
  def writer_tarball, do: File.read!(Path.join(@dir, "kino_vega_lite-0.1.13.tar"))
  def beam(module), do: File.read!(Path.join(@dir, module <> ".beam"))

  @doc "The fixture archive of directory `d` packed on `otp` (`\"otp28\"`): its path."
  def archive(otp, d), do: hd(Path.wildcard(Path.join([@dir, otp, d, "*.tar.gz"])))

  @doc "An outer Hex tarball of `name` `version` whose contents hold `files`."
  def hex_tarball(name, version, files) do
    contents = for {path, bytes} <- files, do: {String.to_charlist(path), bytes}
    tmp = Path.join(System.tmp_dir!(), "kf-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    gz = Path.join(tmp, "contents.tar.gz")
    :ok = :erl_tar.create(String.to_charlist(gz), contents, [:compressed])

    meta =
      [{"name", name}, {"version", version}, {"files", Map.keys(files)}, {"build_tools", ["mix"]}]
      |> Enum.map_join(&(:io_lib.format(~c"~p.~n", [&1]) |> IO.chardata_to_string()))

    outer = Path.join(tmp, "outer.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"metadata.config", meta},
        {~c"contents.tar.gz", File.read!(gz)}
      ])

    bytes = File.read!(outer)
    File.rm_rf!(tmp)
    bytes
  end

  @doc "Puts `tarball` in Hex cache `home` and returns its lock snapshot entry."
  def release(home, name, version, tarball) do
    dir = Path.join(home, "packages/hexpm")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "#{name}-#{version}.tar"), tarball)

    %{
      name: name,
      version: version,
      checksum: :sha256 |> :crypto.hash(tarball) |> Base.encode16(case: :lower)
    }
  end

  @doc """
  `root/proj` with kino 0.19.1 (a tarball holding the real js.ex) and the
  real kino_vega_lite 0.1.13 built under `_build/host/lib`, and a report of
  their two windows (kino 0-100, kino_vega_lite 101-200). Options:
  `:js` (kino's js.ex bytes), `:kino_version`, `:kino_modules`,
  `:writer_modules`, `:writer_beams` (`%{module => beam}` in place of the
  real beams), `:writer_tarball` (kino_vega_lite's tarball), `:kino_manager`,
  `:native` (apps built natively), `:link_kino_priv` (kino's build priv a
  link into deps/kino/priv), `:events`, and `:package`, an app that depends
  on kino_vega_lite (one Erlang module, window 201-300) judged in its place,
  so kino_vega_lite is a closure dependency.
  """
  def project(root, opts \\ []) do
    proj = Path.join(root, "proj")
    home = Path.join(root, "hex")
    File.mkdir_p!(proj)
    File.write!(Path.join(proj, "mix.exs"), "")
    kino_version = Keyword.get(opts, :kino_version, "0.19.1")

    kino_tar =
      hex_tarball("kino", kino_version, %{"lib/kino/js.ex" => Keyword.get(opts, :js, js_ex())})

    writer_tar = Keyword.get(opts, :writer_tarball, writer_tarball())
    top = Keyword.get(opts, :package)

    releases = %{
      "kino" => release(home, "kino", kino_version, kino_tar),
      "kino_vega_lite" => release(home, "kino_vega_lite", "0.1.13", writer_tar)
    }

    for app <- ~w(kino kino_vega_lite), do: File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
    kino_build = Path.join(proj, "_build/host/lib/kino")
    writer_build = Path.join(proj, "_build/host/lib/kino_vega_lite")

    put_app(
      kino_build,
      "kino",
      Keyword.get(opts, :kino_modules, ~w(Elixir.Kino.JS Elixir.Kino.HTML))
    )

    writer_modules =
      Keyword.get(opts, :writer_modules, ~w(Elixir.Kino.VegaLite Elixir.KinoVegaLite.ChartCell))

    put_app(writer_build, "kino_vega_lite", writer_modules)
    beams = Keyword.get(opts, :writer_beams, %{})

    for m <- writer_modules,
        bytes = Map.get_lazy(beams, m, fn -> real_beam(m) end),
        bytes != nil,
        do: File.write!(Path.join([writer_build, "ebin", m <> ".beam"]), bytes)

    if top, do: put_top(proj, top)

    if Keyword.get(opts, :link_kino_priv, false) do
      File.mkdir_p!(Path.join(proj, "deps/kino/priv"))
      File.ln_s!(Path.join(proj, "deps/kino/priv"), Path.join(kino_build, "priv"))
    else
      File.mkdir_p!(Path.join(kino_build, "priv/assets"))
    end

    manager = Keyword.get(opts, :kino_manager, "mix")

    package = top || "kino_vega_lite"
    top_dep = if top, do: [dep(proj, top, ["kino_vega_lite"], "mix")], else: []
    top_window = if top, do: [window(top, 201, 300)], else: []

    top_sentinel =
      if top, do: [%{app: top, ts: 202, integrity_ok: true, pid: "<0.95.0>"}], else: []

    report = %Report{
      start: Map.merge(%{"otp_root" => Path.join(root, "otp")}, @libs),
      closure: %{
        "packages" => [package],
        "deps" =>
          [dep(proj, "kino", [], manager), dep(proj, "kino_vega_lite", ["kino"], "mix")] ++
            top_dep
      },
      windows: [window("kino", 0, 100), window("kino_vega_lite", 101, 200)] ++ top_window,
      sentinels:
        [
          %{app: "kino", ts: 1, integrity_ok: true, pid: "<0.95.0>"},
          %{app: "kino_vega_lite", ts: 102, integrity_ok: true, pid: "<0.95.0>"}
        ] ++ top_sentinel,
      stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
      ending:
        Map.merge(
          %{
            "status" => "ok",
            "depth_ok" => true,
            "final_sentinel" => true,
            "overflow" => false,
            "integrity_ok" => true,
            "delivered" => true
          },
          @libs
        ),
      events: Keyword.get(opts, :events, [])
    }

    ctx =
      Context.build(proj, package, report, Keyword.get(opts, :native, []),
        hex_home: home,
        releases: releases
      )

    real_kino = Context.realpath(kino_build)

    %{
      proj: proj,
      home: home,
      releases: releases,
      report: report,
      ctx: ctx,
      kino_build: real_kino,
      assets: Path.join(real_kino, "priv/assets"),
      writer_build: Context.realpath(writer_build)
    }
  end

  defp real_beam(m) when m in ["Elixir.Kino.VegaLite", "Elixir.KinoVegaLite.ChartCell"],
    do: beam(m)

  defp real_beam(_m), do: nil

  # The package judged in kino_vega_lite's place: one Erlang module, so it
  # packs no assets of its own.
  defp put_top(proj, app) do
    build = Path.join(proj, "_build/host/lib/" <> app)
    File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
    put_app(build, app, [app])
    mod = String.to_atom(app)
    {:ok, ^mod, bytes} = :compile.forms([{:attribute, 1, :module, mod}], [:binary])
    File.write!(Path.join([build, "ebin", app <> ".beam"]), bytes)
  end

  defp put_app(build, app, modules) do
    File.mkdir_p!(Path.join(build, "ebin"))
    mods = Enum.map(modules, &String.to_atom/1)
    term = {:application, String.to_atom(app), [vsn: ~c"1.0.0", modules: mods]}
    File.write!(Path.join([build, "ebin", app <> ".app"]), :io_lib.format(~c"~p.~n", [term]))
  end

  defp dep(proj, app, children, manager) do
    %{
      "app" => app,
      "dest" => Path.join([proj, "deps", app]),
      "build" => Path.join([proj, "_build/host/lib", app]),
      "manager" => manager,
      "children" => children
    }
  end

  defp window(app, open, close),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: @libs
    }
end
