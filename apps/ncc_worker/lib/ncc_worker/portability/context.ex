defmodule NccWorker.Portability.Context do
  @moduledoc """
  What the judge (`NccWorker.Portability`) knows about one traced compile:
  the closure the driver compiled (each dependency's source dir, build dir,
  manager, Hex file list and whether it builds native code), the windows and
  quiet intervals, the roots R2 searches literals for, the modules the
  tracer loaded before anything compiled (`preloaded`), the windows
  package code started a nested compile in (`nested`), and, for the VM
  whose events are being decided, its `code:ensure_loaded/1` probes
  (`ensured`, `NccWorker.Portability.Probes.ensured/1`).

  Every app here is an OTP app name, as the trace's closure line carries
  them. The `package` given to `build/4` may be a Hex name that is not its
  app's: the driver (`mix ncc.trace_compile`) resolved it through the
  dependency's `:hex` option, and `build/4` takes the app from the closure's
  `packages`. A package the closure does not name becomes `nil`, which is no
  dependency, so the judge refuses to judge.

  Paths are real paths: every component is checked for a symlink and
  followed, and `..` applies to the resolved directory, as the OS does it, so
  `/var` and `/private/var`, or `_build/<env>/lib/<d>/priv` and
  `deps/<d>/priv`, compare equal (spec R1, "resolved to its real path"). A
  path that does not exist is resolved as far as it exists: a read of a
  missing file is still a read of that path. A symlink loop resolves to
  `nil`, which is neither readable nor writable. Containment compares whole
  path segments, so `deps/foo-evil` is not under `deps/foo`, and compares
  them byte for byte: a case variant of an allowed path is refused even on
  a case-insensitive file system (the worker's is case-sensitive).

  Reads (spec R1 "Files") are allowed under the OTP root, the Elixir
  install, a non-native closure dependency's build dir, or a closure
  dependency's source dir when the file is in its Hex file list (a listed
  directory covers the files under it) and, for a native dependency, not
  under `priv`. Never the project's own files: they stand for the consumer
  project. Writes are allowed only under the owning window's dependency's
  `ebin`.

  The Hex file list is the `metadata.config` of the dependency's tarball in
  the run's Hex cache, used only when its outer checksum is the lock's
  (`NccWorker.Portability.HexFiles`); without one, no source file of that
  dependency is readable. A relative path resolves only inside a dependency
  window, against its source dir, and not at all in a window where user code
  changed the directory (`set_cwd`): never against this process's own
  directory.
  """

  alias NccWorker.{DepsLock, HexCache}
  alias NccWorker.Portability.{HexFiles, Trees}
  alias NccWorker.Tracer.Report

  defstruct [
    :project_dir,
    :package,
    :otp_root,
    :elixir_root,
    roots: [],
    deps: %{},
    windows: [],
    quiet: [],
    cd: MapSet.new(),
    hex: {nil, %{}},
    preloaded: %{},
    nested: %{},
    ensured: %{},
    trees: %{},
    hook_scripts: %{}
  ]

  @type dep :: %{
          dest: String.t() | nil,
          build: String.t() | nil,
          manager: String.t() | nil,
          children: [String.t()],
          native?: boolean(),
          hex_files: [[String.t()]] | nil
        }

  @type t :: %__MODULE__{
          project_dir: String.t() | nil,
          package: String.t() | nil,
          otp_root: String.t() | nil,
          elixir_root: String.t() | nil,
          roots: [String.t()],
          deps: %{String.t() => dep()},
          windows: [map()],
          quiet: [map()],
          cd: MapSet.t(),
          hex: {String.t() | nil, map()},
          preloaded: %{String.t() => String.t()},
          nested: %{(String.t() | atom()) => String.t()},
          ensured: %{{term(), String.t(), String.t()} => integer()},
          trees: %{String.t() => Trees.tree()},
          hook_scripts: %{String.t() => String.t()}
        }

  @max_hops 40
  @link_cache {__MODULE__, :link_cache}

  @doc """
  The context of one traced compile of `project_dir`. Options:

    * `:hex_home`, the `HEX_HOME` whose `packages/hexpm/` holds the run's
      tarballs (default: this process's `HEX_HOME`);
    * `:releases`, `{:ok, %{app => %{name, version, checksum}}}` or a bare
      map, the locked Hex releases that verify them (default: the project's
      `mix.lock`, `NccWorker.DepsLock.hex_releases/1`);
    * `:trees`, the `NccWorker.Portability.Trees.snapshot/5` taken before
      the compile (item 5e); without it no tree is checked;
    * `:hook_scripts`, `%{app => sha256}` of each reviewed rebar3 hook
      script on disk before the compile (`NccWorker.Portability.Rebar.reviewed_hooks/0`),
      taken only when the build env left its variable unset; without it no
      reviewed hook is let through.

  A dependency whose tarball is missing or does not match its lock entry has
  no file list, so none of its source files is readable.
  """
  @spec build(String.t(), String.t(), Report.t(), [String.t()], keyword()) :: t()
  def build(project_dir, package, %Report{} = report, native, opts \\ []) do
    start = report.start || %{}
    closure = report.closure || %{}
    listed = for %{"app" => app} = dep when is_binary(app) <- list(closure["deps"]), do: dep
    hex = hex_source(project_dir, opts)

    ctx = %__MODULE__{
      project_dir: realpath(project_dir),
      package: package_app(package, closure["packages"]),
      deps: Map.new(listed, &{&1["app"], dep_info(&1, native, hex)}),
      windows: report.windows,
      quiet: report.quiet,
      otp_root: install_root(start["otp_root"]),
      elixir_root: install_root(start["elixir_root"]),
      roots: roots(project_dir, start),
      hex: hex,
      preloaded: preloaded(start["preloaded"]),
      trees: trees(Keyword.get(opts, :trees)),
      hook_scripts: trees(Keyword.get(opts, :hook_scripts))
    }

    %{ctx | cd: changed_dir(ctx, report), nested: nested(ctx, report)}
  end

  defp trees(trees) when is_map(trees), do: trees
  defp trees(_trees), do: %{}

  # The windows a nested compile or diagnostics capture was started in
  # (channel `nested_compile`), each with the first such call: by owner for
  # the Mix VM's events (`:outside` too), by app for a child VM's.
  defp nested(ctx, report) do
    main =
      for %{"channel" => "nested_compile"} = e <- report.events, do: {owner(ctx, e), e["mfa"]}

    children =
      for {app, %{events: events}} <- report.children,
          %{"channel" => "nested_compile"} = e <- events,
          do: {app, e["mfa"]}

    Enum.reduce(Enum.reverse(main ++ children), %{}, fn {owner, mfa}, acc ->
      Map.put(acc, owner, mfa)
    end)
  end

  defp hex_source(project_dir, opts) do
    home = Keyword.get_lazy(opts, :hex_home, fn -> System.get_env("HEX_HOME") end)

    releases =
      case Keyword.get_lazy(opts, :releases, fn -> DepsLock.hex_releases(project_dir) end) do
        {:ok, map} when is_map(map) -> map
        map when is_map(map) -> map
        _ -> %{}
      end

    {home, releases}
  end

  # The apps a user-extent `set_cwd` ran for: by its owner and by the window
  # its timestamp falls in (a cd from the wrapper's `mix.exs` still moves
  # that window), and by app for a child VM's events.
  defp changed_dir(ctx, report) do
    main =
      for %{"channel" => "cwd"} = event <- report.events,
          app <- [owner(ctx, event), by_time(ctx, event["ts"])],
          is_binary(app),
          do: app

    children =
      for {app, %{events: events}} <- report.children,
          Enum.any?(events, &match?(%{"channel" => "cwd"}, &1)),
          do: app

    MapSet.new(main ++ children)
  end

  # The modules the Mix VM's tracer loaded before anything compiled, with
  # their applications (`NccWorker.Portability.Probes`).
  defp preloaded(map) when is_map(map),
    do: for({m, a} <- map, is_binary(m) and is_binary(a), into: %{}, do: {m, a})

  defp preloaded(_other), do: %{}

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  # The package's OTP app: itself when the closure names it, else the one
  # app the driver resolved its Hex name to.
  defp package_app(package, packages) when is_list(packages) do
    cond do
      package in packages -> package
      match?([app] when is_binary(app), packages) -> hd(packages)
      true -> nil
    end
  end

  defp package_app(_package, _packages), do: nil

  @spec roots(t()) :: [String.t()]
  def roots(%__MODULE__{roots: roots}), do: roots

  @spec dep?(t(), term()) :: boolean()
  def dep?(%__MODULE__{deps: deps}, app), do: is_binary(app) and Map.has_key?(deps, app)

  @doc "A closure dependency's source dir (`deps/<d>`), real path."
  @spec dest(t(), term()) :: String.t() | nil
  def dest(ctx, app), do: if(dep?(ctx, app), do: ctx.deps[app].dest)

  @doc "A closure dependency's `_build/<env>/lib/<d>/ebin`, real path."
  @spec ebin(t(), term()) :: String.t() | nil
  def ebin(ctx, app) do
    case dep?(ctx, app) && ctx.deps[app].build do
      build when is_binary(build) -> realpath(Path.join(build, "ebin"))
      _ -> nil
    end
  end

  @spec manager(t(), term()) :: String.t() | nil
  def manager(ctx, app), do: if(dep?(ctx, app), do: ctx.deps[app].manager)

  @doc "`app` and every closure dependency it reaches, sorted; `[]` for no dependency."
  @spec closure_of(t(), term()) :: [String.t()]
  def closure_of(ctx, app), do: [app] |> reach(ctx, MapSet.new()) |> Enum.sort()

  defp reach([], _ctx, seen), do: seen

  defp reach([app | rest], ctx, seen) do
    cond do
      MapSet.member?(seen, app) -> reach(rest, ctx, seen)
      dep?(ctx, app) -> reach(ctx.deps[app].children ++ rest, ctx, MapSet.put(seen, app))
      true -> reach(rest, ctx, seen)
    end
  end

  @doc """
  The working directory a relative path in `owner`'s window resolves
  against: Mix compiles a dependency inside its source dir. `nil`, so no
  relative path resolves, outside every dependency window and in a window
  where user code changed the directory (`set_cwd`, the `cwd` channel).
  """
  @spec cwd(t(), term()) :: String.t() | nil
  def cwd(ctx, owner) do
    if dep?(ctx, owner) and not MapSet.member?(ctx.cd, owner), do: dest(ctx, owner)
  end

  @doc "The real path a read or write of `path` in `owner`'s window touches."
  @spec resolve(t(), term(), term()) :: String.t() | nil
  def resolve(ctx, path, owner), do: realpath(path, cwd(ctx, owner))

  @spec readable?(t(), String.t() | nil) :: boolean()
  def readable?(_ctx, nil), do: false

  def readable?(ctx, real) when is_binary(real) do
    under?(real, ctx.otp_root) or under?(real, ctx.elixir_root) or
      Enum.any?(Map.values(ctx.deps), &dep_readable?(&1, real))
  end

  def readable?(_ctx, _real), do: false

  defp dep_readable?(%{native?: true} = dep, real) do
    under?(real, dep.dest) and not under_priv?(real, dep.dest) and hex_listed?(dep, real)
  end

  defp dep_readable?(dep, real),
    do: under?(real, dep.build) or (under?(real, dep.dest) and hex_listed?(dep, real))

  @doc """
  Whether `real` lies under a closure dependency's `priv` (its source dir's,
  or its build dir's, which Mix links there or copies), compared
  case-insensitively, and does not exist on the builder. Such a path is
  where runtime or Mix-task data appears on a user's machine (ex_cldr's
  `priv/cldr/locales`), so a compile-time read of it is a host read in
  every window, whatever the Hex file list says: its absence here says
  nothing about the user's.
  """
  @spec missing_under_priv?(t(), String.t() | nil) :: boolean()
  def missing_under_priv?(ctx, real) when is_binary(real) do
    Enum.any?(Map.values(ctx.deps), fn dep ->
      under_priv?(real, dep.dest) or under_priv?(real, dep.build)
    end) and not exists?(real)
  end

  def missing_under_priv?(_ctx, _real), do: false

  # Without following a final link: a dangling link is there too.
  # sobelow_skip ["Traversal.FileModule"]
  defp exists?(real), do: match?({:ok, _}, File.lstat(real))

  # Case-insensitively, so no file system folds `Priv` into `priv` past it.
  defp under_priv?(real, dest) when is_binary(dest),
    do: under?(String.downcase(real), String.downcase(Path.join(dest, "priv")))

  defp under_priv?(_real, _dest), do: false

  # The source dir itself, a listed file or anything under a listed
  # directory, or a directory on the way to a listed entry.
  defp hex_listed?(%{dest: dest, hex_files: files}, real) do
    rel = Enum.drop(Path.split(real), length(Path.split(dest)))

    cond do
      rel == [] -> true
      is_nil(files) -> false
      true -> Enum.any?(files, &(List.starts_with?(rel, &1) or List.starts_with?(&1, rel)))
    end
  end

  @doc """
  Whether `real`, read while `app`'s own `mix.exs` was evaluated, is a path
  under `app`'s source dir that its verified tarball does not hold: `app`
  builds no native code, its tree matched the tarball before the compile
  (`Trees.snapshot/5`), and no member is the path or lies under it, case
  folded, outside `priv` and the root names the snapshot leaves out
  (`Trees.absent?/2`).

  The snapshot proved such a path absent before the compile, and the user's
  `deps/<d>` is unpacked from the same tarball, so reading it gives the same
  answer on both sides: nothing there. `tree_check/3` then decides the read
  as it does a listed one, so a path that is there at judge time cannot be
  judged. A path the tarball holds is left to the Hex file list. Only
  `mix.exs` evaluation: a read from compiled code keeps the Hex file list
  rule.
  """
  @spec absent_from_tree?(t(), term(), String.t() | nil) :: boolean()
  def absent_from_tree?(ctx, app, real) when is_binary(real) do
    with %{native?: false, dest: dest} when is_binary(dest) <- Map.get(ctx.deps, app),
         true <- under?(real, dest),
         {:ok, members} <- Map.get(ctx.trees, app) do
      rel = Path.split(real) |> Enum.drop(length(Path.split(dest)))
      rel != [] and Trees.absent?(Path.join(rel), members)
    else
      _ -> false
    end
  end

  def absent_from_tree?(_ctx, _app, _real), do: false

  @doc """
  Item 5e: the re-check of a read of `real` under the source dir of a
  closure dependency whose tree matched its tarball before the compile
  (`Trees.check_read/4`), `listing?` for a directory listing. `:ok` for any
  other path or dependency. Remembered per call of `with_link_cache/1`.
  """
  @spec tree_check(t(), String.t() | nil, boolean()) :: :ok | {:differs, String.t(), String.t()}
  def tree_check(_ctx, nil, _listing?), do: :ok

  def tree_check(ctx, real, listing?) when is_binary(real) do
    Enum.find_value(ctx.deps, :ok, fn {app, dep} ->
      with dest when is_binary(dest) <- dep.dest,
           true <- under?(real, dest),
           {:ok, members} <- Map.get(ctx.trees, app) do
        dep_tree_check(app, dest, real, members, listing?)
      else
        _ -> nil
      end
    end)
  end

  # nil when the read matches `app`'s tree, else `{:differs, app, detail}`.
  defp dep_tree_check(app, dest, real, members, listing?) do
    rel = Path.split(real) |> Enum.drop(length(Path.split(dest))) |> rel_path()

    case cached({:tree_check, app, rel, listing?}, fn ->
           Trees.check_read(dest, rel, members, listing?)
         end) do
      :ok -> nil
      {:differs, detail} -> {:differs, app, detail}
    end
  end

  defp rel_path([]), do: ""
  defp rel_path(parts), do: Path.join(parts)

  defp cached(key, fun) do
    case Process.get(@link_cache) do
      %{^key => value} ->
        value

      %{} = cache ->
        value = fun.()
        Process.put(@link_cache, Map.put(cache, key, value))
        value

      nil ->
        fun.()
    end
  end

  @spec writable?(t(), term(), term()) :: boolean()
  def writable?(ctx, path, owner) do
    is_binary(path) and dep?(ctx, owner) and under?(resolve(ctx, path, owner), ebin(ctx, owner))
  end

  @doc "An absolute path to a regular file in some closure dependency's source dir."
  @spec closure_file?(t(), term()) :: boolean()
  def closure_file?(ctx, string) when is_binary(string) do
    with :absolute <- Path.type(string),
         real when is_binary(real) <- realpath(string),
         true <- regular?(real) do
      Enum.any?(Map.values(ctx.deps), &under?(real, &1.dest))
    else
      _ -> false
    end
  end

  def closure_file?(_ctx, _string), do: false

  @doc "An absolute path to a directory in some closure dependency's source dir (not the dir itself)."
  @spec closure_dir?(t(), term()) :: boolean()
  def closure_dir?(ctx, string) when is_binary(string) do
    with :absolute <- Path.type(string),
         real when is_binary(real) <- realpath(string),
         true <- dir?(real) do
      Enum.any?(Map.values(ctx.deps), &(under?(real, &1.dest) and real != &1.dest))
    else
      _ -> false
    end
  end

  def closure_dir?(_ctx, _string), do: false

  # A path a beam literal named, checked, never opened.
  # sobelow_skip ["Traversal.FileModule"]
  defp dir?(real), do: File.dir?(real)

  # A path the trace or a beam literal named, checked, never opened.
  # sobelow_skip ["Traversal.FileModule"]
  defp regular?(real), do: File.regular?(real)

  @doc """
  Whom an event counts against: the dependency whose `mix.exs` its first user
  frame is in (spec R4), the wrapper project for our own `mix.exs`, else the
  window or quiet interval its timestamp falls in, else `:outside`.
  """
  @spec owner(t(), map()) :: String.t() | :outside | :quiet | :wrapper
  def owner(ctx, event) do
    case mix_exs_owner(ctx, event) do
      nil -> by_time(ctx, event["ts"])
      owner -> owner
    end
  end

  @doc """
  The real path of the closure dependency's `mix.exs` the event's first user
  frame is in, else `nil`. A relative frame file counts only as `owner`'s
  own `mix.exs`.
  """
  @spec mix_exs(t(), map(), term()) :: String.t() | nil
  def mix_exs(ctx, %{"user" => %{"file" => file}}, owner) when is_binary(file) do
    cond do
      Path.basename(file) != "mix.exs" -> nil
      Path.type(file) == :absolute -> dep_mix_exs(ctx, realpath(file))
      dep?(ctx, owner) -> own_mix_exs(ctx, owner, resolve(ctx, file, owner))
      true -> nil
    end
  end

  def mix_exs(_ctx, _event, _owner), do: nil

  defp dep_mix_exs(ctx, real) do
    if mix_exs_app(ctx, real) in [nil, :wrapper], do: nil, else: real
  end

  defp own_mix_exs(ctx, owner, real) do
    if mix_exs_app(ctx, real) == owner, do: real
  end

  defp mix_exs_owner(ctx, %{"user" => %{"file" => file}}) when is_binary(file) do
    if Path.basename(file) == "mix.exs" and Path.type(file) == :absolute,
      do: mix_exs_app(ctx, realpath(file))
  end

  defp mix_exs_owner(_ctx, _event), do: nil

  defp mix_exs_app(_ctx, nil), do: nil

  defp mix_exs_app(ctx, real) do
    if ctx.project_dir && real == Path.join(ctx.project_dir, "mix.exs"),
      do: :wrapper,
      else: Enum.find_value(ctx.deps, &dep_mix_exs_app(&1, real))
  end

  defp dep_mix_exs_app({app, %{dest: dest}}, real) when is_binary(dest),
    do: if(real == Path.join(dest, "mix.exs"), do: app)

  defp dep_mix_exs_app(_dep, _real), do: nil

  defp by_time(_ctx, ts) when not is_integer(ts), do: :outside

  defp by_time(ctx, ts) do
    cond do
      Enum.any?(ctx.quiet, &within?(&1, ts)) -> :quiet
      window = Enum.find(ctx.windows, &within?(&1, ts)) -> window.app
      true -> :outside
    end
  end

  defp within?(%{open: open, close: close}, ts) when is_integer(open),
    do: ts >= open and (is_nil(close) or ts <= close)

  defp within?(_interval, _ts), do: false

  @doc """
  Whether `path` is `root` or below it, by whole path segments. Both must be
  absolute and free of `.` and `..` (pass real paths); the file system root
  is never a root here, so a broken install root allows nothing.
  """
  @spec under?(term(), term()) :: boolean()
  def under?(path, root) when is_binary(path) and is_binary(root) do
    case Process.get(@link_cache) do
      %{{:under, ^path, ^root} => under} ->
        under

      %{} = cache ->
        under = split_under?(path, root)
        Process.put(@link_cache, Map.put(cache, {:under, path, root}, under))
        under

      nil ->
        split_under?(path, root)
    end
  end

  def under?(_path, _root), do: false

  defp split_under?(path, root) do
    path_parts = Path.split(path)
    root_parts = Path.split(root)

    clean?(path_parts) and clean?(root_parts) and length(root_parts) > 1 and
      List.starts_with?(path_parts, root_parts)
  end

  defp clean?(["/" | rest]), do: not Enum.any?(rest, &(&1 in [".", ".."]))
  defp clean?(_parts), do: false

  @doc """
  The real path of an absolute `path`: symlinks followed component by
  component, `.` and `..` applied to the resolved directory. `nil` for a
  relative path (never this process's own directory), `nil`, `""` or a
  symlink loop.
  """
  @spec realpath(term()) :: String.t() | nil
  def realpath(path), do: realpath(path, nil)

  defp realpath(path, cwd) when is_binary(path) and path != "" do
    case {Path.type(path), cwd} do
      {:absolute, _cwd} -> walk(Path.split(path), [], 0)
      {_relative, cwd} when is_binary(cwd) -> relative(path, cwd)
      {_relative, nil} -> nil
    end
  end

  defp realpath(_path, _cwd), do: nil

  defp relative(path, cwd) do
    if Path.type(cwd) == :absolute,
      do: walk(Path.split(cwd) ++ Path.split(path), [], 0),
      else: nil
  end

  # `done` holds the resolved prefixes so far, the longest first, down to
  # "/": each one the path `Path.join/1` of its components gives.
  defp walk([], [path | _], _hops), do: path
  defp walk(["/" | rest], _done, hops), do: walk(rest, ["/"], hops)
  defp walk(["." | rest], done, hops), do: walk(rest, done, hops)
  defp walk([".." | rest], ["/"], hops), do: walk(rest, ["/"], hops)
  defp walk([".." | rest], [_last | done], hops), do: walk(rest, done, hops)

  defp walk([part | rest], done, hops) do
    path = join_part(done, part)

    case read_link(path) do
      {:ok, _target} when hops >= @max_hops -> nil
      {:ok, target} -> walk(Path.split(target) ++ rest, done, hops + 1)
      {:error, _reason} -> walk(rest, [path | done], hops)
    end
  end

  defp join_part(["/" | _], part), do: "/" <> part
  defp join_part([prefix | _], part), do: prefix <> "/" <> part

  @doc """
  Runs `fun` with every symlink read this module makes remembered per path
  for the length of the call, and every `under?/2` answer (a pure function
  of its two paths) per pair. The judge resolves the same directories for
  thousands of events, after the compile, when nothing writes the tree any
  more. Outside such a call every read goes to the file system.
  """
  @spec with_link_cache((-> result)) :: result when result: term()
  def with_link_cache(fun) do
    previous = Process.put(@link_cache, %{})

    try do
      fun.()
    after
      if previous, do: Process.put(@link_cache, previous), else: Process.delete(@link_cache)
    end
  end

  defp read_link(path) do
    case Process.get(@link_cache) do
      %{^path => result} ->
        result

      %{} = cache ->
        result = file_read_link(path)
        Process.put(@link_cache, Map.put(cache, path, result))
        result

      nil ->
        file_read_link(path)
    end
  end

  # Reads links only, of paths the traced compile itself reported.
  # sobelow_skip ["Traversal.FileModule"]
  defp file_read_link(path), do: File.read_link(path)

  defp install_root(path) do
    case realpath(path) do
      real when is_binary(real) -> if Path.type(path) == :absolute and real != "/", do: real
      nil -> nil
    end
  end

  defp dep_info(dep, native, hex) do
    dest = install_root(dep["dest"])

    %{
      dest: dest,
      build: install_root(dep["build"]),
      manager: dep["manager"],
      children: Enum.filter(list(dep["children"]), &is_binary/1),
      native?: dep["app"] in native,
      hex_files: hex_files(dep["app"], hex)
    }
  end

  # The file list of the dependency's Hex tarball, the one whose outer
  # checksum is the lock's: never `deps/<d>/hex_metadata.config`, which an
  # untraced build step can rewrite.
  defp hex_files(app, hex), do: app |> verified_tarball(hex) |> HexFiles.from_tarball()

  @doc """
  The bytes of `app`'s Hex tarball in the run's Hex cache, only when its
  outer checksum is the lock snapshot's; else `nil`.
  """
  @spec tarball(t(), term()) :: binary() | nil
  def tarball(%__MODULE__{hex: hex}, app), do: verified_tarball(app, hex)

  @doc """
  `tarball/2` before there is a context: `app`'s tarball in the Hex cache
  `home`, only when its outer checksum is the one `releases` (a
  `NccWorker.Portability.lock_snapshot/1`) gives; else `nil`.
  """
  @spec release_tarball(String.t() | nil, map(), String.t()) :: binary() | nil
  def release_tarball(home, releases, app), do: verified_tarball(app, {home, releases})

  defp verified_tarball(app, {home, releases}) when is_binary(home) and home != "" do
    case Map.get(releases, app) do
      %{name: name, version: version, checksum: sum}
      when is_binary(name) and is_binary(version) and is_binary(sum) ->
        HexCache.package_tarball(home, name, version, sum)

      _ ->
        nil
    end
  end

  defp verified_tarball(_app, _hex), do: nil

  @doc "The closure's rebar3-built dependencies that list `app` as a child, sorted."
  @spec rebar3_parents(t(), term()) :: [String.t()]
  def rebar3_parents(%__MODULE__{deps: deps}, app) do
    for {parent, %{manager: "rebar3", children: children}} <- deps,
        app in children,
        do: parent
  end

  defp roots(project_dir, start) do
    [project_dir | Enum.map(~w(otp_root elixir_root home mix_home hex_home), &start[&1])]
    |> Enum.filter(&is_binary/1)
    |> Enum.flat_map(&[Path.expand(&1), realpath(&1)])
    |> Enum.reject(&(is_nil(&1) or byte_size(&1) < 4))
    |> Enum.uniq()
  end
end
