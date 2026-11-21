defmodule NccWorker.NativeBuild do
  @moduledoc """
  Rule 2's reading of a native build file (precompiled judge refinements
  spec, item 1): a `Makefile`, `CMakeLists.txt` or the like in a
  dependency's tarball counts only when Mix runs `make` for it.

  Mix picks the manager in `Mix.Dep.Loader` (Elixir 1.19.1-1.20.4): a
  `manager:` option, else the first of `:mix`, `:rebar3` in the lock
  entry's `managers` (the package's `build_tools`), else the parent's
  manager, else the files (`infer_manager/1`). `computed/2` takes the
  `build_tools` and the files only, so a dependency whose `build_tools`
  name neither `mix` nor `rebar3` counts as `make` or unknown and stays
  native.

  The `build_tools` are read from the `metadata.config` of the
  dependency's checksum-verified Hex tarball (`build_tools/1`), never from
  `mix.lock`: a dependency's `mix.exs`, evaluated during the untraced
  `deps.get`, could rewrite another dependency's `managers` there. Without
  a verified, readable tarball that lists them, the dependency is never
  declassified. What Mix actually
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

  alias NccWorker.{BuildCache, StaticPriv}
  alias NccWorker.Portability.HexFiles

  @rebar_files ~w(rebar rebar.config rebar.config.script rebar.lock)
  @make_files ~w(Makefile Makefile.win)
  @mix_managers ~w(mix rebar3)

  @doc """
  The manager Mix runs for the dependency in `dest`, from its `managers`
  (its Hex `build_tools`; `nil`: unknown) and its files: `"mix"`,
  `"rebar3"`, `"make"` or `nil`.
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

  @doc """
  `computed/2` for the dependency in `dest` from its Hex `tarball` (a path
  or `{:binary, bytes}`, as `NccWorker.StaticPriv.check/3` takes; `nil`
  gives `nil`). The caller vouches for the tarball (its outer checksum).
  """
  @spec manager(Path.t() | {:binary, binary()} | nil, String.t()) :: String.t() | nil
  def manager(tarball, dest),
    do: tarball |> StaticPriv.tarball_bytes() |> build_tools() |> computed(dest)

  @doc """
  The `build_tools` a Hex tarball's `metadata.config` lists (what Hex
  writes into the lock as `managers`), as strings; `nil` when there is no
  tarball, it cannot be read, or it lists none (fail closed: Mix would fall
  to the files, rule 2 keeps the dependency native).
  """
  @spec build_tools(binary() | nil) :: [String.t()] | nil
  def build_tools(bytes) when is_binary(bytes) do
    with {:ok, [{_name, meta}]} <-
           :erl_tar.extract({:binary, bytes}, [:memory, {:files, [~c"metadata.config"]}]),
         {:ok, terms} <- HexFiles.parse(meta),
         {_key, [_ | _] = tools} <- List.keyfind(terms, "build_tools", 0),
         true <- Enum.all?(tools, &is_binary/1) do
      tools
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  def build_tools(_bytes), do: nil

  @doc """
  The project's dependencies under `deps/`, sorted, split for rule 2:
  `native`, the ones `BuildCache.dep_target_agnostic?/2` refuses except a
  native build file Mix never runs, and `declassified`, `%{app => manager}`
  for exactly the ones that exception turned non-native. `tarball_of`
  gives a dependency's verified Hex tarball bytes, or `nil` (it then stays
  native). A `deps/` that cannot be listed gives `{[], %{}}`: callers that
  must tell that from no dependencies list it themselves. `deps` is the
  dir the compile reads them from instead of `deps/` (a firmware target's
  `deps_<target>`).

  `package:` names the package under test (judge revision 21): a target
  read in one of its doc files (`NccWorker.TargetScan.doc_file?/1`, a
  README naming `MIX_TARGET`) does not count for it, as it does not in
  `NccWorker.BuildSelection.static_rules/4`. It is then declassified like
  any other, held to its manager. Its other checks, and every dependency's,
  are whole. `deps` must be a path or `nil` and `opts` a keyword list: an
  option list in the `deps` place raises rather than reading no `deps/`
  at all (every dependency non-native).

  `native_side: true` (S3) passes the same to the rule-2 predicate, which
  then reads a bare `alias Mix` and a `function_exported('Elixir.Mix', ...)`
  check as no target read (`BuildCache.dep_target_agnostic_rule2?/4`).
  """
  @spec split(String.t(), (String.t() -> binary() | nil), String.t() | nil, keyword()) ::
          {[String.t()], %{String.t() => String.t()}}
  # The run's own project dir.
  # sobelow_skip ["Traversal.FileModule"]
  def split(project_dir, tarball_of, deps \\ nil, opts \\ [])
      when (is_binary(deps) or is_nil(deps)) and is_list(opts) do
    deps = deps || Path.join(project_dir, "deps")
    package = Keyword.get(opts, :package)
    side = Keyword.get(opts, :native_side) == true

    case File.ls(deps) do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce({[], %{}}, &split_one(deps, tarball_of, {package, side}, &1, &2))

      {:error, _reason} ->
        {[], %{}}
    end
  end

  defp split_one(deps, tarball_of, {package, side}, name, {native, declassified}) do
    manager = computed(build_tools(tarball_of.(name)), Path.join(deps, name))
    rule2_opts = if is_binary(package) and name == package, do: [docs: false], else: []
    rule2_opts = if side, do: [native_side: true] ++ rule2_opts, else: rule2_opts

    cond do
      BuildCache.dep_target_agnostic?(deps, name) ->
        {native, declassified}

      manager in @mix_managers and
          BuildCache.dep_target_agnostic_rule2?(deps, name, manager, rule2_opts) ->
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
