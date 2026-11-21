defmodule NccWorker.Portability.RebarPluginsTest do
  # The plugins a rebar3 app's build installed, held to the reviewed Hex
  # releases by version and outer checksum, as rebar3 lays them out: the
  # release extracted into `_build/default/plugins/<name>` with its
  # `hex_metadata.config` and an `ebin`, linked from `_build/prod/plugins`,
  # and its tarball in rebar3's cache.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.RebarPlugins

  @moduletag :tmp_dir

  @src %{
    "src/fx_plugin.erl" => "-module(fx_plugin).\n-export([init/1]).\ninit(S) -> {ok, S}.\n",
    "src/fx_plugin.app.src" =>
      "{application, fx_plugin, [{vsn, \"1.0.0\"}, {env, [{providers, [fx_plugin]}]}]}.\n",
    "rebar.config" => "{erl_opts, [debug_info]}.\n"
  }

  # A real beam of `module`, as rebar3's compile writes it.
  defp beam(module) do
    {:ok, ^module, bytes} =
      :compile.forms([{:attribute, 1, :module, module}, {:attribute, 1, :export, []}], [:binary])

    bytes
  end

  @app ~s|{application,fx_plugin,[{vsn,"1.0.0"},{env,[{providers,[fx_plugin]}]},{modules,[fx_plugin]}]}.\n|

  defp metadata(name, version),
    do: ~s({<<"name">>,<<"#{name}">>}.\n{<<"version">>,<<"#{version}">>}.\n)

  # A Hex tarball's bytes: the outer tar around metadata.config and
  # contents.tar.gz.
  defp tarball(root, name, version, files) do
    work = Path.join(root, "tar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(work)
    contents = Path.join(work, "contents.tar.gz")

    entries = for {path, bytes} <- files, do: {String.to_charlist(path), bytes}
    :ok = :erl_tar.create(String.to_charlist(contents), entries, [:compressed])
    outer = Path.join(work, "outer.tar")

    :ok =
      :erl_tar.create(String.to_charlist(outer), [
        {~c"VERSION", "3"},
        {~c"CHECKSUM", String.duplicate("0", 64)},
        {~c"metadata.config", metadata(name, version)},
        {~c"contents.tar.gz", File.read!(contents)}
      ])

    File.read!(outer)
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  # rebar3's install of `name` `version` into the app at `dest`, with its
  # tarball in `cache`; returns the tarball's checksum.
  defp install(root, name, version, files \\ @src, ebin \\ ["fx_plugin.beam"]) do
    dest = Path.join(root, "dep")
    cache = Path.join(root, "cache")
    bytes = tarball(root, name, version, files)
    dir = Path.join([dest, "_build", "default", "plugins", name])

    for {path, data} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), data)
    end

    File.write!(Path.join(dir, "hex_metadata.config"), metadata(name, version))
    File.mkdir_p!(Path.join(dir, "ebin"))

    for file <- ebin,
        do: File.write!(Path.join([dir, "ebin", file]), beam(String.to_atom(Path.rootname(file))))

    File.write!(Path.join([dir, "ebin", name <> ".app"]), String.replace(@app, "fx_plugin", name))

    prod = Path.join([dest, "_build", "prod", "plugins"])
    File.mkdir_p!(Path.join(prod, ".rebar3"))
    File.ln_s!(dir, Path.join(prod, name))

    packages = Path.join([cache, "hex", "hexpm", "packages"])
    File.mkdir_p!(packages)
    File.write!(Path.join(packages, "#{name}-#{version}.tar"), bytes)
    %{dest: dest, cache: cache, dir: dir, sha: sha(bytes)}
  end

  defp pins(name, version, sha), do: %{name => %{version => sha}}

  test "a reviewed release, installed as rebar3 installs it, passes", %{tmp_dir: root} do
    i = install(root, "fx_plugin", "1.0.0")

    assert RebarPlugins.check(i.dest, i.cache, ["fx_plugin"], pins("fx_plugin", "1.0.0", i.sha)) ==
             :ok
  end

  # What a build records of the plugins it ran (review S5 S1): every
  # installed release, its version and its cached tarball's checksum, pinned
  # or not.
  test "the installed releases, as a build records them", %{tmp_dir: root} do
    i = install(root, "fx_plugin", "1.0.0")

    assert RebarPlugins.releases(i.dest, i.cache) == [
             %{"name" => "fx_plugin", "version" => "1.0.0", "sha256" => i.sha}
           ]

    assert RebarPlugins.releases(i.dest, nil) == [
             %{"name" => "fx_plugin", "version" => "1.0.0", "sha256" => nil}
           ]

    assert RebarPlugins.releases(Path.join(root, "none"), i.cache) == []
  end

  test "a release the table does not pin refuses, naming the plugin and its version",
       %{tmp_dir: root} do
    i = install(root, "fx_plugin", "1.0.1")

    assert RebarPlugins.check(i.dest, i.cache, [], pins("fx_plugin", "1.0.0", i.sha)) ==
             {:refuse, "rebar3 build runs plugin fx_plugin 1.0.1, a release not reviewed"}
  end

  # The shipped table: a release of a reviewed plugin published after the
  # review is not in it.
  test "an unreviewed release of a reviewed plugin refuses against the shipped table",
       %{tmp_dir: root} do
    i = install(root, "rebar3_ex_doc", "0.3.99")

    assert RebarPlugins.check(i.dest, i.cache, ["rebar3_ex_doc"]) ==
             {:refuse, "rebar3 build runs plugin rebar3_ex_doc 0.3.99, a release not reviewed"}

    # The reviewed version number on other bytes is not the reviewed release.
    other = install(Path.join(root, "other"), "rebar3_ex_doc", "0.3.0")

    assert RebarPlugins.check(other.dest, other.cache, ["rebar3_ex_doc"]) ==
             {:refuse,
              "rebar3 build runs plugin rebar3_ex_doc 0.3.0 from a Hex tarball that is not " <>
                "the reviewed release"}
  end

  test "the shipped table pins every reviewed plugin and what builds resolve today" do
    pins = RebarPlugins.pins()

    for {name, releases} <- pins, {version, sha} <- releases do
      assert Regex.match?(~r/\A[0-9a-f]{64}\z/, sha), "#{name} #{version}"
      assert {:ok, _} = Version.parse(version)
    end

    for name <- ~w(rebar3_hex rebar3_ex_doc rebar3_lint rebar3_proper coveralls covertool),
        do: assert(map_size(pins[name]) > 0, name)

    # What `{plugins, [rebar3_hex]}`, `[rebar3_ex_doc]` and `[{rebar3_lint,
    # "~> 5.0"}]` installed in builds on 2026-11-21, dependencies included.
    for {name, version} <- [
          {"rebar3_hex", "7.5.0"},
          {"hex_core", "0.21.1"},
          {"verl", "1.1.1"},
          {"rebar3_ex_doc", "0.3.0"},
          {"rebar3_lint", "5.0.4"},
          {"elvis_core", "5.0.4"},
          {"katana_code", "2.4.3"}
        ],
        do: assert(is_binary(pins[name][version]), "#{name} #{version}")
  end

  # rebar3's leex and yecc compilers write the module they generate next to
  # the `.xrl`/`.yrl` in the plugin's own `src` (hex_core's safe_erl_term).
  test "a module generated from the release's own leex or yecc file is the release's",
       %{tmp_dir: root} do
    files = Map.merge(@src, %{"src/lexer.xrl" => "Definitions.\n", "src/parser.yrl" => "x.\n"})

    i =
      install(root, "fx_plugin", "1.0.0", files, ["fx_plugin.beam", "lexer.beam", "parser.beam"])

    File.write!(Path.join(i.dir, "src/lexer.erl"), "-module(lexer).\n")
    File.write!(Path.join(i.dir, "src/parser.erl"), "-module(parser).\n")
    pins = pins("fx_plugin", "1.0.0", i.sha)

    assert RebarPlugins.check(i.dest, i.cache, [], pins) == :ok

    # Only next to its source, and never over a module the release ships.
    File.write!(Path.join(i.dir, "lexer.erl"), "-module(lexer).\n")
    assert {:refuse, _} = RebarPlugins.check(i.dest, i.cache, [], pins)
    File.rm!(Path.join(i.dir, "lexer.erl"))

    shipped = Map.merge(files, %{"src/lexer.erl" => "-module(lexer).\n%% shipped\n"})
    j = install(Path.join(root, "shipped"), "fx_plugin", "1.0.0", shipped)
    File.write!(Path.join(j.dir, "src/lexer.erl"), "-module(lexer).\n")

    assert {:refuse, _} =
             RebarPlugins.check(j.dest, j.cache, [], pins("fx_plugin", "1.0.0", j.sha))
  end

  # rebar3 runs `init/1` of the modules the `.app`'s `providers` names, and
  # loads the beams by file name (review S5 N3).
  test "an ebin whose app file or beams are not the release's sources' refuses",
       %{tmp_dir: root} do
    differs = "from files that are not its reviewed release's"

    for {case_name, change} <- [
          {"no_app", fn dir -> File.rm!(Path.join(dir, "ebin/fx_plugin.app")) end},
          {"providers",
           fn dir ->
             File.write!(
               Path.join(dir, "ebin/fx_plugin.app"),
               String.replace(@app, "{providers,[fx_plugin]}", "{providers,[evil]}")
             )
           end},
          {"app_unreadable",
           fn dir -> File.write!(Path.join(dir, "ebin/fx_plugin.app"), "{") end},
          {"other_app",
           fn dir ->
             File.write!(
               Path.join(dir, "ebin/fx_plugin.app"),
               String.replace(@app, "{application,fx_plugin", "{application,other")
             )
           end},
          {"beam_module",
           fn dir -> File.write!(Path.join(dir, "ebin/fx_plugin.beam"), beam(:evil)) end},
          {"beam_bytes",
           fn dir -> File.write!(Path.join(dir, "ebin/fx_plugin.beam"), "compiled") end}
        ] do
      i = install(Path.join(root, case_name), "fx_plugin", "1.0.0")
      change.(i.dir)

      assert {:refuse, "rebar3 build runs plugin fx_plugin 1.0.0 " <> ^differs} =
               RebarPlugins.check(i.dest, i.cache, [], pins("fx_plugin", "1.0.0", i.sha)),
             case_name
    end
  end

  test "a module a source defines under another file name is that module", %{tmp_dir: root} do
    files = Map.put(@src, "src/named.erl", "-module('fx_named').\n")
    i = install(root, "fx_plugin", "1.0.0", files, ["fx_plugin.beam", "fx_named.beam"])
    assert RebarPlugins.check(i.dest, i.cache, [], pins("fx_plugin", "1.0.0", i.sha)) == :ok
  end

  test "a file of the release changed, planted or missing refuses", %{tmp_dir: root} do
    differs = "from files that are not its reviewed release's"

    for {case_name, change} <- [
          {"changed",
           fn dir -> File.write!(Path.join(dir, "src/fx_plugin.erl"), "-module(x).") end},
          {"planted",
           fn dir -> File.write!(Path.join(dir, "src/evil.erl"), "-module(evil).") end},
          {"missing", fn dir -> File.rm!(Path.join(dir, "rebar.config")) end},
          {"metadata",
           fn dir ->
             File.write!(
               Path.join(dir, "hex_metadata.config"),
               metadata("fx_plugin", "1.0.0") <> "%\n"
             )
           end},
          {"beam", fn dir -> File.write!(Path.join(dir, "ebin/evil.beam"), "x") end},
          {"ebin_dir",
           fn dir ->
             File.mkdir_p!(Path.join(dir, "ebin/sub"))
             File.write!(Path.join(dir, "ebin/sub/fx_plugin.beam"), "x")
           end},
          {"link", fn dir -> File.ln_s!("rebar.config", Path.join(dir, "alias.config")) end}
        ] do
      i = install(Path.join(root, case_name), "fx_plugin", "1.0.0")
      change.(i.dir)

      assert {:refuse, "rebar3 build runs plugin fx_plugin 1.0.0 " <> ^differs} =
               RebarPlugins.check(i.dest, i.cache, [], pins("fx_plugin", "1.0.0", i.sha)),
             case_name
    end
  end

  test "a link from another profile must name the plugin dir of the same name",
       %{tmp_dir: root} do
    i = install(root, "fx_plugin", "1.0.0")
    pins = pins("fx_plugin", "1.0.0", i.sha)
    link = Path.join([i.dest, "_build", "prod", "plugins", "fx_plugin"])
    elsewhere = Path.join(root, "elsewhere/fx_plugin")
    File.mkdir_p!(elsewhere)
    File.rm!(link)
    File.ln_s!(elsewhere, link)

    assert {:refuse, "rebar3 build runs a plugin from a dir it cannot judge (fx_plugin)"} =
             RebarPlugins.check(i.dest, i.cache, [], pins)

    File.rm!(link)
    File.write!(link, "not a dir")
    assert {:refuse, _} = RebarPlugins.check(i.dest, i.cache, [], pins)
  end

  test "what cannot be read cannot be judged", %{tmp_dir: root} do
    i = install(root, "fx_plugin", "1.0.0")
    pins = pins("fx_plugin", "1.0.0", i.sha)

    assert {:unjudged, "rebar3 plugin fx_plugin 1.0.0: rebar3's cache dir is unknown"} =
             RebarPlugins.check(i.dest, nil, [], pins)

    assert {:unjudged, "rebar3 plugin fx_plugin 1.0.0: no cached Hex tarball"} =
             RebarPlugins.check(i.dest, Path.join(root, "empty-cache"), [], pins)

    assert {:unjudged, "rebar3 plugin rebar3_lint is named but not installed"} =
             RebarPlugins.check(i.dest, i.cache, ["fx_plugin", "rebar3_lint"], pins)

    File.write!(Path.join(i.dir, "hex_metadata.config"), "{<<\"name\">>,<<\"other\">>}.\n")

    assert {:unjudged, "rebar3 plugin fx_plugin: its release cannot be read"} =
             RebarPlugins.check(i.dest, i.cache, [], pins)
  end

  test "the reviewed plugins a config names, in its active sections" do
    config =
      ~s|{plugins, [rebar3_hex, pc, {rebar3_lint, "~> 5.0"}]}.\n| <>
        ~s|{profiles, [{prod, [{plugins, [covertool]}]}, {test, [{plugins, [coveralls]}]}]}.\n|

    assert NccWorker.Portability.Rebar.named_plugins(%{config: config, script?: false}, nil) ==
             ["rebar3_hex", "rebar3_lint", "covertool"]

    assert NccWorker.Portability.Rebar.named_plugins(%{config: nil, script?: false}, nil) == []
  end

  test "rebar3's cache dir of a compile" do
    rebar_cache = &NccWorker.Portability.rebar_cache/1

    assert rebar_cache.([{"REBAR_CACHE_DIR", "/c"}, {"HOME", "/h"}]) == "/c"
    # The compile's env applies the last value of a name (review S5 N4).
    assert rebar_cache.([{"HOME", "/first"}, {"HOME", "/last"}]) == "/last/.cache/rebar3"

    assert rebar_cache.([{"REBAR_CACHE_DIR", "/c"}, {"REBAR_CACHE_DIR", nil}, {"HOME", "/h"}]) ==
             "/h/.cache/rebar3"

    assert rebar_cache.([{"REBAR_CACHE_DIR", nil}, {"HOME", "/h"}]) == "/h/.cache/rebar3"
    assert rebar_cache.([{"REBAR_CACHE_DIR", ""}, {"HOME", nil}]) == nil
  end

  test "no plugins installed and none named passes", %{tmp_dir: root} do
    assert RebarPlugins.check(Path.join(root, "nothing"), nil, []) == :ok

    dest = Path.join(root, "built")
    File.mkdir_p!(Path.join([dest, "_build", "prod", "lib"]))
    assert RebarPlugins.check(dest, nil, []) == :ok
  end
end
