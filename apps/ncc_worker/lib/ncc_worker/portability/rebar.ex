defmodule NccWorker.Portability.Rebar do
  @moduledoc """
  Spec R1 "Other OS processes" and R0 for rebar3-built packages and closure
  dependencies. rebar3 compiles in its own VM, which the trace reaches only
  through `ERL_AFLAGS`; hooks and plugins run programs no trace sees, and
  `platform_define` is host dependence by definition when rebar compiles,
  except one whose regex can consume only the leading OTP major
  (precompiled judge refinements, item 3), which decides the same on every
  host. Any `provider_hooks` entry refuses too: providers come from plugins
  or run arbitrary build steps.

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
  refuses. A rebar3 parent's script stays could-not-judge: the overrides
  it hands its children are computed.

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
  active section, unless its regex can consume only the leading OTP major
  (precompiled judge refinements, item 3).

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

  Config files are anyone's text, so they are read with
  `NccWorker.Portability.HexFiles.parse/1` (bounded, creates no atoms)
  rather than `:file.consult/1`. A config that parser cannot read refuses.

  Coverage: a child VM's trace counts only when it fired its sentinel, has no
  problems, and recorded a successful `compile:file/2` return for every beam
  in the dependency's `ebin`. rebar3 ends with `erlang:halt/1`, which can
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
  # `REBAR_PROFILE=prod` on top of rebar3's default profile.
  @active_profiles ~w(default prod)
  @max_config_bytes 1024 * 1024
  @max_contents_bytes 64 * 1024 * 1024
  @config_files [~c"rebar.config", ~c"rebar.config.script"]

  @typedoc "A rebar3 app's own config files: `rebar.config`'s text (or `nil`) and whether it has a script."
  @type sources :: %{config: binary() | nil, script?: boolean()}

  @doc """
  The static rebar3 rules for the source dir `dest` as it is on disk and,
  when given, the `mix.rebar.config` Mix wrote for rebar3.
  """
  @spec check(String.t(), String.t() | nil) ::
          :ok | {:refuse, String.t()} | {:unjudged, String.t()}
  # A dependency's own build files, read as data; nothing is evaluated.
  # sobelow_skip ["Traversal.FileModule"]
  def check(dest, mix_config \\ nil) when is_binary(dest) do
    config =
      case read_file(Path.join(dest, "rebar.config")) do
        {:ok, text} -> text
        :absent -> nil
        :error -> :unreadable
      end

    sources = %{config: config, script?: File.exists?(Path.join(dest, "rebar.config.script"))}
    check_sources(sources, [], mix_config)
  end

  @doc """
  The static rebar3 rules for one app's `sources` (from its verified
  tarball), with the `sources` of its rebar3 parents, whose top-level
  `overrides` Mix applies to it, and the `mix.rebar.config` rebar3 read.
  """
  @spec check_sources(sources(), [sources()], String.t() | nil) ::
          :ok | {:refuse, String.t()} | {:unjudged, String.t()}
  def check_sources(%{script?: true}, _parents, nil),
    do: {:refuse, "rebar3 build evaluates rebar.config.script"}

  def check_sources(%{config: own}, parents, mix_config) do
    with {:ok, own_terms} <- parse_own(own),
         {:ok, inherited} <- parent_overrides(parents),
         :ok <- config({:ok, own_terms ++ inherited}) do
      mix_config(mix_config)
    end
  end

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
  # child's own config. A parent's script could compute them: unknowable.
  defp parent_overrides(parents) do
    Enum.reduce_while(parents, {:ok, []}, fn
      %{script?: true}, _acc ->
        {:halt, {:unjudged, "a rebar3 parent evaluates rebar.config.script"}}

      %{config: text}, {:ok, acc} ->
        case parse_own(text) do
          {:ok, terms} ->
            {:cont, {:ok, acc ++ for({{:atom, "overrides"}, _} = o <- terms, do: o)}}

          refusal ->
            {:halt, refusal}
        end
    end)
  end

  @doc """
  `rebar.config` and `rebar.config.script` from a Hex tarball's
  `contents.tar.gz`, inflated under a bound; `{:unjudged, _}` without a
  verified tarball or when it cannot be read.
  """
  @spec tarball_sources(binary() | nil) :: {:ok, sources()} | {:unjudged, String.t()}
  def tarball_sources(nil), do: {:unjudged, "rebar3 app has no verified Hex tarball"}

  def tarball_sources(bytes) when is_binary(bytes) do
    with {:ok, tar} <- contents_tar(bytes),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory, {:files, @config_files}]) do
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
    {:ok,
     %{
       config: Map.get(files, "rebar.config"),
       script?: Map.has_key?(files, "rebar.config.script")
     }}
  end

  defp mix_config(nil), do: :ok

  defp mix_config({:unjudged, _} = unjudged), do: unjudged

  # sobelow_skip ["Traversal.FileModule"]
  defp mix_config(path) when is_binary(path) do
    case read_file(path) do
      {:ok, text} -> config(HexFiles.parse(text))
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

  defp config({:ok, terms}) do
    sections = active_sections(terms)

    # `overrides` of every active section, top level and profiles alike.
    overrides =
      for section <- sections,
          {{:atom, "overrides"}, value} <- List.wrap(section),
          do: value

    case Enum.find(@hook_keys, &(runs?(sections, &1) or nested?(overrides, &1))) do
      # The sections hold their `overrides` already.
      nil -> platform_define(sections)
      key -> {:refuse, "rebar3 build runs #{key}"}
    end
  end

  defp config(:error), do: {:refuse, "rebar3 build config unreadable"}

  # The top level and the bodies of the profiles active under Mix's rebar3
  # call, each a list of `{key, value}` terms.
  defp active_sections(terms) do
    profiles =
      for {{:atom, "profiles"}, list} when is_list(list) <- terms,
          {{:atom, name}, body} when name in @active_profiles and is_list(body) <- list,
          do: body

    [terms | profiles]
  end

  defp runs?(sections, key) do
    Enum.any?(sections, fn section ->
      Enum.any?(List.wrap(section), &match?({{:atom, ^key}, value} when value != [], &1))
    end)
  end

  defp nested?(terms, key) do
    any_term?(terms, fn
      {{:atom, ^key}, value} -> value != []
      _ -> false
    end)
  end

  # Ignoring `project_plugins` and inactive profiles at the top level. Item 3
  # (precompiled judge refinements): a `platform_define` whose regex can
  # consume only the leading OTP major (`otp_major_only?/1`) is accepted;
  # any other one refuses, as before.
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

    if Enum.all?(defines, &otp_major_only?/1),
      do: :ok,
      else: {:refuse, "rebar3 build uses platform_define"}
  end

  defp inactive?({{:atom, key}, _value}), do: key in ["profiles", "project_plugins"]
  defp inactive?(_term), do: false

  # Every term in `term`, itself included, for which `fun` holds.
  defp collect(term, fun) do
    own = if fun.(term), do: [term], else: []
    own ++ Enum.flat_map(inner(term), &collect(&1, fun))
  end

  # `rebar_utils:get_arch/0` is `<full OTP version>-<arch>-<wordsize>`, and
  # the client checks only the OTP major. A regex of `^` followed only by
  # digits, `R`, classes of digits and `( | )` groups of the same can only
  # consume characters before the first `.` or `-`, so it decides the same
  # on every host and patch of the build's major. Evaluated against the
  # major followed by `.` and by `-`: both must agree.
  defp otp_major_only?({{:atom, "platform_define"}, regex, _key}), do: major_regex?(regex)

  defp otp_major_only?({{:atom, "platform_define"}, regex, _key, _value}),
    do: major_regex?(regex)

  defp otp_major_only?(_define), do: false

  defp major_regex?(regex) do
    with {:ok, text} <- regex_text(regex),
         "^" <> body <- text,
         {:ok, ""} <- major_seq(body),
         {:ok, compiled} <- Regex.compile(text) do
      major = :erlang.system_info(:otp_release) |> List.to_string()
      Regex.match?(compiled, major <> ".") == Regex.match?(compiled, major <> "-")
    else
      _ -> false
    end
  end

  defp regex_text(text) when is_binary(text),
    do: if(String.valid?(text), do: {:ok, text}, else: :error)

  defp regex_text([_ | _] = chars) do
    if Enum.all?(chars, &is_integer/1), do: {:ok, List.to_string(chars)}, else: :error
  rescue
    _ -> :error
  end

  defp regex_text(_regex), do: :error

  # The grammar: items until something else, returning what is left.
  defp major_seq(<<c, rest::binary>>) when c in ?0..?9 or c == ?R, do: major_seq(rest)

  defp major_seq("[" <> rest) do
    with {:ok, rest} <- major_class(rest), do: major_seq(rest)
  end

  defp major_seq("(" <> rest) do
    with {:ok, rest} <- major_group(rest), do: major_seq(rest)
  end

  defp major_seq(rest), do: {:ok, rest}

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
      {:ok, beams} -> covered(beams, child)
    end
  end

  defp covered([], nil), do: {:unjudged, "rebar3 built nothing and was not traced"}
  defp covered(_beams, nil), do: {:error, "rebar3 compile was not traced"}

  defp covered(beams, child) do
    compiled = for %{"result" => "ok", "module" => m} <- child.compiles, into: MapSet.new(), do: m
    missing = Enum.reject(beams, &MapSet.member?(compiled, &1))

    cond do
      child.problems != [] ->
        {:error, "rebar3 trace incomplete"}

      child.sentinel? != true ->
        {:error, "rebar3 trace sentinel missing"}

      Enum.any?(child.compiles, &(&1["result"] != "ok")) ->
        {:unjudged, "rebar3 compile returned an error"}

      missing == [] ->
        :ok

      match?([_], missing) ->
        {:gap, hd(missing)}

      true ->
        {:error, "rebar3 compile of #{Enum.join(missing, ", ")} was not traced"}
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
