defmodule NccWorker.Portability.Rebar do
  @moduledoc """
  Spec R1 "Other OS processes" and R0 for rebar3-built packages and closure
  dependencies. rebar3 compiles in its own VM, which the trace reaches only
  through `ERL_AFLAGS`; hooks and plugins run programs no trace sees, and
  `platform_define` is host dependence by definition when rebar compiles,
  except one whose regex the OTP major alone decides (precompiled judge
  refinements, item 3, branch by branch: `major_regex?/1`), which
  decides the same on every host. Any other regex string is a compile
  input (`check_sources/3`'s `{:inputs, items}`): `%{"kind" =>
  "platform_define", "regex", "matched"}`, whether it matched the
  builder's `arch/0`, for a client to recompute (judge round 2, change 3).
  `provider_hooks` refuse too: providers come from plugins or run
  arbitrary build steps.

  A hook counts only when `rebar3 bare compile` runs it: on `compile`,
  `erlc_compile` or `app_compile`, the only commands whose hooks
  `rebar_prv_compile` runs, and `rebar_hooks` matches the command exactly.
  So `{pre_hooks, [{clean, "rm -rf ..."}]}` (hackney, yamerl, erlfmt,
  covertool) does not refuse. A `pre_hooks`/`post_hooks` entry is
  `{Command, Script}` or `{Arch, Command, Script}`, a `provider_hooks`
  value `[{pre | post, [{Command, Provider}]}]`; any other shape counts
  (fail closed), in a section and inside `overrides` alike.

  One reviewed compile hook is let through (`reviewed_hooks/0`): quic's
  `{"(linux|darwin|solaris)", compile, "sh c_src/build_nif.sh"}` and its
  BSD twin, which run a script that exits 0 unless `QUIC_BUILD_NIF=1`
  and otherwise writes only into quic's own tree (`c_src/build`,
  `priv/quic_crypto_nif.so`). Only when the caller vouches for it
  (`sources`' `reviewed:`, `allowed_hooks/3`): the script in the verified
  tarball and on disk before the compile has a reviewed sha256, and the
  build env left `QUIC_BUILD_NIF` unset. Only as an entry of the app's own
  active sections; in `overrides`, or any other script, arch, command or
  digest, it counts as before. quic itself stays native (`c_src`).

  `plugins` refuse unless every entry is a reviewed plugin from Hex
  (`@reviewed_plugins`: rebar3_hex, rebar3_ex_doc, rebar3_lint,
  rebar3_proper, coveralls, covertool), as the bare atom or `{Name,
  Requirement}` with a version or requirement string. rebar3 installs a
  dependency's `plugins` before `bare compile`, from Hex at whatever release
  its own registry cache resolves (no lock names it), and runs each one's
  `init/1` (`rebar_plugins:top_level_install/1`, without provider
  overrides) in the traced child VM, where what the plugin's code reads,
  writes or fetches is judged like any compile code. What its `init/1`
  does to rebar3's state no trace sees, so the release that ran, and every
  dependency release it pulled, must be one reviewed to only register
  providers: `NccWorker.Portability.RebarPlugins` pins them by version and
  Hex outer checksum (`named_plugins/2` names what must be installed). A
  git source, a `{pkg, Name}` source, or any other plugin still refuses.

  A hook refuses whether or not the app is natively built (crc32cer's
  `make nif`): rebar3 runs it untraced, and nothing compares a native
  app's tree after the compile. `escriptize` counts as a compile command
  (review S5 R1): `rebar_prv_escriptize` runs its own hooks, and a provider
  hook on `compile` can run it. A hook whose command is namespaced
  (`{{hex, publish}, Script}`), or any shape not understood, counts.

  A dependency's own `rebar.config.script` is not refused for existing.
  Mix evaluates it (`Mix.Rebar.load_config/1`, from
  `Mix.Dep.Loader.rebar_dep/4`) in the traced Mix VM when it loads the
  dependencies, after the tracer started and outside every window, so what
  its evaluation reads is judged like any other read there: a host read
  refuses the build, an environment read is a `compile_inputs` item. rebar3
  does not evaluate it again: `REBAR_CONFIG` points it at the
  `mix.rebar.config` Mix wrote from the script's result, which is held to
  the rules below, so a hook, plugin or `platform_define` the script adds
  refuses there. Without that file (`check/2` on its own) a script still
  refuses. A rebar3 parent's script is judged the same way: the overrides
  it hands its children (`Mix.Dep.Loader.rebar_children/4`, the parent's
  evaluated config's top-level `overrides`) are in the `mix.rebar.config`
  Mix writes for the parent from that same evaluated config
  (`Mix.Rebar.dependency_config/1` keeps `overrides`), so they are read
  from there (`parent_overrides/1`, the parent's `mix_config:`). Without
  that file, or with one that cannot be read, the parent stays
  could-not-judge.

  Only what rebar3 runs when Mix compiles the dependency counts. Mix
  (`Mix.Tasks.Deps.Compile.do_rebar3/2`, Elixir 1.19 and 1.20) runs
  `rebar3 bare compile --paths <deps>/ebin` with `REBAR_PROFILE=prod`,
  `REBAR_SKIP_PROJECT_PLUGINS=true` and `REBAR_CONFIG` set to
  `_build/<env>/lib/<d>/mix.rebar.config`, which it writes from the
  dependency's config (`rebar.config.script` evaluated, a parent's
  `overrides` applied, `project_plugins` dropped:
  `Mix.Rebar.dependency_config/1`). So the active sections are the top
  level and the `default` and `prod` profiles; `project_plugins` and every
  other profile (`test`, `docs`, ...) are ignored. A hook or plugin key
  counts only as a key of an active section; inside `overrides` it counts
  at any depth (fail closed). `platform_define` counts at any depth of an
  active section, unless the OTP major alone decides its regex
  (precompiled judge refinements, item 3); it is then recorded, or
  refuses when its regex is not a string.

  The judge (`check_sources/3`) reads the dependency's `rebar.config` and
  `rebar.config.script` from its checksum-verified Hex tarball
  (`tarball_sources/1`), never from `deps/<d>/` after the build, which an
  untraced hook can rewrite. A rebar3 parent's top-level `overrides`, which
  Mix applies to its children (`Mix.Dep.Loader.rebar_dep/4`,
  `Mix.Rebar.apply_overrides/3`), are read from the parent's tarball the
  same way and checked as if they were the dependency's own `overrides`. As
  a second check the `mix.rebar.config` rebar3 actually read is held to the
  same rules; a missing one is could-not-judge. `check/2` applies the same
  rules to the files on disk (tests, and nothing the judge trusts).

  What rebar3 evaluates itself refuses (review S5 S2): an app's
  `.app.src.script` (`rebar_app_utils`, `app_src_script`; but for a
  reviewed one, `allowed_app_src_scripts/2`: jesse 1.8.2's, gproc 1.2.0's
  and 1.3.0's) and a `.app.src`
  whose `vsn` is not a plain string (`git`, `semver`, `{git, _}`, `{cmd,
  Cmd}`, and the strings `"git"`, `"semver"`, `"hg"`, `"pkg"` and
  `"git_subdir"`, which rebar3 takes as the same directives:
  `rebar_utils:vcs_vsn/3` runs a command). rebar3 evaluates them in its own
  VM, where the code has only OTP and rebar3 frames, so the trace drops what
  it does, and the result goes into the `.app` it writes, a published file.
  They are read from the verified tarball, in each dir rebar3 looks in
  (`rebar_app_discover`: `<src dir>/*.app.src` and `*.app.src.script`, not
  below): `src`, and every dir a `src_dirs` entry names anywhere in the
  app's config, its parents' overrides and the `mix.rebar.config` rebar3
  read (top level, `erl_opts`, any profile or override; fail closed). A
  `src_dirs` value the rule cannot read makes every dir count. So a
  template under `priv` (rebar3_erllambda's) is not read. An `.app.src` the
  bounded parser cannot read (a `fun` in its `env`) refuses too, since its
  `vsn` cannot be known. `check/2` reads the same files under `dest`.

  Config files are anyone's text, so they are read with
  `NccWorker.Portability.HexFiles.parse/1` (bounded, creates no atoms)
  rather than `:file.consult/1`. A config that parser cannot read refuses.

  Coverage: a child VM's trace counts only when it fired its sentinel, has no
  problems, and recorded a successful `compile:file/2` return for every beam
  in the dependency's `ebin`, with the sha256 of the beam it wrote, which
  the beam must still have (review S5 R1): a beam written over after its
  compile returned, or a return without a hash, taints. rebar3 ends with `erlang:halt/1`, which can
  drop the collector's last queued line, the return of a compile. The tracer
  records returns only, so which one was last cannot be checked: at most
  one beam without a return per child, with the sentinel present and the
  trace otherwise clean, is a `{:gap, module}` the judge records in
  `trace_stats` rather than taint (a halt race must not taint a clean
  dependency); the reads of that compile were still traced. Two or more are an `{:error, _}`, which taints.

  `{:unjudged, _}` (could not be judged, never a gap or taint): a compile
  that returned an error, a missing `ebin`, or an empty `ebin` with no child
  trace at all, which proves nothing about what rebar3 ran.
  """

  alias NccWorker.Portability.HexFiles

  @hook_keys ~w(pre_hooks post_hooks provider_hooks plugins)
  # The plugins let through by name; the releases that may run are
  # `NccWorker.Portability.RebarPlugins.pins/0`.
  @reviewed_plugins ~w(rebar3_hex rebar3_ex_doc rebar3_lint rebar3_proper coveralls covertool)
  # The commands `rebar3 bare compile` runs hooks for (`rebar_prv_compile`).
  # And `escriptize`, the one other provider whose hooks `bare compile` can
  # reach (review S5 R1): rebar3's `rebar_prv_escriptize` runs its own
  # hooks, and a provider hook on `compile` can run it.
  @compile_commands ~w(compile erlc_compile app_compile escriptize)
  # `REBAR_PROFILE=prod` on top of rebar3's default profile.
  @active_profiles ~w(default prod)
  @max_config_bytes 1024 * 1024
  @max_contents_bytes 64 * 1024 * 1024
  @config_files [~c"rebar.config", ~c"rebar.config.script"]
  # The `vsn` strings rebar3 takes as a directive, not a version (review S5
  # F1): its resource types and "semver" (`rebar_utils:vcs_vsn_cmd/3`). "git"
  # writes the enclosing repo's `git describe` ("0.0.0" outside one), so a
  # user whose project is a git repo compiles another `.app`.
  @vsn_directives ~w(git semver hg pkg git_subdir)

  @typedoc """
  A rebar3 app's own config files: `rebar.config`'s text (or `nil`) and
  whether it has a script. As a parent, a scripted app also carries
  `mix_config:`, the path of the `mix.rebar.config` Mix wrote from the
  script's result (or `{:unjudged, why}`).
  """
  @type sources :: %{
          required(:config) => binary() | nil | :unreadable,
          required(:script?) => boolean(),
          optional(:app_src_scripts) => [String.t()],
          optional(:app_srcs) => [{String.t(), binary() | :unreadable}],
          optional(:mix_config) => String.t() | {:unjudged, String.t()},
          optional(:reviewed) => [{String.t(), String.t()}],
          optional(:reviewed_scripts) => [String.t()]
        }

  # Reviewed rebar3 compile hooks, by app: the `{Arch, compile, Script}`
  # entries let through, the script file they run, the sha256 of every
  # reviewed copy of it, and the variable that must be unset for it to do
  # nothing. quic 2.1.4, 2.6.1 and 2.7.0 carry the same script (judge round
  # 2, section 6): `[ "$QUIC_BUILD_NIF" = 1 ] || exit 0`, else a cmake
  # build into `c_src/build` and `priv/quic_crypto_nif.so`.
  @reviewed_hooks %{
    "quic" => %{
      hooks: [
        {"(linux|darwin|solaris)", "sh c_src/build_nif.sh"},
        {"(freebsd|netbsd|openbsd)", "sh c_src/build_nif.sh"}
      ],
      file: "c_src/build_nif.sh",
      sha256: ["e92786641bbfba08e0640db6eca95247b468bd923729d0e5b199e9a278b2ab0b"],
      env: "QUIC_BUILD_NIF"
    }
  }

  # Reviewed `.app.src.script`s (coverage drop 2026-11-22, F8), by the Hex
  # outer checksum of the one release each was read in: the script's path
  # and the sha256 of the reviewed copy. jesse 1.8.2's
  # `src/jesse.app.src.script` (read 2026-11-22) takes the `.app.src` term
  # rebar3 binds to CONFIG and only prepends `{applications, Apps}`, where
  # Apps is the `.app.src`'s own list for OTP 27 and later, with `jsx`
  # added for OTP 21 to 26 and `jsx` and `rfc3339` below that. Its one
  # input is `erlang:system_info(otp_release)` of the VM rebar3 runs in: no
  # file, env, command, node or other host fact. A toolchain build is per
  # OTP major and the client checks it, so the `.app` it writes is the one
  # a user's rebar3 on that OTP major writes.
  #
  # gproc 1.2.0's and 1.3.0's `src/gproc.app.src.script` (byte-identical,
  # read 2026-11-22, S2 review) binds `[{application, Name, Opts}]` to
  # CONFIG and returns CONFIG unchanged unless `Opts`' vsn is "zomp"; only
  # then does it consult a `zomp.meta` beside the app. Each release's
  # `.app.src` vsn is its own plain version (pinned with it by the outer
  # checksum) and neither tarball holds a `zomp.meta`, so that branch cannot
  # run. It reads no env, argument, release, path or clock: the `.app`
  # rebar3 writes is the one the plain `.app.src` gives, on every host.
  #
  # Any other release, script or copy counts as before.
  @gproc_app_src_script %{
    "src/gproc.app.src.script" =>
      "35edb4115b4a43cff9ca220cb0402af1181e8633389aed86ec78259e84b4816c"
  }

  @reviewed_app_src_scripts %{
    "46c9c46f673f07d9df4158d1acf62b0d0188db35e8996833075e28b4fe639bad" => %{
      release: {"jesse", "1.8.2"},
      scripts: %{
        "src/jesse.app.src.script" =>
          "eb6aaa74916f560f5f5998277f22c187c38ce657c79f4c837e384e9d5784e04d"
      }
    },
    "70c6f8c91fa5974296cd87974949d8eab953230414f31c4a623ff75131e0827a" => %{
      release: {"gproc", "1.2.0"},
      scripts: @gproc_app_src_script
    },
    "143a8ce6eb59610a351178482b629d2b052c69df84c9c50b9c13ae38354c8c14" => %{
      release: {"gproc", "1.3.0"},
      scripts: @gproc_app_src_script
    }
  }

  @doc """
  The static rebar3 rules for the source dir `dest` as it is on disk and,
  when given, the `mix.rebar.config` Mix wrote for rebar3.
  """
  @spec check(String.t(), String.t() | nil) ::
          :ok | {:inputs, [map()]} | {:refuse, String.t()} | {:unjudged, String.t()}
  # A dependency's own build files, read as data; nothing is evaluated.
  # sobelow_skip ["Traversal.FileModule"]
  def check(dest, mix_config \\ nil) when is_binary(dest) do
    config =
      case read_file(Path.join(dest, "rebar.config")) do
        {:ok, text} -> text
        :absent -> nil
        :error -> :unreadable
      end

    {scripts, srcs} = dest |> app_src_paths() |> Enum.split_with(&app_src_script?/1)

    sources = %{
      config: config,
      script?: File.exists?(Path.join(dest, "rebar.config.script")),
      app_src_scripts: Enum.map(scripts, &Path.relative_to(&1, dest)),
      app_srcs: Enum.map(srcs, &{Path.relative_to(&1, dest), app_src_text(&1)})
    }

    check_sources(sources, [], mix_config)
  end

  # The `.app.src` and `.app.src.script` files under `dest`, at any depth;
  # `app_src/2` keeps those in a src dir.
  # sobelow_skip ["Traversal.FileModule"]
  defp app_src_paths(dest) do
    Path.wildcard(Path.join(dest, "**/*.app.src")) ++
      Path.wildcard(Path.join(dest, "**/*.app.src.script"))
  end

  defp app_src_text(path) do
    case read_file(path) do
      {:ok, text} -> text
      _ -> :unreadable
    end
  end

  @doc """
  The static rebar3 rules for one app's `sources` (from its verified
  tarball), with the `sources` of its rebar3 parents, whose top-level
  `overrides` Mix applies to it, and the `mix.rebar.config` rebar3 read.
  """
  @spec check_sources(sources(), [sources()], String.t() | nil) ::
          :ok | {:inputs, [map()]} | {:refuse, String.t()} | {:unjudged, String.t()}
  def check_sources(%{script?: true}, _parents, nil),
    do: {:refuse, "rebar3 build evaluates rebar.config.script"}

  def check_sources(%{config: own} = sources, parents, mix_config) do
    reviewed = Map.get(sources, :reviewed, [])

    with {:ok, own_terms} <- parse_own(own),
         {:ok, inherited} <- parent_overrides(parents),
         :ok <- app_src(sources, src_dirs(own_terms ++ inherited ++ mix_terms(mix_config))),
         {:ok, own_inputs} <- inputs(config({:ok, own_terms ++ inherited}, reviewed)),
         {:ok, mix_inputs} <- inputs(mix_config(mix_config, reviewed)) do
      case Enum.uniq(own_inputs ++ mix_inputs) do
        [] -> :ok
        items -> {:inputs, items}
      end
    end
  end

  @doc """
  The dirs, relative to the app's own dir, that rebar3 builds the app under
  (`<dir>/<profile>/plugins` holds the plugins it installs): `_build`, and
  the `base_dir` the compile's `REBAR_BASE_DIR` (`env_base`, rebar3 lets it
  win) or else the `mix.rebar.config` rebar3 read (`mix_config`, a path; it
  holds the dependency's rebar.config as Mix loaded it, its parents'
  overrides applied) sets in an active section (coverage drop 2026-11-22,
  F9: jhn_stdlib's `{base_dir, ".build"}`). `_build` is always one of them,
  so a plugin planted there is still judged. A `base_dir` that is not one
  relative path inside the app's dir (absolute, empty, with a `..` that
  leaves it, not a string), two that differ, or a config that cannot be
  read cannot be judged. No config, or none that sets it, is `_build`.
  """
  @spec base_dirs(String.t() | term(), String.t() | nil) ::
          {:ok, [String.t()]} | {:unjudged, String.t()}
  def base_dirs(mix_config, env_base) do
    with {:ok, configured} <- configured_base(mix_config),
         {:ok, base} <- chosen_base(env_base, configured) do
      {:ok, Enum.uniq(["_build", base])}
    end
  end

  defp chosen_base(env_base, _configured) when is_binary(env_base) and env_base != "",
    do: relative_base(env_base)

  defp chosen_base(_env_base, nil), do: {:ok, "_build"}
  defp chosen_base(_env_base, configured), do: {:ok, configured}

  defp configured_base(path) when is_binary(path) do
    with {:ok, text} <- read_file(path),
         {:ok, terms} <- HexFiles.parse(text) do
      values =
        for section <- active_sections(terms),
            {{:atom, "base_dir"}, value} <- List.wrap(section),
            uniq: true,
            do: value

      case values do
        [] -> {:ok, nil}
        [value] -> relative_base(value)
        _ -> unjudged_base(values)
      end
    else
      :absent -> {:ok, nil}
      _ -> {:unjudged, "rebar3 base_dir cannot be judged: mix.rebar.config cannot be read"}
    end
  end

  defp configured_base(_path), do: {:ok, nil}

  defp relative_base(value) when is_list(value) do
    if Enum.all?(value, &(is_integer(&1) and &1 in 1..0x10FFFF)),
      do: relative_base(List.to_string(value)),
      else: unjudged_base(value)
  rescue
    _ -> unjudged_base(value)
  end

  defp relative_base(value) when is_binary(value) do
    parts = value |> Path.split() |> Enum.reject(&(&1 == "."))

    if Path.type(value) == :relative and parts != [] and ".." not in parts,
      do: {:ok, Path.join(parts)},
      else: unjudged_base(value)
  end

  defp relative_base(value), do: unjudged_base(value)

  defp unjudged_base(value),
    do: {:unjudged, "rebar3 base_dir cannot be judged: #{inspect(value, limit: 5)}"}

  @doc """
  The reviewed plugins (`@reviewed_plugins`) that `sources`' config and the
  `mix.rebar.config` rebar3 read (a path, or anything else for none) name in
  their active sections: what rebar3 installs for the app, which
  `NccWorker.Portability.RebarPlugins` then finds installed. A config that
  cannot be read names none (`check_sources/3` refuses it).
  """
  @spec named_plugins(sources(), String.t() | term()) :: [String.t()]
  def named_plugins(%{config: own}, mix_config) do
    from_mix =
      with path when is_binary(path) <- mix_config,
           {:ok, text} <- read_file(path),
           {:ok, terms} <- HexFiles.parse(text) do
        terms
      else
        _ -> []
      end

    own_terms =
      case parse_own(own) do
        {:ok, terms} -> terms
        _ -> []
      end

    for terms <- [own_terms, from_mix],
        section <- active_sections(terms),
        {{:atom, "plugins"}, plugins} <- List.wrap(section),
        is_list(plugins),
        plugin <- plugins,
        name = plugin_name(plugin),
        name in @reviewed_plugins,
        uniq: true,
        do: name
  end

  # Review S5 S2: what rebar3 evaluates itself (moduledoc), in the dirs it
  # looks in (`dirs`, or `:any`).
  defp app_src(sources, dirs) do
    read? = fn path -> dirs == :any or Path.dirname(path) in dirs end

    scripts = Map.get(sources, :app_src_scripts, []) -- Map.get(sources, :reviewed_scripts, [])

    if Enum.any?(scripts, read?) do
      {:refuse, "rebar3 build evaluates an .app.src.script"}
    else
      sources
      |> Map.get(:app_srcs, [])
      |> Enum.filter(fn {path, _text} -> read?.(path) end)
      |> Enum.map(fn {_path, text} -> app_src_vsn(text) end)
      |> Enum.find(:ok, &(&1 != :ok))
    end
  end

  # The dirs rebar3 finds an `.app.src` in: `src` and every dir a
  # `src_dirs` entry names anywhere in `terms`, or `:any` when one cannot be
  # read (fail closed).
  defp src_dirs(terms) do
    terms
    |> src_dirs_values()
    |> Enum.reduce_while(MapSet.new(["src"]), fn value, acc ->
      case src_dir_list(value) do
        {:ok, dirs} -> {:cont, MapSet.union(acc, MapSet.new(dirs))}
        :error -> {:halt, :any}
      end
    end)
  end

  defp src_dirs_values({{:atom, "src_dirs"}, value}), do: [value]
  defp src_dirs_values(term) when is_tuple(term), do: term |> Tuple.to_list() |> src_dirs_values()

  defp src_dirs_values(term) when is_list(term) do
    if List.ascii_printable?(term), do: [], else: Enum.flat_map(term, &src_dirs_values/1)
  end

  defp src_dirs_values(_term), do: []

  defp src_dir_list(value) when is_list(value) do
    dirs = Enum.map(value, &src_dir/1)
    if :error in dirs, do: :error, else: {:ok, dirs}
  end

  defp src_dir_list(_value), do: :error

  defp src_dir({dir, opts}) when is_list(opts), do: src_dir(dir)
  defp src_dir(dir) when is_binary(dir), do: normal_dir(dir)

  defp src_dir(dir) when is_list(dir) and dir != [] do
    if List.ascii_printable?(dir), do: normal_dir(List.to_string(dir)), else: :error
  end

  defp src_dir(_dir), do: :error

  defp normal_dir(dir) do
    parts = dir |> Path.split() |> Enum.reject(&(&1 == "."))

    cond do
      parts == [] -> "."
      Path.type(dir) != :relative or ".." in parts -> :error
      true -> Path.join(parts)
    end
  end

  # The terms of the `mix.rebar.config` rebar3 read, for its `src_dirs`;
  # none when it cannot be read (the config rules decide that case).
  defp mix_terms(path) when is_binary(path) do
    with {:ok, text} <- read_file(path),
         {:ok, terms} <- HexFiles.parse(text) do
      terms
    else
      _ -> []
    end
  end

  defp mix_terms(_path), do: []

  defp app_src_vsn(text) when is_binary(text) do
    case HexFiles.parse(text) do
      {:ok, [{{:atom, "application"}, {:atom, _app}, props}]} when is_list(props) ->
        props |> Enum.flat_map(&vsn_of/1) |> plain_vsn()

      _ ->
        {:refuse, "rebar3 build .app.src unreadable"}
    end
  end

  defp app_src_vsn(_unreadable), do: {:refuse, "rebar3 build .app.src unreadable"}

  defp vsn_of({{:atom, "vsn"}, vsn}), do: [vsn]
  defp vsn_of(_prop), do: []

  # One `vsn`, a non-empty string that names no resource type: rebar3
  # takes it as it is.
  defp plain_vsn([vsn]) when is_list(vsn) and vsn != [] do
    if List.ascii_printable?(vsn) and List.to_string(vsn) not in @vsn_directives,
      do: :ok,
      else: computed_vsn()
  end

  defp plain_vsn(_vsns), do: computed_vsn()

  defp computed_vsn, do: {:refuse, "rebar3 build computes its .app.src vsn"}

  defp app_src_script?(path), do: String.ends_with?(path, ".app.src.script")

  defp app_src?(path),
    do: String.ends_with?(path, ".app.src") or app_src_script?(path)

  defp plugin_name({:atom, name}), do: name
  defp plugin_name({{:atom, name}, _requirement}), do: name
  defp plugin_name(_plugin), do: nil

  defp inputs(:ok), do: {:ok, []}
  defp inputs({:inputs, items}), do: {:ok, items}
  defp inputs(other), do: other

  @doc """
  The reviewed hook files: `%{app => {script path, variable}}`, the script
  `allowed_hooks/3` wants the on-disk sha256 of, taken before the compile
  and only when the build env leaves the variable unset.
  """
  @spec reviewed_hooks() :: %{String.t() => {String.t(), String.t()}}
  def reviewed_hooks, do: Map.new(@reviewed_hooks, fn {app, r} -> {app, {r.file, r.env}} end)

  @doc """
  The reviewed `{Arch, Script}` compile hooks `app` may run (`sources`'
  `reviewed:`): its entry's hooks when both the copy of its script in the
  verified Hex tarball `tarball` and `disk_sha256`, the copy on disk before
  the compile, have a reviewed sha256; `[]` otherwise.
  """
  @spec allowed_hooks(String.t(), binary() | nil, String.t() | nil) :: [{String.t(), String.t()}]
  def allowed_hooks(app, tarball, disk_sha256) do
    with %{} = entry <- Map.get(@reviewed_hooks, app),
         true <- disk_sha256 in entry.sha256,
         {:ok, bytes} <- tarball_file(tarball, entry.file),
         true <- sha256(bytes) in entry.sha256 do
      entry.hooks
    else
      _ -> []
    end
  end

  @doc """
  The `.app.src.script`s of a rebar3 app that are let through
  (`@reviewed_app_src_scripts`, coverage drop 2026-11-22, F8): those of the
  release whose Hex outer checksum `tarball` (its verified bytes) has, when
  the app's tree on disk before the compile (`tree`, `NccWorker.Portability.Trees`)
  was that tarball's and holds the reviewed copy. `[]` otherwise.
  """
  @spec allowed_app_src_scripts(binary() | nil, term()) :: [String.t()]
  def allowed_app_src_scripts(tarball, {:ok, members}) when is_binary(tarball) do
    case Map.get(@reviewed_app_src_scripts, sha256(tarball)) do
      %{scripts: scripts} -> for {path, sha} <- scripts, Map.get(members, path) == sha, do: path
      nil -> []
    end
  end

  def allowed_app_src_scripts(_tarball, _tree), do: []

  defp tarball_file(bytes, path) when is_binary(bytes) do
    with {:ok, tar} <- contents_tar(bytes),
         {:ok, [{_name, body}]} <-
           :erl_tar.extract({:binary, tar}, [:memory, {:files, [String.to_charlist(path)]}]) do
      {:ok, body}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp tarball_file(_bytes, _path), do: :error

  defp sha256(bytes), do: :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)

  defp parse_own(nil), do: {:ok, []}
  defp parse_own(text) when is_binary(text), do: parse_or_refuse(text)
  defp parse_own(_unreadable), do: {:refuse, "rebar3 build config unreadable"}

  defp parse_or_refuse(text) do
    case HexFiles.parse(text) do
      {:ok, terms} -> {:ok, terms}
      :error -> {:refuse, "rebar3 build config unreadable"}
    end
  end

  # Each parent's top-level `overrides`, as `overrides` entries of the
  # child's own config. A scripted parent's are what its script evaluated
  # to, read from the `mix.rebar.config` Mix wrote from that result
  # (`mix_config:`), on top of its tarball's (fail closed); without that
  # file they are unknowable.
  defp parent_overrides(parents) do
    Enum.reduce_while(parents, {:ok, []}, fn parent, {:ok, acc} ->
      with {:ok, terms} <- parse_own(parent.config),
           {:ok, evaluated} <- evaluated_terms(parent) do
        {:cont, {:ok, acc ++ top_overrides(terms) ++ top_overrides(evaluated)}}
      else
        other -> {:halt, other}
      end
    end)
  end

  defp top_overrides(terms), do: for({{:atom, "overrides"}, _} = o <- terms, do: o)

  defp evaluated_terms(%{script?: false}), do: {:ok, []}

  defp evaluated_terms(%{script?: true, mix_config: path}) when is_binary(path) do
    with {:ok, text} <- read_file(path),
         {:ok, terms} <- HexFiles.parse(text) do
      {:ok, terms}
    else
      :absent -> {:unjudged, "a rebar3 parent's mix.rebar.config is missing"}
      _ -> {:unjudged, "a rebar3 parent's mix.rebar.config is unreadable"}
    end
  end

  defp evaluated_terms(%{script?: true, mix_config: {:unjudged, _} = unjudged}), do: unjudged

  defp evaluated_terms(%{script?: true}),
    do: {:unjudged, "a rebar3 parent evaluates rebar.config.script"}

  @doc """
  `rebar.config` and `rebar.config.script` from a Hex tarball's
  `contents.tar.gz`, inflated under a bound; `{:unjudged, _}` without a
  verified tarball or when it cannot be read.
  """
  @spec tarball_sources(binary() | nil) :: {:ok, sources()} | {:unjudged, String.t()}
  def tarball_sources(nil), do: {:unjudged, "rebar3 app has no verified Hex tarball"}

  def tarball_sources(bytes) when is_binary(bytes) do
    with {:ok, tar} <- contents_tar(bytes),
         {:ok, names} <- :erl_tar.table({:binary, tar}),
         app_srcs = Enum.filter(names, &app_src?(List.to_string(&1))),
         {:ok, files} <-
           :erl_tar.extract({:binary, tar}, [:memory, {:files, @config_files ++ app_srcs}]) do
      sources(Map.new(files, fn {name, body} -> {List.to_string(name), body} end))
    else
      _ -> {:unjudged, "rebar3 app's verified Hex tarball is unreadable"}
    end
  rescue
    _ -> {:unjudged, "rebar3 app's verified Hex tarball is unreadable"}
  end

  @doc """
  The inflated `contents.tar.gz` of a Hex tarball's bytes, under the 64 MiB
  cap; `:error` when it is missing, corrupt or over the cap. The one reader
  of a tarball's contents the judge uses (`tarball_sources/1`,
  `NccWorker.Portability.Trees`).
  """
  @spec contents_tar(binary()) :: {:ok, binary()} | :error
  def contents_tar(bytes) when is_binary(bytes) do
    with {:ok, gz} <- outer_contents(bytes), do: inflate(gz)
  end

  defp outer_contents(bytes) do
    case :erl_tar.extract({:binary, bytes}, [:memory, {:files, [~c"contents.tar.gz"]}]) do
      {:ok, [{_name, gz}]} -> {:ok, gz}
      _ -> :error
    end
  end

  defp inflate(gz) do
    case Compatibility.StaticPriv.inflate(gz, @max_contents_bytes) do
      {:ok, tar} -> {:ok, tar}
      _ -> :error
    end
  end

  defp sources(%{"rebar.config" => config} = files) when byte_size(config) > @max_config_bytes,
    do: sources(%{files | "rebar.config" => :unreadable})

  defp sources(files) do
    {scripts, srcs} =
      files |> Map.keys() |> Enum.filter(&app_src?/1) |> Enum.split_with(&app_src_script?/1)

    {:ok,
     %{
       config: Map.get(files, "rebar.config"),
       script?: Map.has_key?(files, "rebar.config.script"),
       app_src_scripts: Enum.sort(scripts),
       app_srcs: for(src <- Enum.sort(srcs), do: {src, bounded(files[src])})
     }}
  end

  defp bounded(text) when byte_size(text) <= @max_config_bytes, do: text
  defp bounded(_text), do: :unreadable

  defp mix_config(nil, _reviewed), do: :ok

  defp mix_config({:unjudged, _} = unjudged, _reviewed), do: unjudged

  # sobelow_skip ["Traversal.FileModule"]
  defp mix_config(path, reviewed) when is_binary(path) do
    case read_file(path) do
      {:ok, text} -> config(HexFiles.parse(text), reviewed)
      :absent -> {:unjudged, "rebar3 mix.rebar.config missing"}
      :error -> {:refuse, "rebar3 build config unreadable"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_file(path) do
    case File.stat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_config_bytes ->
        case File.read(path) do
          {:ok, text} -> {:ok, text}
          _ -> :error
        end

      {:error, :enoent} ->
        :absent

      _ ->
        :error
    end
  end

  defp config({:ok, terms}, reviewed) do
    sections = active_sections(terms)

    # `overrides` of every active section, top level and profiles alike.
    overrides =
      for section <- sections,
          {{:atom, "overrides"}, value} <- List.wrap(section),
          do: value

    case Enum.find(@hook_keys, &(runs?(sections, &1, reviewed) or nested?(overrides, &1))) do
      # The sections hold their `overrides` already.
      nil -> platform_define(sections)
      key -> {:refuse, "rebar3 build runs #{key}"}
    end
  end

  defp config(:error, _reviewed), do: {:refuse, "rebar3 build config unreadable"}

  # The top level and the bodies of the profiles active under Mix's rebar3
  # call, each a list of `{key, value}` terms.
  defp active_sections(terms) do
    profiles =
      for {{:atom, "profiles"}, list} when is_list(list) <- terms,
          {{:atom, name}, body} when name in @active_profiles and is_list(body) <- list,
          do: body

    [terms | profiles]
  end

  # A reviewed hook (`reviewed`) is let through here only: as an entry of
  # an active section, never inside `overrides`.
  defp runs?(sections, key, reviewed) do
    Enum.any?(sections, fn section ->
      Enum.any?(List.wrap(section), fn
        {{:atom, ^key}, value} -> counts?(key, value, reviewed)
        _ -> false
      end)
    end)
  end

  defp nested?(terms, key) do
    any_term?(terms, fn
      {{:atom, ^key}, value} -> counts?(key, value, [])
      _ -> false
    end)
  end

  # Whether a hook or plugin key's value runs anything under Mix's
  # `rebar3 bare compile`: plugins whenever there are any, hooks only on a
  # compile command, any shape not understood always.
  defp counts?(_key, [], _reviewed), do: false

  defp counts?(hooks, value, reviewed) when hooks in ["pre_hooks", "post_hooks"],
    do: not proper_list?(value) or Enum.any?(value, &compile_hook?(&1, reviewed))

  defp counts?("plugins", value, _reviewed),
    do: not proper_list?(value) or not Enum.all?(value, &hex_plugin?/1)

  defp counts?("provider_hooks", value, _reviewed),
    do: not proper_list?(value) or Enum.any?(value, &compile_provider_hooks?/1)

  defp counts?(_key, _value, _reviewed), do: true

  defp compile_hook?({{:atom, command}, _script}, _reviewed), do: command in @compile_commands

  defp compile_hook?({arch, {:atom, command}, script}, reviewed),
    do: command in @compile_commands and not reviewed_hook?(arch, command, script, reviewed)

  defp compile_hook?(_entry, _reviewed), do: true

  defp reviewed_hook?(arch, "compile", script, reviewed) do
    with {:ok, arch} <- regex_text(arch),
         {:ok, script} <- regex_text(script) do
      {arch, script} in reviewed
    else
      _ -> false
    end
  end

  defp reviewed_hook?(_arch, _command, _script, _reviewed), do: false

  defp compile_provider_hooks?({{:atom, type}, hooks}) when type in ["pre", "post"] do
    not proper_list?(hooks) or
      Enum.any?(hooks, fn
        {{:atom, command}, _provider} ->
          command in @compile_commands

        _entry ->
          true
      end)
  end

  defp compile_provider_hooks?(_entry), do: true

  # A reviewed plugin (`@reviewed_plugins`) from Hex: the bare name, or the
  # name with a version or requirement string.
  defp hex_plugin?({:atom, name}), do: name in @reviewed_plugins

  defp hex_plugin?({{:atom, name}, requirement}) when name in @reviewed_plugins do
    with {:ok, text} <- regex_text(requirement),
         {:ok, _parsed} <- Version.parse_requirement(text) do
      true
    else
      _ -> false
    end
  end

  defp hex_plugin?(_plugin), do: false

  defp proper_list?([]), do: true
  defp proper_list?([_ | tail]), do: proper_list?(tail)
  defp proper_list?(_term), do: false

  # Ignoring `project_plugins` and inactive profiles at the top level. Item 3
  # (precompiled judge refinements): a `platform_define` whose regex the
  # OTP major alone decides (`major_regex?/1`) is accepted. Judge round
  # 2, change 3: any other regex string is recorded as a `platform_define`
  # compile input, with whether it matched the builder's arch string
  # (`arch/0`), which a client recomputes and compares; one `:re` cannot
  # compile, or that is not ASCII, records `config_unrecorded`. A define
  # whose regex is not a string, or that is not a define tuple, refuses.
  defp platform_define(sections) do
    searched =
      Enum.map(sections, fn
        section when is_list(section) -> Enum.reject(section, &inactive?/1)
        other -> other
      end)

    defines =
      collect(
        searched,
        &(is_tuple(&1) and tuple_size(&1) > 0 and elem(&1, 0) == {:atom, "platform_define"})
      )

    defines
    |> Enum.reduce_while([], fn define, acc ->
      case define_input(define) do
        :decided -> {:cont, acc}
        {:input, item} -> {:cont, [item | acc]}
        :refuse -> {:halt, :refuse}
      end
    end)
    |> case do
      :refuse -> {:refuse, "rebar3 build uses platform_define"}
      [] -> :ok
      items -> {:inputs, items |> Enum.reverse() |> Enum.uniq()}
    end
  end

  defp define_input(define) do
    case define_regex(define) do
      {:ok, text} -> if major_regex?(text), do: :decided, else: {:input, arch_input(text)}
      :error -> :refuse
    end
  end

  defp define_regex({{:atom, "platform_define"}, regex, _key}), do: regex_text(regex)
  defp define_regex({{:atom, "platform_define"}, regex, _key, _value}), do: regex_text(regex)
  defp define_regex(_define), do: :error

  @unrecorded %{"kind" => "config_unrecorded"}

  # rebar3's own test (`rebar_utils:is_arch/1`): `re:run(get_arch(), Regex,
  # [{capture, none}])`. Only ASCII, so the string rebar3 passes (a
  # charlist from `rebar.config`) and this binary are the same pattern.
  defp arch_input(text) do
    with true <- ascii?(text),
         true <- Compatibility.CompileInputs.regex?(text),
         {:ok, compiled} <- :re.compile(text) do
      matched = :re.run(arch(), compiled, [{:capture, :none}]) == :match
      %{"kind" => "platform_define", "regex" => text, "matched" => matched}
    else
      _ -> @unrecorded
    end
  rescue
    _ -> @unrecorded
  end

  defp ascii?(text), do: for(<<c <- text>>, reduce: true, do: (acc -> acc and c < 128))

  @doc """
  The builder's arch string as rebar3 computes it (`rebar_utils:get_arch/0`):
  `<OTP version>-<system_architecture>-<wordsize in bits>`, the OTP version
  read from `<root>/releases/<major>/OTP_VERSION` as `otp_version_of/2`
  reads it.
  """
  @spec arch() :: String.t()
  def arch do
    words = Integer.to_string(8 * :erlang.system_info({:wordsize, :external}))
    system = List.to_string(:erlang.system_info(:system_architecture))
    otp_version() <> "-" <> system <> "-" <> words
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp otp_version do
    release = List.to_string(:erlang.system_info(:otp_release))
    file = Path.join([List.to_string(:code.root_dir()), "releases", release, "OTP_VERSION"])
    otp_version_of(File.read(file), release)
  end

  @doc """
  The OTP version from `OTP_VERSION`'s `read` result, as
  `rebar_utils:otp_release1/1` (rebar3 3.22 to 3.28) takes it: everything
  before the first `**` when there is one, else the contents with every
  trailing newline trimmed; `release`, the major, when the file cannot be
  read.
  """
  @spec otp_version_of({:ok, binary()} | {:error, term()}, String.t()) :: String.t()
  def otp_version_of({:ok, vsn}, _release) when is_binary(vsn) do
    case :binary.match(vsn, "**") do
      {pos, _} -> binary_part(vsn, 0, pos)
      :nomatch -> String.trim_trailing(vsn, "\n")
    end
  end

  def otp_version_of(_read, release), do: release

  defp inactive?({{:atom, key}, _value}), do: key in ["profiles", "project_plugins"]
  defp inactive?(_term), do: false

  # Every term in `term`, itself included, for which `fun` holds.
  defp collect(term, fun) do
    own = if fun.(term), do: [term], else: []
    own ++ Enum.flat_map(inner(term), &collect(&1, fun))
  end

  # `rebar_utils:get_arch/0` is `<full OTP version>-<arch>-<wordsize>`, and
  # the client checks only the OTP major. Atoms of digits, `R`, classes of
  # digits and `( | )` groups of the same, each optionally quantified
  # (`?`, `*`, `+`, `{n}`, `{n,}`, `{n,m}`), can only consume characters
  # before the first `.` or `-`. The regex is split on its top-level `|`
  # (`top_branches/1`) and each branch judged on its own (`branch/2`): it
  # always matches, never matches, or may depend on the host. A regex any
  # of whose branches always matches, or all of whose branches never
  # match, decides the same on every host and patch of the build's major.
  defp major_regex?(text) do
    with {:ok, _compiled} <- Regex.compile(text),
         {:ok, branches} <- top_branches(text) do
      major = :erlang.system_info(:otp_release) |> List.to_string()
      kinds = Enum.map(branches, &branch(&1, major))
      :always in kinds or Enum.all?(kinds, &(&1 == :never))
    else
      _ -> false
    end
  end

  # One top-level branch, anchored with `^`. Wholly in the grammar, it is
  # evaluated against the major followed by `.` and by `-` (what can follow
  # it): both match is `:always`, neither `:never`. Only a leading part in
  # the grammar (`^20` of `^20\.3`) decides only when that part matches
  # neither: the branch then never matches either, as anything it matches
  # starts with a match of that part. Anything else is `:unknown`.
  defp branch("^" <> body = text, major) do
    case major_seq(body) do
      {:ok, ""} ->
        probe(text, major, &both/2)

      {:ok, <<next, _::binary>> = rest} when next not in [??, ?*, ?+, ?{] and rest != body ->
        prefix = binary_part(text, 0, byte_size(text) - byte_size(rest))
        probe(prefix, major, &prefix_only/2)

      _ ->
        :unknown
    end
  end

  defp branch(_text, _major), do: :unknown

  defp probe(text, major, verdict) do
    case Regex.compile(text) do
      {:ok, compiled} ->
        verdict.(Regex.match?(compiled, major <> "."), Regex.match?(compiled, major <> "-"))

      _ ->
        :unknown
    end
  end

  defp both(true, true), do: :always
  defp both(false, false), do: :never
  defp both(_dot, _dash), do: :unknown

  defp prefix_only(false, false), do: :never
  defp prefix_only(_dot, _dash), do: :unknown

  # The regex's top-level branches, split on `|` outside groups, classes
  # and escapes. Anything that could hide a `|` from this scan or change
  # how the pattern reads, `(?...)`, `(*...)`, `\Q`, `\E`, `\c`, a POSIX
  # class inside `[...]`, or unbalanced parentheses, is `:error`.
  defp top_branches(text), do: split(text, 0, "", [])

  defp split("", 0, current, acc), do: {:ok, Enum.reverse([current | acc])}
  defp split("", _depth, _current, _acc), do: :error

  defp split(<<?\\, c, rest::binary>>, depth, current, acc) when c not in ~c"QEc",
    do: split(rest, depth, current <> <<?\\, c>>, acc)

  defp split(<<?\\, _::binary>>, _depth, _current, _acc), do: :error
  defp split("(?" <> _, _depth, _current, _acc), do: :error
  defp split("(*" <> _, _depth, _current, _acc), do: :error
  defp split("(" <> rest, depth, current, acc), do: split(rest, depth + 1, current <> "(", acc)
  defp split(")" <> _, 0, _current, _acc), do: :error
  defp split(")" <> rest, depth, current, acc), do: split(rest, depth - 1, current <> ")", acc)
  defp split("|" <> rest, 0, current, acc), do: split(rest, 0, "", [current | acc])

  defp split("[" <> rest, depth, current, acc) do
    with {:ok, class, rest} <- class_body(rest) do
      split(rest, depth, current <> "[" <> class, acc)
    end
  end

  defp split(<<c, rest::binary>>, depth, current, acc),
    do: split(rest, depth, current <> <<c>>, acc)

  # The rest of a `[...]` class, its closing `]` included: a leading `^`
  # and a leading `]` are literal, as in PCRE.
  defp class_body("^]" <> rest), do: class_more(rest, "^]")
  defp class_body("^" <> rest), do: class_more(rest, "^")
  defp class_body("]" <> rest), do: class_more(rest, "]")
  defp class_body(rest), do: class_more(rest, "")

  defp class_more("]" <> rest, acc), do: {:ok, acc <> "]", rest}
  defp class_more("[:" <> _, _acc), do: :error

  defp class_more(<<?\\, c, rest::binary>>, acc) when c not in ~c"QEc",
    do: class_more(rest, acc <> <<?\\, c>>)

  defp class_more(<<?\\, _::binary>>, _acc), do: :error
  defp class_more(<<c, rest::binary>>, acc), do: class_more(rest, acc <> <<c>>)
  defp class_more("", _acc), do: :error

  defp regex_text(text) when is_binary(text),
    do: if(String.valid?(text), do: {:ok, text}, else: :error)

  defp regex_text([_ | _] = chars) do
    if Enum.all?(chars, &is_integer/1), do: {:ok, List.to_string(chars)}, else: :error
  rescue
    _ -> :error
  end

  defp regex_text(_regex), do: :error

  # The grammar: atoms, each optionally quantified, until something else,
  # returning what is left.
  defp major_seq(<<c, rest::binary>>) when c in ?0..?9 or c == ?R, do: quantified(rest)

  defp major_seq("[" <> rest) do
    with {:ok, rest} <- major_class(rest), do: quantified(rest)
  end

  defp major_seq("(" <> rest) do
    with {:ok, rest} <- major_group(rest), do: quantified(rest)
  end

  defp major_seq(rest), do: {:ok, rest}

  # One optional greedy quantifier after an atom. A lazy or possessive
  # suffix, or a `{` that is not a quantifier, is left for the caller,
  # which never reads it as part of the grammar.
  defp quantified(<<c, rest::binary>>) when c in [??, ?*, ?+], do: major_seq(rest)

  defp quantified("{" <> rest = text) do
    case Regex.run(~r/\A[0-9]+(,[0-9]*)?\}/, rest) do
      [counted | _] ->
        major_seq(binary_part(rest, byte_size(counted), byte_size(rest) - byte_size(counted)))

      nil ->
        {:ok, text}
    end
  end

  defp quantified(rest), do: major_seq(rest)

  defp major_group(text) do
    case major_seq(text) do
      {:ok, "|" <> rest} -> major_group(rest)
      {:ok, ")" <> rest} -> {:ok, rest}
      _ -> :error
    end
  end

  # Digits and digit ranges, at least one, up to `]`.
  defp major_class(<<d, ?-, e, rest::binary>>) when d in ?0..?9 and e in ?0..?9,
    do: major_class_more(rest)

  defp major_class(<<d, rest::binary>>) when d in ?0..?9, do: major_class_more(rest)
  defp major_class(_text), do: :error

  defp major_class_more("]" <> rest), do: {:ok, rest}
  defp major_class_more(text), do: major_class(text)

  # Whether `fun` holds for `term` or anything inside it (lists, tuples,
  # maps). The parser bounds the nesting depth.
  defp any_term?(term, fun) do
    fun.(term) or Enum.any?(inner(term), &any_term?(&1, fun))
  end

  defp inner(term) when is_list(term), do: improper(term)
  defp inner(term) when is_tuple(term), do: Tuple.to_list(term)
  defp inner(term) when is_map(term), do: Enum.flat_map(term, fn {k, v} -> [k, v] end)
  defp inner(_term), do: []

  defp improper([head | tail]) when is_list(tail), do: [head | improper(tail)]
  defp improper([head | tail]), do: [head, tail]
  defp improper([]), do: []

  @doc """
  Whether the child VM trace `child` (`NccWorker.Tracer.Report`, `nil` when
  there is none) covers every beam in `ebin`: `:ok`, `{:gap, module}` for the
  one beam whose return a final `halt` may have dropped, `{:error, why}`
  (taint) or `{:unjudged, why}` (could not be judged).
  """
  @spec coverage(String.t() | nil, map() | nil) ::
          :ok | {:gap, String.t()} | {:error, String.t()} | {:unjudged, String.t()}
  def coverage(ebin, child) do
    case beams(ebin) do
      {:unjudged, _} = unjudged -> unjudged
      {:ok, beams} -> covered(beams, child, ebin)
    end
  end

  defp covered([], nil, _ebin), do: {:unjudged, "rebar3 built nothing and was not traced"}
  defp covered(_beams, nil, _ebin), do: {:error, "rebar3 compile was not traced"}

  defp covered(beams, child, ebin) do
    # The beam each module's last traced compile returned, by sha256.
    compiled =
      for %{"result" => "ok", "module" => m} = line <- child.compiles,
          into: %{},
          do: {m, line["beam_sha256"]}

    missing = Enum.reject(beams, &Map.has_key?(compiled, &1))

    cond do
      child.problems != [] ->
        {:error, "rebar3 trace incomplete"}

      child.sentinel? != true ->
        {:error, "rebar3 trace sentinel missing"}

      Enum.any?(child.compiles, &(&1["result"] != "ok")) ->
        {:unjudged, "rebar3 compile returned an error"}

      changed = changed_beam(beams -- missing, compiled, ebin) ->
        changed

      missing == [] ->
        :ok

      match?([_], missing) ->
        {:gap, hd(missing)}

      true ->
        {:error, "rebar3 compile of #{Enum.join(missing, ", ")} was not traced"}
    end
  end

  # Review S5 R1: each traced beam must be, byte for byte, what its compile
  # wrote when it returned (the tracer hashes the beam then), so anything
  # that wrote over it later, a hook or any other writer, taints.
  defp changed_beam(beams, compiled, ebin) do
    Enum.find_value(beams, &beam_changed(&1, compiled[&1], ebin))
  end

  defp beam_changed(module, sha, ebin) when is_binary(sha) do
    if beam_sha(ebin, module) == sha,
      do: nil,
      else: {:error, "rebar3 beam #{module} changed after its traced compile"}
  end

  defp beam_changed(module, _sha, _ebin),
    do: {:error, "rebar3 compile of #{module} recorded no beam hash"}

  @max_beam_bytes 64 * 1024 * 1024

  # `ebin` is the dependency's build ebin and `module` a beam file's name in it.
  # sobelow_skip ["Traversal.FileModule"]
  defp beam_sha(ebin, module) do
    path = Path.join(ebin, module <> ".beam")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
           File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower)
    else
      _ -> nil
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp beams(ebin) when is_binary(ebin) do
    if File.dir?(ebin) do
      {:ok,
       ebin
       |> Path.join("*.beam")
       |> Path.wildcard()
       |> Enum.map(&Path.basename(&1, ".beam"))
       |> Enum.sort()}
    else
      {:unjudged, "rebar3 ebin missing"}
    end
  end

  defp beams(_ebin), do: {:unjudged, "rebar3 ebin missing"}
end
