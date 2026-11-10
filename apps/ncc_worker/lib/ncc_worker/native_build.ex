defmodule NccWorker.NativeBuild do
  @moduledoc """
  Rule 2's reading of a native build file (precompiled judge refinements
  spec, item 1): a `Makefile`, `CMakeLists.txt` or the like in a
  dependency's tarball counts only when Mix runs `make` for it.

  Mix picks the manager in `Mix.Dep.Loader` (Elixir 1.19.1-1.20.4): a
  `manager:` option, else the first of `:mix`, `:rebar3` in the lock
  entry's `managers` (the package's `build_tools`), else the parent's
  manager, else the files (`infer_manager/1`). `computed/2` takes the lock
  and the files only, so a dependency whose lock names neither `mix` nor
  `rebar3` counts as `make` or unknown and stays native. What Mix actually
  ran is the trace's closure line; `NccWorker.Portability` refuses
  ("manager mismatch") when it differs from this for a dependency `split/1`
  declassified.

  `c_src`/`native`/`zig_src`/`go_src`, rebar `port_specs`/`port_env`, a
  target read and a `nerves*` name stay native. The grep for a `mix.exs`
  naming `elixir_make`, `rustler` and the like stays too, but it is only a
  hint: the defences that hold are the trace refusing a compile-time
  `open_port`/`os:cmd` (`programs`, which also catches a custom Mix
  compiler that shells out), a `load_nif` call failing the static beam
  scan, and `NccWorker.StaticPriv` refusing priv files the tarball does not
  carry. Rule 1, the build cache and the Nerves classification keep
  `NccWorker.BuildCache.dep_target_agnostic?/2`.
  """

  alias NccWorker.{BuildCache, DepsLock}

  @rebar_files ~w(rebar rebar.config rebar.config.script rebar.lock)
  @make_files ~w(Makefile Makefile.win)
  @mix_managers ~w(mix rebar3)

  @doc """
  The manager Mix runs for the dependency in `dest`, from its lock
  `managers` (`nil`: no lock entry) and its files: `"mix"`, `"rebar3"`,
  `"make"` or `nil`.
  """
  @spec computed([String.t()] | nil, String.t()) :: String.t() | nil
  def computed(nil, _dest), do: nil

  def computed(managers, dest) when is_list(managers) do
    cond do
      "mix" in managers -> "mix"
      "rebar3" in managers -> "rebar3"
      true -> from_files(dest)
    end
  end

  @doc "`computed/2` for `deps/<name>` of the project, from its `mix.lock`."
  @spec manager(String.t(), String.t()) :: String.t() | nil
  def manager(project_dir, name) do
    case DepsLock.managers(project_dir) do
      {:ok, managers} -> computed(Map.get(managers, name), Path.join([project_dir, "deps", name]))
      :error -> nil
    end
  end

  @doc """
  The project's dependencies under `deps/`, sorted, split for rule 2:
  `native`, the ones `BuildCache.dep_target_agnostic?/2` refuses except a
  native build file Mix never runs, and `declassified`, `%{app => manager}`
  for exactly the ones that exception turned non-native.
  """
  @spec split(String.t()) :: {[String.t()], %{String.t() => String.t()}}
  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  def split(project_dir) do
    deps = Path.join(project_dir, "deps")

    managers =
      case DepsLock.managers(project_dir) do
        {:ok, managers} -> managers
        :error -> %{}
      end

    case File.ls(deps) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reduce({[], %{}}, &split_one(deps, managers, &1, &2))

      {:error, _reason} ->
        {[], %{}}
    end
  end

  defp split_one(deps, managers, name, {native, declassified}) do
    manager = computed(Map.get(managers, name), Path.join(deps, name))

    cond do
      BuildCache.dep_target_agnostic?(deps, name) ->
        {native, declassified}

      manager in @mix_managers and BuildCache.dep_target_agnostic_rule2?(deps, name, manager) ->
        {native, Map.put(declassified, name, manager)}

      true ->
        {native ++ [name], declassified}
    end
  end

  # `Mix.Dep.Loader.infer_manager/1`, read only.
  # sobelow_skip ["Traversal.FileModule"]
  defp from_files(dest) do
    cond do
      File.regular?(Path.join(dest, "mix.exs")) -> "mix"
      Enum.any?(@rebar_files, &File.regular?(Path.join(dest, &1))) -> "rebar3"
      Enum.any?(@make_files, &File.regular?(Path.join(dest, &1))) -> "make"
      true -> nil
    end
  end
end
