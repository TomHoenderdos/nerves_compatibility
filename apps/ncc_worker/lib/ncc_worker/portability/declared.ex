defmodule NccWorker.Portability.Declared do
  @moduledoc """
  The dependencies the closure's members declare that the build lacks (an
  optional dependency left out of this variant), with the modules and the
  application each one holds (`NccWorker.Portability.Probes`, fix round 2).

  A package's probe of such a module is no false hit on the host: the client
  serves a build only to a project whose package closure equals the build's
  (`Precompiled.Match.closure_ok/4`), and Mix makes a present optional
  dependency a child of the member that declares it, in a project and under
  Mix.install alike. A user who has the dependency is never served the build
  that lacks it.

  The declarations are each member's verified Hex tarball's `requirements`
  (`metadata.config`, read by `NccWorker.Portability.HexFiles.parse/1`), of
  the `hexpm` repository only. A declared dependency's modules come from its
  tarballs in the run's Hex cache, any version (the host puts there only
  tarballs it checked against Hex.pm): every literal `defmodule`,
  `defprotocol` and `defimpl` name in its `.ex` sources, parsed without
  creating atoms, and every `-module` of its `.erl` sources. A module a macro
  defines is not found, and a declared dependency with no cached tarball
  holds no known module: a probe of either refuses as before. Its
  application, which the declaration names, is known either way.

  The residual risk is a module name two packages define: a user with the
  other one, undeclared, would find the module. Never raises.

  `fetch/4` runs before the judge (`NccWorker.Portability.run/3`): it
  downloads the latest release of every declared-absent dependency the run's
  Hex cache lacks, with Hex itself (`mix hex.package fetch`, which keeps the
  tarball in `HEX_HOME`), bounded in count and time. What it downloads is a
  run's miss like any other: the host checks it against Hex.pm before it
  promotes it (`NccWorker.HexCache`). A failed fetch leaves those modules
  unknown, so their probes refuse. `NCC_DECLARED_FETCH=0` turns the
  download off (the ncc_worker test helper sets it: fixtures judge from the
  Hex cache they lay out themselves).
  """

  alias NccWorker.Portability.{Context, HexFiles, Rebar}

  @tarball ~r/\A([a-z][a-z0-9_]*)-([0-9][0-9A-Za-z.+\-]*)\.tar\z/
  # Versions read per declared dependency, newest first.
  @max_versions 3
  # The source bytes one dependency's tarball may have parsed.
  @max_source_bytes 32 * 1024 * 1024
  @max_files 5_000
  @max_fetch 64
  @fetch_timeout_sec 120
  @name ~r/\A[a-z][a-z0-9_]*\z/

  @type t :: %{modules: %{String.t() => [String.t()]}, apps: %{String.t() => [String.t()]}}

  @doc "The declared-absent dependencies' modules and applications, each with the members that declare it."
  @spec index(Context.t()) :: t()
  def index(%Context{deps: deps, hex: {home, _releases}} = ctx) do
    present = deps |> Map.keys() |> MapSet.new()

    declared =
      for {member, _dep} <- deps,
          req <- requirements(Context.tarball(ctx, member)),
          not MapSet.member?(present, req.app),
          do: {req, member}

    apps =
      declared
      |> Enum.group_by(fn {req, _} -> req.app end, &elem(&1, 1))
      |> Map.new(fn {app, members} -> {app, members |> Enum.uniq() |> Enum.sort()} end)

    modules =
      for {name, members} <- Enum.group_by(declared, fn {req, _} -> req.name end, &elem(&1, 1)),
          module <- modules_of(home, name),
          reduce: %{} do
        acc -> Map.update(acc, module, Enum.uniq(members), &Enum.uniq(&1 ++ members))
      end

    %{modules: Map.new(modules, fn {m, ms} -> {m, Enum.sort(ms)} end), apps: apps}
  rescue
    _ -> %{modules: %{}, apps: %{}}
  end

  def index(_ctx), do: %{modules: %{}, apps: %{}}

  @doc """
  Downloads into `home` (the run's `HEX_HOME`) the declared-absent
  dependencies of the locked `releases` (`%{app => %{name, version,
  checksum}}`, each read from its verified tarball) that `home` holds no
  tarball of. Returns `{:ok, names}` (fetched or tried) or the fetch's
  error. `fetch:` replaces the download (tests).
  """
  @spec fetch(String.t() | nil, map(), list(), keyword()) ::
          {:ok, [String.t()]} | {:error, term()}
  def fetch(home, releases, env, opts \\ [])

  def fetch(home, releases, env, opts) when is_binary(home) and is_map(releases) do
    locked = MapSet.new(Map.keys(releases))

    names =
      for {app, _release} <- releases,
          req <- requirements(Context.release_tarball(home, releases, app)),
          not MapSet.member?(locked, req.app),
          not cached?(home, req.name),
          uniq: true,
          do: req.name

    case names |> Enum.sort() |> Enum.take(@max_fetch) do
      [] ->
        {:ok, []}

      names ->
        fun = Keyword.get_lazy(opts, :fetch, &default_fetch/0)

        case fun.(names, home: home, env: env) do
          :ok -> {:ok, names}
          {:error, _why} = error -> error
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def fetch(_home, _releases, _env, _opts), do: {:ok, []}

  defp default_fetch do
    if System.get_env("NCC_DECLARED_FETCH") == "0",
      do: fn _names, _opts -> {:error, :off} end,
      else: &hex_fetch/2
  end

  @doc false
  # The `mix run` script that fetches `names`, one Hex task per name, each
  # failure caught. Names match `@name`, so no quoting can break out.
  @spec fetch_script([String.t()], String.t()) :: String.t()
  def fetch_script(names, out) do
    true = Enum.all?(names, &Regex.match?(@name, &1))

    """
    for n <- #{inspect(names)} do
      try do
        Mix.Task.rerun("hex.package", ["fetch", n, "--output", #{inspect(out)}])
      catch
        _, _ -> :error
      end
    end
    """
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp cached?(home, name) do
    case File.ls(Path.join([home, "packages", "hexpm"])) do
      {:ok, files} -> Enum.any?(files, &match?([_, ^name, _], Regex.run(@tarball, &1)))
      _ -> false
    end
  end

  # `mix hex.package fetch` keeps each tarball in HEX_HOME's cache as well
  # as at `--output`, a scratch dir beside the run's HEX_HOME. Under
  # timeout(1) where there is one.
  # sobelow_skip ["CI.System", "Traversal.FileModule"]
  defp hex_fetch(names, opts) do
    home = Keyword.fetch!(opts, :home)
    out = Path.join(Path.dirname(home), "declared-fetch")
    File.mkdir_p!(out)
    script = fetch_script(names, out)
    env = Keyword.get(opts, :env, []) ++ [{"HEX_HOME", home}]
    mix = ["mix", "run", "--no-mix-exs", "-e", script]

    {command, args} =
      case System.find_executable("timeout") do
        nil -> {"mix", tl(mix)}
        t -> {t, ["--kill-after=10", "#{@fetch_timeout_sec}" | mix]}
      end

    {_output, code} = System.cmd(command, args, cd: out, env: env, stderr_to_stdout: true)
    if code == 0, do: :ok, else: {:error, {:exit, code}}
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc "The `hexpm` requirements a Hex tarball's `metadata.config` declares."
  @spec requirements(binary() | nil) :: [%{name: String.t(), app: String.t()}]
  def requirements(bytes) when is_binary(bytes) do
    with {:ok, [{_, meta}]} <-
           :erl_tar.extract({:binary, bytes}, [:memory, {:files, [~c"metadata.config"]}]),
         {:ok, terms} <- HexFiles.parse(meta),
         {_key, reqs} <- List.keyfind(terms, "requirements", 0) do
      for r <- entries(reqs), req = requirement(r), req != nil, do: req
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  def requirements(_bytes), do: []

  # Hex writes a list of property lists (metadata 1.0 and later); older
  # releases a list of `{name, props}` or a map by name.
  defp entries(reqs) when is_list(reqs), do: reqs
  defp entries(reqs) when is_map(reqs), do: Enum.map(reqs, fn {n, props} -> {n, props} end)
  defp entries(_reqs), do: []

  defp requirement({name, props}) when is_binary(name),
    do: requirement([{"name", name} | props(props)])

  defp requirement(props) when is_list(props) do
    map = Map.new(for {k, v} <- props, is_binary(k), do: {k, v})

    with name when is_binary(name) <- map["name"],
         true <- Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name),
         repo when repo in [nil, "hexpm"] <- map["repository"] do
      app = if is_binary(map["app"]), do: map["app"], else: name
      %{name: name, app: app}
    else
      _ -> nil
    end
  end

  defp requirement(_other), do: nil

  defp props(props) when is_list(props), do: props
  defp props(props) when is_map(props), do: Map.to_list(props)
  defp props(_props), do: []

  # sobelow_skip ["Traversal.FileModule"]
  defp modules_of(home, name) when is_binary(home) do
    dir = Path.join([home, "packages", "hexpm"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(fn file ->
          case Regex.run(@tarball, file) do
            [_, ^name, version] -> [{version, Path.join(dir, file)}]
            _ -> []
          end
        end)
        |> Enum.sort_by(&elem(&1, 0), &newer?/2)
        |> Enum.take(@max_versions)
        |> Enum.flat_map(fn {_version, path} -> tarball_modules(path) end)
        |> Enum.uniq()

      _ ->
        []
    end
  end

  defp modules_of(_home, _name), do: []

  defp newer?(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp tarball_modules(path) do
    max = Compatibility.StaticPriv.max_tarball_bytes()

    with {:ok, bytes} when byte_size(bytes) <= max <-
           File.open(path, [:read, :raw, :binary], &IO.binread(&1, max + 1)),
         {:ok, tar} <- Rebar.contents_tar(bytes),
         {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory]) do
      files
      |> Enum.take(@max_files)
      |> Enum.reduce({[], 0}, fn {name, body}, {acc, bytes} ->
        source(List.to_string(name), body, acc, bytes)
      end)
      |> elem(0)
    else
      _ -> []
    end
  rescue
    _ -> []
  end

  defp source(_name, body, acc, bytes) when bytes + byte_size(body) > @max_source_bytes,
    do: {acc, bytes}

  defp source(name, body, acc, bytes) do
    cond do
      String.ends_with?(name, ".ex") and String.valid?(body) ->
        {elixir_modules(body) ++ acc, bytes + byte_size(body)}

      String.ends_with?(name, ".erl") ->
        {erlang_modules(body) ++ acc, bytes + byte_size(body)}

      true ->
        {acc, bytes}
    end
  end

  defp erlang_modules(body) do
    case Regex.run(~r/^-module\(\s*'?([a-z][A-Za-z0-9_@]*)'?\s*\)/m, body) do
      [_, m] -> [m]
      _ -> []
    end
  end

  # No atom is created: every atom of the source comes back as {:atom, name}.
  defp elixir_modules(body) do
    case Code.string_to_quoted(body,
           static_atoms_encoder: fn name, _meta -> {:ok, {:atom, name}} end,
           existing_atoms_only: true,
           columns: false,
           emit_warnings: false
         ) do
      {:ok, ast} -> ast |> walk(nil, []) |> Enum.uniq()
      _ -> []
    end
  rescue
    _ -> []
  end

  defp walk({{:atom, kind}, _, [name_ast | rest]}, outer, acc)
       when kind in ["defmodule", "defprotocol"] do
    case alias_name(name_ast, outer) do
      nil -> walk(rest, outer, acc)
      name -> walk(rest, name, [name | acc])
    end
  end

  defp walk({{:atom, "defimpl"}, _, [proto_ast | rest]}, outer, acc) do
    proto = alias_name(proto_ast, nil)
    fors = rest |> Enum.filter(&is_list/1) |> Enum.flat_map(&for_option/1)
    fors = if fors == [] and outer, do: [outer], else: Enum.map(fors, &alias_name(&1, nil))

    impls =
      for f <- fors,
          is_binary(proto) and is_binary(f),
          do: proto <> "." <> String.replace_prefix(f, "Elixir.", "")

    walk(rest, outer, impls ++ acc)
  end

  defp walk({a, _meta, args}, outer, acc), do: walk(args, outer, walk(a, outer, acc))
  defp walk({l, r}, outer, acc), do: walk(r, outer, walk(l, outer, acc))
  defp walk(list, outer, acc) when is_list(list), do: Enum.reduce(list, acc, &walk(&1, outer, &2))
  defp walk(_other, _outer, acc), do: acc

  defp for_option(kw) do
    Enum.flat_map(kw, fn
      {key, value} when key in [:for, {:atom, "for"}] -> List.wrap(value)
      _ -> []
    end)
  end

  # A literal alias, nested under the enclosing module unless it starts at
  # `Elixir`; `__MODULE__` or anything dynamic names nothing.
  defp alias_name({:__aliases__, _, parts}, outer) do
    names = for {:atom, p} <- parts, do: p

    cond do
      length(names) != length(parts) -> nil
      hd(names) == "Elixir" -> Enum.join(names, ".")
      is_binary(outer) -> outer <> "." <> Enum.join(names, ".")
      true -> "Elixir." <> Enum.join(names, ".")
    end
  end

  defp alias_name({:atom, name}, _outer), do: name
  defp alias_name(_other, _outer), do: nil
end
