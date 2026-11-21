defmodule NccWorker.FirmwarePluginsTest do
  use ExUnit.Case, async: true

  alias NccWorker.FirmwarePlugins

  @moduletag :tmp_dir

  @target "rpi4"

  # A Nerves project whose rpi4 target built its deps in `deps_rpi4`, and
  # rebar3's cache dir of that build.
  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")
    cache = Path.join(dir, "rebar3-cache")
    File.mkdir_p!(Path.join(proj, "deps_#{@target}"))
    File.mkdir_p!(Path.join([cache, "hex", "hexpm", "packages"]))

    env = [
      {"MIX_TARGET", @target},
      {"MIX_DEPS_PATH", Path.join(proj, "deps_#{@target}")},
      {"REBAR_CACHE_DIR", cache}
    ]

    %{proj: proj, cache: cache, env: env}
  end

  # rebar3's install of plugin `name` `version` for the rebar3 app `owner`:
  # its dir under the default profile, its tarball in the cache.
  defp install!(proj, cache, owner, name, version, opts \\ []) do
    dir =
      Path.join([proj, "deps_#{@target}", owner, "_build", "default", "plugins", name])

    File.mkdir_p!(Path.join(dir, "ebin"))

    File.write!(
      Path.join(dir, "hex_metadata.config"),
      ~s|{<<"name">>,<<"#{name}">>}.\n{<<"version">>,<<"#{version}">>}.\n|
    )

    if Keyword.get(opts, :tarball, true) do
      File.write!(
        Path.join([cache, "hex", "hexpm", "packages", "#{name}-#{version}.tar"]),
        "tarball of #{name} #{version}"
      )
    end

    dir
  end

  defp sha(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp pass, do: %{status: :pass, beam_scan: %{}}

  defp put(systems, proj, env),
    do: FirmwarePlugins.put(systems, %{project_dir: proj, targets: %{"rpi4" => {@target, env}}})

  test "records each plugin release a target's rebar3 apps installed, with the apps that ran it",
       %{proj: proj, cache: cache, env: env} do
    install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8")
    install!(proj, cache, "spectra", "rebar3_hex", "7.0.8")
    install!(proj, cache, "spectra", "rebar3_proper", "0.12.1")

    %{"rpi4" => %{rebar3_plugins: record}} = put(%{"rpi4" => pass()}, proj, env)

    assert record == [
             %{
               "name" => "rebar3_hex",
               "version" => "7.0.8",
               "sha256" => sha("tarball of rebar3_hex 7.0.8"),
               "owners" => ["spectra", "yamerl"]
             },
             %{
               "name" => "rebar3_proper",
               "version" => "0.12.1",
               "sha256" => sha("tarball of rebar3_proper 0.12.1"),
               "owners" => ["spectra"]
             }
           ]
  end

  test "a profile's link to the default profile's plugin is the same release",
       %{proj: proj, cache: cache, env: env} do
    install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8")
    prod = Path.join([proj, "deps_#{@target}", "yamerl", "_build", "prod", "plugins"])
    File.mkdir_p!(prod)
    File.ln_s!("../../default/plugins/rebar3_hex", Path.join(prod, "rebar3_hex"))

    %{"rpi4" => %{rebar3_plugins: [release]}} = put(%{"rpi4" => pass()}, proj, env)
    assert %{"name" => "rebar3_hex", "owners" => ["yamerl"]} = release
  end

  test "an empty list when the target's apps installed no plugin", %{proj: proj, env: env} do
    File.mkdir_p!(Path.join([proj, "deps_#{@target}", "jason", "lib"]))
    assert %{"rpi4" => %{rebar3_plugins: []}} = put(%{"rpi4" => pass()}, proj, env)
  end

  test "a release whose tarball is not in the cache has no sha256",
       %{proj: proj, cache: cache, env: env} do
    install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8", tarball: false)

    assert %{"rpi4" => %{rebar3_plugins: [%{"name" => "rebar3_hex", "sha256" => nil}]}} =
             put(%{"rpi4" => pass()}, proj, env)
  end

  test "rebar3's cache dir is $HOME/.cache/rebar3 when the build env names none",
       %{proj: proj, tmp_dir: dir} do
    home = Path.join(dir, "home")
    cache = Path.join([home, ".cache", "rebar3"])
    File.mkdir_p!(Path.join([cache, "hex", "hexpm", "packages"]))
    install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8")

    env = [
      {"MIX_TARGET", @target},
      {"MIX_DEPS_PATH", Path.join(proj, "deps_#{@target}")},
      {"HOME", home}
    ]

    assert %{"rpi4" => %{rebar3_plugins: [%{"sha256" => sha}]}} =
             put(%{"rpi4" => pass()}, proj, env)

    assert sha == sha("tarball of rebar3_hex 7.0.8")
  end

  test "a plugin dir that names another release, or none, is recorded as unreadable",
       %{proj: proj, cache: cache, env: env} do
    dir = install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8")
    File.write!(Path.join(dir, "hex_metadata.config"), ~s|{<<"name">>,<<"other">>}.\n|)

    assert %{"rpi4" => %{rebar3_plugins: [%{"name" => "rebar3_hex", "version" => nil}]}} =
             put(%{"rpi4" => pass()}, proj, env)
  end

  test "a link out of the app's build dir is recorded as unreadable",
       %{proj: proj, cache: cache, env: env, tmp_dir: dir} do
    elsewhere = Path.join(dir, "elsewhere")
    File.mkdir_p!(elsewhere)
    plugins = Path.join([proj, "deps_#{@target}", "yamerl", "_build", "default", "plugins"])
    File.mkdir_p!(plugins)
    File.ln_s!(elsewhere, Path.join(plugins, "rebar3_odd"))
    _ = cache

    assert %{"rpi4" => %{rebar3_plugins: [%{"name" => "rebar3_odd", "version" => nil}]}} =
             put(%{"rpi4" => pass()}, proj, env)
  end

  test "only passing targets with a build env are recorded", %{proj: proj, cache: cache, env: env} do
    install!(proj, cache, "yamerl", "rebar3_hex", "7.0.8")

    systems =
      FirmwarePlugins.put(
        %{"rpi4" => %{status: :fail}, "bbb" => pass(), "x86_64" => pass()},
        %{project_dir: proj, targets: %{"rpi4" => {@target, env}, "x86_64" => {"x86_64", env}}}
      )

    refute Map.has_key?(systems["rpi4"], :rebar3_plugins)
    refute Map.has_key?(systems["bbb"], :rebar3_plugins)
    assert [%{"name" => "rebar3_hex"}] = systems["x86_64"].rebar3_plugins
  end

  test "a target whose env names no deps dir is not recorded", %{proj: proj} do
    systems = put(%{"rpi4" => pass()}, proj, [{"MIX_TARGET", @target}])
    refute Map.has_key?(systems["rpi4"], :rebar3_plugins)
  end
end
