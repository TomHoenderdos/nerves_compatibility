defmodule NccWorker.Portability.Rebar do
  @moduledoc """
  Spec R1 "Other OS processes" and R0 for rebar3-built packages and closure
  dependencies. rebar3 compiles in its own VM, which the trace reaches only
  through `ERL_AFLAGS`; hooks and plugins run programs no trace sees, and
  `platform_define` and `rebar.config.script` are host dependence by
  definition when rebar compiles. Any `provider_hooks` entry refuses too:
  providers come from plugins or run arbitrary build steps.

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
  active section.

  Both files are checked, each with the same rules: the dependency's own
  `rebar.config` and, when the judge passes it, the `mix.rebar.config` that
  rebar3 actually read; a missing one of those is could-not-judge.
  `rebar.config.script` refuses on its own: it is code.

  Config files are anyone's text, so they are read with
  `NccWorker.Portability.HexFiles.parse/1` (bounded, creates no atoms)
  rather than `:file.consult/1`. A config that parser cannot read refuses.

  Coverage: a child VM's trace counts only when it fired its sentinel, has no
  problems, and recorded a successful `compile:file/2` return for every beam
  in the dependency's `ebin`. rebar3 ends with `erlang:halt/1`, which can
  drop the collector's last queued line, the return of a compile. The tracer
  records returns only, so which one was last cannot be checked (controller
  ruling, re-ruling M2): at most one beam without a return per child, with
  the sentinel present and the trace otherwise clean, is a `{:gap, module}`
  the judge records in `trace_stats`; the reads of that compile were still
  traced. Two or more are an `{:error, _}`, which taints.

  `{:unjudged, _}` (could not be judged, never a gap or taint): a compile
  that returned an error, a missing `ebin`, or an empty `ebin` with no child
  trace at all, which proves nothing about what rebar3 ran.
  """

  alias NccWorker.Portability.HexFiles

  @hook_keys ~w(pre_hooks post_hooks provider_hooks plugins)
  # `REBAR_PROFILE=prod` on top of rebar3's default profile.
  @active_profiles ~w(default prod)
  @max_config_bytes 1024 * 1024

  @doc """
  The static rebar3 rules for the source dir `dest` and, when given, the
  `mix.rebar.config` Mix wrote for rebar3.
  """
  @spec check(String.t(), String.t() | nil) ::
          :ok | {:refuse, String.t()} | {:unjudged, String.t()}
  # A dependency's own build files, read as data; nothing is evaluated.
  # sobelow_skip ["Traversal.FileModule"]
  def check(dest, mix_config \\ nil) when is_binary(dest) do
    config = Path.join(dest, "rebar.config")

    cond do
      File.exists?(Path.join(dest, "rebar.config.script")) ->
        {:refuse, "rebar3 build evaluates rebar.config.script"}

      File.exists?(config) ->
        with :ok <- config |> read_config() |> config(), do: mix_config(mix_config)

      true ->
        mix_config(mix_config)
    end
  end

  defp mix_config(nil), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp mix_config(path) when is_binary(path) do
    if File.exists?(path),
      do: path |> read_config() |> config(),
      else: {:unjudged, "rebar3 mix.rebar.config missing"}
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_config(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_config_bytes <-
           File.stat(path),
         {:ok, text} <- File.read(path) do
      HexFiles.parse(text)
    else
      _ -> :error
    end
  end

  defp config({:ok, terms}) do
    sections = active_sections(terms)
    overrides = for {{:atom, "overrides"}, value} <- terms, do: value

    case Enum.find(@hook_keys, &(runs?(sections, &1) or nested?(overrides, &1))) do
      nil -> platform_define(sections ++ overrides)
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

  # Ignoring `project_plugins` and inactive profiles at the top level.
  defp platform_define(sections) do
    searched =
      Enum.map(sections, fn
        section when is_list(section) -> Enum.reject(section, &inactive?/1)
        other -> other
      end)

    pd? =
      any_term?(
        searched,
        &(is_tuple(&1) and tuple_size(&1) > 0 and elem(&1, 0) == {:atom, "platform_define"})
      )

    if pd?, do: {:refuse, "rebar3 build uses platform_define"}, else: :ok
  end

  defp inactive?({{:atom, key}, _value}), do: key in ["profiles", "project_plugins"]
  defp inactive?(_term), do: false

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
