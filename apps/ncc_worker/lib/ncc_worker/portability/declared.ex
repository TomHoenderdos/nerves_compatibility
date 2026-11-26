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
  tarballs it checked against Hex.pm), read by `Compatibility.HexModules`.
  A module a macro defines is not found, and a declared dependency with no
  cached tarball
  holds no known module: a probe of either refuses as before. Its
  application, which the declaration names, is known either way.

  The residual risk is a module name two packages define: a user with the
  other one, undeclared, would find the module. Never raises.

  `fetch/4` runs before the judge (`NccWorker.Portability.run/3`), only
  when a probe this index decides was traced: it downloads the latest
  release of every declared-absent dependency the run's Hex cache lacks,
  with Hex itself (`mix hex.package fetch`, which checks it against the
  signed registry), bounded in count and in time by the BEAM. What it
  downloads is a run's miss like any other: the host checks it against
  Hex.pm before it promotes it (`NccWorker.HexCache`). A failed, partial or
  killed fetch leaves those modules unknown, so their probes are no
  declared-absent ones. Since S10 such a probe is a `probe` compile input
  with no known definer (`NccWorker.Portability.Probes`), which client 0.10
  checks against the user's deps' own sources; a verdict a refusal of such
  a probe still decides says nothing about the package and is a transient
  could-not-judge, which the portal retries
  (`NccWorker.Portability.settle_declared/1`, coverage drop 2026-11-22,
  F7). `NCC_DECLARED_FETCH=0` turns the
  download off (the ncc_worker test helper sets it: fixtures judge from the
  Hex cache they lay out themselves).
  """

  alias NccWorker.Portability.{Context, HexFiles}

  @tarball ~r/\A([a-z][a-z0-9_]*)-([0-9][0-9A-Za-z.+\-]*)\.tar\z/
  # Versions read per declared dependency, newest first.
  @max_versions 3
  @max_fetch 64
  @fetch_timeout_sec 120
  @name ~r/\A[a-z][a-z0-9_]*\z/
  @no_facts %{modules: [], protocols: [], impls: []}

  @type t :: %{
          modules: %{String.t() => [String.t()]},
          apps: %{String.t() => [String.t()]},
          owners: %{String.t() => [String.t()]},
          packages: %{String.t() => String.t()},
          gated: %{String.t() => [String.t()]}
        }

  @doc """
  The declared-absent dependencies' modules and applications, each with the
  members that declare it (`modules`, `apps`), each module with the
  declared packages that define it (`owners`), and each declared package's
  application (`packages`). `gated` (S10 round 3, the declared-optional-
  dependency rule's review gate) holds each module with the declared
  packages whose own tarball defines it in their own namespace, not as a
  protocol's implementation (`gate?/3`). Declared-absent: an
  `optional: true` requirement (round 3, R2-3: a non-optional one the build
  lacks is a `targets:` dependency, which Mix still makes a child of its
  declarer) whose application the lock does not hold.
  """
  @spec index(Context.t()) :: t()
  def index(%Context{deps: deps, hex: {home, releases}} = ctx) do
    present = deps |> Map.keys() |> Enum.concat(Map.keys(releases || %{})) |> MapSet.new()

    declared =
      for {member, _dep} <- deps,
          req <- requirements(Context.tarball(ctx, member)),
          req.optional,
          not MapSet.member?(present, req.app),
          do: {req, member}

    apps =
      declared
      |> Enum.group_by(fn {req, _} -> req.app end, &elem(&1, 1))
      |> Map.new(fn {app, members} -> {app, members |> Enum.uniq() |> Enum.sort()} end)

    packages = Map.new(declared, fn {req, _} -> {req.name, req.app} end)

    {modules, owners, gated} =
      for {name, members} <- Enum.group_by(declared, fn {req, _} -> req.name end, &elem(&1, 1)),
          facts = facts_of(home, name),
          module <- facts.modules,
          reduce: {%{}, %{}, %{}} do
        {acc, own, gate} ->
          gate =
            if gate?(module, facts, Map.get(packages, name, name)),
              do: Map.update(gate, module, [name], &Enum.uniq([name | &1])),
              else: gate

          {Map.update(acc, module, Enum.uniq(members), &Enum.uniq(&1 ++ members)),
           Map.update(own, module, [name], &Enum.uniq([name | &1])), gate}
      end

    %{
      modules: Map.new(modules, fn {m, ms} -> {m, Enum.sort(ms)} end),
      apps: apps,
      owners: Map.new(owners, fn {m, ns} -> {m, Enum.sort(ns)} end),
      packages: packages,
      gated: Map.new(gated, fn {m, ns} -> {m, Enum.sort(ns)} end)
    }
  rescue
    _ -> empty()
  end

  def index(_ctx), do: empty()

  @doc "The index of a build that declares nothing absent."
  @spec empty() :: t()
  def empty, do: %{modules: %{}, apps: %{}, owners: %{}, packages: %{}, gated: %{}}

  @doc """
  The review gate of the declared-optional-dependency rule (S10 round 3):
  whether a declared package D (`facts`: the modules, protocols and
  implementations its own tarball defines, `app` its application) may
  decide a probe of `module` by D's presence alone. D's tarball defines the
  module, not as a `defimpl` (an implementation is defined by design in
  other packages: Jason.Encoder's are `defimpl`s inside them); the module
  is in D's namespace (for an Elixir module, D defines its first segment,
  `Elixir.Postgrex` for `Elixir.Postgrex.Error`; for an Erlang module, it is
  D's application or starts with it and `_`); and no proper prefix of the
  module is a protocol D defines (a name under a protocol is an
  implementation's). A probe of the protocol module itself passes: no
  implementation defines it.
  """
  @spec gate?(
          String.t(),
          %{modules: [String.t()], protocols: [String.t()], impls: [String.t()]},
          String.t()
        ) ::
          boolean()
  def gate?(module, facts, app) do
    module in facts.modules and module not in facts.impls and namespace?(module, facts, app) and
      not Enum.any?(prefixes(module), &(&1 in facts.protocols))
  end

  defp namespace?("Elixir." <> rest, facts, _app) do
    [root | _] = String.split(rest, ".")
    ("Elixir." <> root) in facts.modules
  end

  defp namespace?(module, _facts, app) when is_binary(app),
    do: module == app or String.starts_with?(module, app <> "_")

  defp namespace?(_module, _facts, _app), do: false

  # The proper prefixes of an Elixir module's name, `Elixir.A` and
  # `Elixir.A.B` for `Elixir.A.B.C`.
  defp prefixes("Elixir." <> rest) do
    parts = String.split(rest, ".")
    for n <- 1..(length(parts) - 1)//1, do: "Elixir." <> Enum.join(Enum.take(parts, n), ".")
  end

  defp prefixes(_module), do: []

  @doc """
  Downloads into `home` (the run's `HEX_HOME`) the declared-absent
  dependencies of the locked `releases` (`%{app => %{name, version,
  checksum}}`, each read from its verified tarball) that `home` holds no
  tarball of. Returns `{:ok, %{fetched: ["name-version"], failed: [name]}}`
  or the fetch's error. `relevant: false` (no probe `index/1` decides was
  traced, round 3, R2-5) fetches nothing. `fetch:` replaces the download
  (tests).

  The download (`hex_fetch/2`) runs `mix hex.package fetch` per package
  with a `HEX_HOME` of its own, so nothing it writes reaches the run's cache
  by itself, under a hard deadline the BEAM keeps (`run_bounded/5`, which
  kills the OS process). Only a package the script reports fetched, with
  the tarball it names, is copied into `home` (`collect/4`): Hex verified it
  against the signed registry first. A checksum error, a crash or a kill
  leaves the package unknown, so a probe of its modules refuses.
  """
  @spec fetch(String.t() | nil, map(), list(), keyword()) ::
          {:ok, %{fetched: [String.t()], failed: [String.t()]}} | {:error, term()}
  def fetch(home, releases, env, opts \\ [])

  def fetch(home, releases, env, opts) when is_binary(home) and is_map(releases) do
    locked = MapSet.new(Map.keys(releases))

    names =
      if Keyword.get(opts, :relevant, true),
        do:
          for(
            {app, _release} <- releases,
            req <- requirements(Context.release_tarball(home, releases, app)),
            req.optional,
            not MapSet.member?(locked, req.app),
            not cached?(home, req.name),
            uniq: true,
            do: req.name
          ),
        else: []

    case names |> Enum.sort() |> Enum.take(@max_fetch) do
      [] ->
        {:ok, %{fetched: [], failed: []}}

      names ->
        fun = Keyword.get_lazy(opts, :fetch, &default_fetch/0)
        fun.(names, home: home, env: env)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  def fetch(_home, _releases, _env, _opts), do: {:ok, %{fetched: [], failed: []}}

  defp default_fetch do
    if System.get_env("NCC_DECLARED_FETCH") == "0",
      do: fn _names, _opts -> {:error, :off} end,
      else: &hex_fetch/2
  end

  @doc false
  # The `mix run` script that fetches `names`, one Hex task per name into
  # its own dir under `out`, and reports each: `NCC_FETCH ok <name> <file>`
  # or `NCC_FETCH error <name> <kind>`. Names match `@name`, so no quoting
  # can break out. A name whose fetch failed is fetched once more, a second
  # later, into an emptied dir (coverage drop 2026-11-22, F7): the first
  # `hex.package` task of the VM starts Hex's update check, whose answer
  # can crash `Hex.Registry.Server` after the task closed the registry, and
  # a fetch in flight then exits `:noproc`. The second try reports.
  @spec fetch_script([String.t()], String.t()) :: String.t()
  def fetch_script(names, out) do
    true = Enum.all?(names, &Regex.match?(@name, &1))

    """
    fetch = fn n, dir ->
      try do
        Mix.Task.rerun("hex.package", ["fetch", n, "--output", dir])

        case Path.wildcard(Path.join(dir, n <> "-*.tar")) do
          [file] -> {:ok, Path.basename(file)}
          _ -> {:error, "no_file"}
        end
      catch
        kind, _ -> {:error, to_string(kind)}
      end
    end

    for n <- #{inspect(names)} do
      dir = Path.join(#{inspect(out)}, n)

      result =
        with {:error, _first} <- fetch.(n, dir) do
          Process.sleep(1_000)
          File.rm_rf(dir)
          fetch.(n, dir)
        end

      case result do
        {:ok, file} -> IO.puts("NCC_FETCH ok " <> n <> " " <> file)
        {:error, kind} -> IO.puts("NCC_FETCH error " <> n <> " " <> kind)
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

  # sobelow_skip ["Traversal.FileModule"]
  defp hex_fetch(names, opts) do
    home = Keyword.fetch!(opts, :home)
    scratch = Path.join(Path.dirname(home), "declared-fetch")
    File.rm_rf!(scratch)
    out = Path.join(scratch, "out")
    File.mkdir_p!(out)
    env = Keyword.get(opts, :env, []) ++ [{"HEX_HOME", Path.join(scratch, "hex-home")}]

    case System.find_executable("mix") do
      nil ->
        {:error, :no_mix}

      mix ->
        args = ["run", "--no-mix-exs", "-e", fetch_script(names, out)]

        case run_bounded(mix, args, env, scratch, @fetch_timeout_sec * 1000) do
          {:ok, output} -> {:ok, collect(output, names, out, home)}
          {:error, :timeout, output} -> {:error, {:timeout, collect(output, names, out, home)}}
          {:error, why} -> {:error, why}
        end
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc false
  # The names `output` reports fetched, each with a tarball named
  # `<name>-<version>.tar` in its own dir under `out`, copied into `home`'s
  # Hex cache; every other requested name failed.
  @spec collect(String.t(), [String.t()], String.t(), String.t()) :: %{
          fetched: [String.t()],
          failed: [String.t()]
        }
  # sobelow_skip ["Traversal.FileModule"]
  def collect(output, names, out, home) do
    reported =
      for line <- String.split(output, "\n"),
          [_, n, file] <- [Regex.run(~r/\ANCC_FETCH ok ([a-z][a-z0-9_]*) (\S+)\z/, line)],
          n in names,
          [_, ^n, version] <- [Regex.run(@tarball, file)],
          into: %{},
          do: {n, {file, version}}

    dest = Path.join([home, "packages", "hexpm"])
    File.mkdir_p!(dest)

    fetched =
      for n <- Enum.sort(names),
          {file, version} <- List.wrap(Map.get(reported, n)),
          src = Path.join([out, n, file]),
          File.regular?(src),
          :ok == File.cp(src, Path.join(dest, file)),
          do: "#{n}-#{version}"

    got = MapSet.new(fetched, &(&1 |> String.split("-", parts: 2) |> hd()))
    %{fetched: fetched, failed: names |> Enum.sort() |> Enum.reject(&MapSet.member?(got, &1))}
  end

  @doc false
  # Runs `cmd` with `args` and `env` in `cd`, its output in one binary, for
  # at most `timeout_ms`: past it the OS process is killed
  # (`NccWorker.OsKill`) and `{:error, :timeout, output_so_far}` returned.
  # The deadline is the BEAM's own, not timeout(1)'s.
  @spec run_bounded(
          String.t(),
          [String.t()],
          [{String.t(), String.t()}],
          String.t(),
          pos_integer()
        ) ::
          {:ok, String.t()} | {:error, :timeout, String.t()} | {:error, term()}
  def run_bounded(cmd, args, env, cd, timeout_ms) do
    port =
      Port.open({:spawn_executable, String.to_charlist(cmd)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        :hide,
        args: args,
        cd: String.to_charlist(cd),
        env: Enum.map(env, fn {k, v} -> {String.to_charlist(k), String.to_charlist(v)} end)
      ])

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port(port, deadline, [])
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp collect_port(port, deadline, acc) do
    left = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect_port(port, deadline, [acc | data])

      {^port, {:exit_status, 0}} ->
        {:ok, IO.iodata_to_binary(acc)}

      {^port, {:exit_status, code}} ->
        {:error, {:exit, code, IO.iodata_to_binary(acc)}}
    after
      left ->
        kill_port(port)
        {:error, :timeout, IO.iodata_to_binary(acc)}
    end
  end

  defp kill_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> NccWorker.OsKill.kill([Integer.to_string(pid)])
      _ -> :ok
    end

    Port.close(port)
  catch
    _, _ -> :ok
  after
    receive do
      {^port, _} -> :ok
    after
      0 -> :ok
    end
  end

  @doc "The `hexpm` requirements a Hex tarball's `metadata.config` declares."
  @spec requirements(binary() | nil) :: [
          %{name: String.t(), app: String.t(), optional: boolean()}
        ]
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
      %{name: name, app: app, optional: map["optional"] in [true, {:atom, "true"}]}
    else
      _ -> nil
    end
  end

  defp requirement(_other), do: nil

  defp props(props) when is_list(props), do: props
  defp props(props) when is_map(props), do: Map.to_list(props)
  defp props(_props), do: []

  # The union of what the cached tarballs of package `name` define, newest
  # @max_versions first: their modules, protocols and implementations.
  # sobelow_skip ["Traversal.FileModule"]
  defp facts_of(home, name) when is_binary(home) do
    dir = Path.join([home, "packages", "hexpm"])

    case File.ls(dir) do
      {:ok, files} ->
        files
        |> Enum.flat_map(&release_of(&1, name, dir))
        |> Enum.sort_by(&elem(&1, 0), &newer?/2)
        |> Enum.take(@max_versions)
        |> Enum.map(fn {_version, path} -> tarball_facts(path) end)
        |> Enum.reduce(@no_facts, fn facts, acc ->
          Map.new(acc, fn {key, list} -> {key, Enum.uniq(list ++ Map.fetch!(facts, key))} end)
        end)

      _ ->
        @no_facts
    end
  end

  defp facts_of(_home, _name), do: @no_facts

  # `{version, path}` of a cached tarball of package `name`.
  defp release_of(file, name, dir) do
    case Regex.run(@tarball, file) do
      [_, ^name, version] -> [{version, Path.join(dir, file)}]
      _ -> []
    end
  end

  defp newer?(a, b) do
    case {Version.parse(a), Version.parse(b)} do
      {{:ok, va}, {:ok, vb}} -> Version.compare(va, vb) != :lt
      _ -> a >= b
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp tarball_facts(path) do
    max = Compatibility.StaticPriv.max_tarball_bytes()

    with {:ok, bytes} when is_binary(bytes) <-
           File.open(path, [:read, :raw, :binary], &IO.binread(&1, max + 1)),
         {:ok, read} <- Compatibility.HexModules.read(bytes) do
      Map.take(read, [:modules, :protocols, :impls])
    else
      _ -> @no_facts
    end
  rescue
    _ -> @no_facts
  end
end
