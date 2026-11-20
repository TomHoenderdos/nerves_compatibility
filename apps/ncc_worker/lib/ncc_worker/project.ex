defmodule NccWorker.Project do
  @moduledoc """
  Creates and configures Nerves projects for testing packages.

  Handles:
  - Creating a new Nerves project non-interactively
  - Adding package dependencies
  - Applying system version overrides
  - Adding the package's optional dependencies for the published build

  ## Optional dependencies that are never added

  `add_optional_deps/5` adds a package's unresolved optional dependencies so
  its published files match an application that has them in its lock.
  `optional_deps_to_add/1` sets aside the ones most applications do not lock
  (dev tooling, and alternatives an application picks one of):
  `Compatibility.OptionalDeps.never_added/0`, which the portal reads too.
  """

  alias NccWorker.DepsLock

  @optional_deps_never_added Compatibility.OptionalDeps.never_added()

  @doc """
  Creates a new Nerves project in the specified work directory.

  ## Parameters
    - work_dir: Base working directory
    - systems_override: Optional map of system package names to version requirements
    - targets: Nerves target names to generate system deps for, from
      `NccWorker.Systems.targets/1`

  ## Returns
    - {:ok, project_dir} - Path to the created project
    - {:error, reason} - Creation failed
  """
  # `mix nerves.new --prerelease` (nerves_bootstrap >= 1.17.3) generates a Nerves
  # 2 project, but with a floating `~> 2.0.0-pre.N` requirement, which would let
  # Hex move the Nerves version under an unchanged worker image -- and the
  # portal deduplicates runs on that image. Pinned exactly so a new Nerves
  # prerelease only arrives with a new image. Revisit once Nerves 2 is final.
  @nerves_version "2.0.0-pre.3"

  @spec create(String.t(), map() | nil, [String.t()]) :: {:ok, String.t()} | {:error, term()}
  def create(work_dir, systems_override, targets) do
    project_dir = Path.join(work_dir, "proj")

    with :ok <- create_nerves_project(project_dir, targets),
         :ok <- pin_nerves_version(project_dir),
         :ok <- cap_squashfs_threads(project_dir),
         :ok <- maybe_apply_systems_override(project_dir, systems_override) do
      {:ok, project_dir}
    end
  end

  @doc """
  Creates a plain, non-Nerves project in `<work_dir>/proj` with
  `mix new . --app <app_name>`, for a toolchain run.

  A toolchain image carries neither nerves_bootstrap nor an OTP that Nerves 2
  accepts, and a toolchain build compiles the package on the host only, so
  nothing in the project may depend on Nerves. The generated `mix.exs` has
  the same `defp deps do [` block `add_package/4` injects into.
  """
  @spec create_plain(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:mix_new_failed, String.t()}}
  # project_dir is the runner-configured work mount plus the fixed proj directory.
  # sobelow_skip ["Traversal.FileModule"]
  def create_plain(work_dir, app_name) do
    project_dir = Path.join(work_dir, "proj")
    File.mkdir_p!(project_dir)

    case System.cmd("mix", ["new", ".", "--app", app_name],
           cd: project_dir,
           stderr_to_stdout: true
         ) do
      {_, 0} -> {:ok, project_dir}
      {output, _} -> {:error, {:mix_new_failed, output}}
    end
  end

  # Nerves' own defaults for `:squashfs`. Setting `rootfs_type` replaces them
  # rather than adding to them, and they are what makes the image reproducible.
  @squashfs_defaults ["-mkfs-time", "0", "-all-time", "0", "-no-xattrs", "-quiet"]

  @doc """
  `config_content` with sqfstar limited to `processors` threads, or unchanged
  for `nil`.

  sqfstar starts one thread per visible core, and a container's `--cpus` quota
  hides none of them. In a 2-CPU container with 14 visible cores the rpi4
  rootfs took 7.0 s and 13.8 CPU-seconds; with `-processors 2`, 3.9 s and 7.9,
  for a byte-identical image. On a busy build host the surplus threads are also
  the scheduler churn behind a third of its time going to the kernel.
  """
  @spec cap_squashfs(String.t(), pos_integer() | nil) :: String.t()
  def cap_squashfs(config_content, nil), do: config_content

  def cap_squashfs(config_content, processors) when is_integer(processors) and processors > 0 do
    flags = @squashfs_defaults ++ ["-processors", Integer.to_string(processors)]

    config_content <>
      """

      # Added by ncc_worker: limit sqfstar to the build's CPU quota.
      config :nerves, :firmware, rootfs_type: {:squashfs, #{inspect(flags)}}
      """
  end

  # `NCC_SQUASHFS_PROCESSORS` comes from `Portal.Builder`, derived from the same
  # CPU quota it hands the BEAM. Unset (no quota) leaves sqfstar as it was.
  # Edits only the generated worker project's config.
  # sobelow_skip ["Traversal.FileModule"]
  defp cap_squashfs_threads(project_dir) do
    case squashfs_processors() do
      nil ->
        :ok

      processors ->
        path = Path.join([project_dir, "config", "config.exs"])

        with {:ok, content} <- File.read(path) do
          File.write(path, cap_squashfs(content, processors))
        end
    end
  end

  defp squashfs_processors do
    with value when is_binary(value) <- System.get_env("NCC_SQUASHFS_PROCESSORS"),
         {n, ""} when n > 0 <- Integer.parse(value) do
      n
    else
      _ -> nil
    end
  end

  @doc """
  Adds the target package to the project by editing mix.exs and running
  `mix deps.get`.

  `env` is not optional on purpose. Under Nerves 2 (the pinned template)
  `deps.get` compiles nothing: nerves_bootstrap's aliases only hook
  `deps.loadpaths` and `compile`, so the closure's first compile is the host
  stage's, and the worker takes its item-5e tree snapshot right after this
  (`NccWorker.Portability.first_tree_snapshot/3`, `nil` if anything was
  compiled already). Under Nerves 1 nerves_bootstrap compiled the whole tree
  inside `deps.get`; with no env that compile ran in `MIX_ENV=dev` into
  `_build/dev`, which nothing downstream reads (measured on `ash`: 393 seconds
  and 2106 beam files thrown away per run). The host build's env keeps any
  such compile where the host stage picks it up.

  Note: we deliberately avoid `mix igniter.install`. That command temporarily
  injects igniter into mix.exs with `only: [:dev, :test]`, which fails with
  "Dependencies have diverged" whenever the target package depends on igniter
  as a regular (non-:only) dep — a very common pattern in modern Phoenix/Ash
  packages. Of 22 worker crashes in an overnight run, every single one was
  this conflict. For compat testing we only need the package to be in mix.exs
  and fetchable; igniter's install-time code generators aren't required to
  answer "does this package compile on Nerves?".

  ## Parameters
    - project_dir: Path to the project directory
    - package: Package information with name and optional version/requirement
    - env: the environment `mix deps.get` runs in
    - deps_get: runs `mix deps.get`; tests pass their own so they stay offline

  ## Returns
    - {:ok, :added} - Package was added successfully
    - {:error, reason} - Failed to add package
  """
  @spec add_package(
          String.t(),
          map(),
          keyword() | list(),
          (String.t(), list() -> :ok | {:error, term()})
        ) :: {:ok, :added} | {:error, term()}
  # Edits only the generated worker project mix.exs; the worker deliberately builds package code.
  # sobelow_skip ["Traversal.FileModule"]
  def add_package(project_dir, package, env, deps_get \\ &run_deps_get/2) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, new_content} <- inject_dep(content, package),
         :ok <- File.write(mix_exs_path, new_content),
         :ok <- deps_get.(project_dir, env) do
      {:ok, :added}
    end
  end

  @doc """
  The OTP application of the Hex package Mix fetched into `deps/<name>`,
  when it is not `name`: the `app` of its `hex_metadata.config`, which Hex
  writes from the release's checksum-verified tarball at `deps.get`, read
  right after it, before anything compiles. hpack_erl's is `hpack`, and a
  project has to declare it as `{:hpack, ..., hex: :hpack_erl}`: under its
  Hex name, Mix builds `hpack.app` and then stops at "could not find an app
  file at .../hpack_erl.app". `nil` when the application is `name`, when the
  file cannot be read or names none, and when the name it gives is not one
  Mix writes into `mix.exs` as an atom (lowercase letters, digits and `_`,
  a letter first).
  """
  @spec hex_app(String.t(), String.t()) :: String.t() | nil
  # Reads one file Hex wrote into the generated project's own deps/.
  # sobelow_skip ["Traversal.FileModule"]
  def hex_app(project_dir, name) do
    with true <- app_name?(name),
         {:ok, text} <- File.read(Path.join([project_dir, "deps", name, "hex_metadata.config"])),
         {:ok, terms} <- NccWorker.Portability.HexFiles.parse(text),
         {"app", app} when is_binary(app) and app != name <- List.keyfind(terms, "app", 0),
         true <- app_name?(app) do
      app
    else
      _ -> nil
    end
  end

  defp app_name?(name), do: Regex.match?(~r/\A[a-z][a-z0-9_]{0,254}\z/, name)

  @doc """
  Declares the package `add_package/4` added as the application `app`
  (`hex_app/2`): its `{:name, ...}` entry is replaced by `{:app, "==
  version", hex: :name}`, its lock entry and `deps/<name>` are removed, so
  nothing of it stays under the old name, and `mix deps.get` runs again.
  """
  @spec declare_as_app(
          String.t(),
          map(),
          String.t(),
          keyword() | list(),
          (String.t(), list() -> :ok | {:error, term()})
        ) :: {:ok, :added} | {:error, term()}
  # Edits only the generated worker project's mix.exs, mix.lock and deps/.
  # sobelow_skip ["Traversal.FileModule"]
  def declare_as_app(project_dir, %{name: name} = package, app, env, deps_get \\ &run_deps_get/2) do
    mix_exs_path = Path.join(project_dir, "mix.exs")
    dep = %{name: app, requirement: "== " <> package.version, hex: name}

    with true <- app_name?(app) or {:error, {:invalid_app, app}},
         :ok <- remove_deps(project_dir, [name]) |> removed(name),
         {:ok, _} <- File.rm_rf(Path.join([project_dir, "deps", name])),
         {:ok, content} <- File.read(mix_exs_path),
         {:ok, content} <- prepend_dep(content, dep),
         :ok <- File.write(mix_exs_path, content),
         :ok <- deps_get.(project_dir, env) do
      {:ok, :added}
    end
  end

  defp removed(:ok, _name), do: :ok
  defp removed(:error, name), do: {:error, {:dep_not_declared, name}}
  defp removed({:error, _reason} = error, _name), do: error

  @doc """
  `add_package/4` for a pinned build (`NccWorker.Pins`): the package at
  `== version` and every pin of `deps` (`inject_pins/2`) are written into
  `mix.exs` before the one `deps.get`, so Mix resolves the set it was given
  or nothing. `deps` are `Compatibility.Pins` deps.
  """
  @spec add_pinned_package(
          String.t(),
          map(),
          [map()],
          keyword() | list(),
          (String.t(), list() -> :ok | {:error, term()})
        ) :: {:ok, :added} | {:error, term()}
  # Edits only the generated worker project mix.exs; the worker deliberately builds package code.
  # sobelow_skip ["Traversal.FileModule"]
  def add_pinned_package(project_dir, package, deps, env, deps_get \\ &run_deps_get/2) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, content} <- inject_dep(content, package),
         {:ok, content} <- inject_pins(content, deps),
         :ok <- File.write(mix_exs_path, content) do
      deps_get.(project_dir, env)
      |> case do
        :ok -> {:ok, :added}
        error -> error
      end
    end
  end

  @doc """
  Writes each pin (`%{"name", "hex", "version"}`) into `content` as an exact
  requirement: a dependency the template declares is repinned in place,
  keeping its options; every other one is prepended as `{:app, "== v"}`,
  with `hex: :pkg` when the names differ. Never `override: true`: a set that
  does not resolve is refused, never forced.
  """
  @spec inject_pins(String.t(), [map()]) :: {:ok, String.t()} | {:error, term()}
  def inject_pins(content, deps) do
    Enum.reduce_while(deps, {:ok, content}, fn pin, {:ok, acc} ->
      dep = %{name: pin["name"], requirement: "== " <> pin["version"], hex: pin["hex"]}

      case inject_dep(acc, dep) do
        {:ok, injected} -> {:cont, {:ok, injected}}
        error -> {:halt, error}
      end
    end)
  end

  @doc """
  The applications the project's `mix.exs` declares, one per `{:app, ...}`
  line, in file order: for a generated Nerves project before anything is
  injected, the template's own top-level dependencies. `[]` when `mix.exs`
  cannot be read.
  """
  @spec declared_deps(String.t()) :: [String.t()]
  # Reads only the generated worker project's mix.exs.
  # sobelow_skip ["Traversal.FileModule"]
  def declared_deps(project_dir) do
    case File.read(Path.join(project_dir, "mix.exs")) do
      {:ok, content} ->
        ~r/^\s*\{:([a-z][a-z0-9_]*),/m
        |> Regex.scan(content, capture: :all_but_first)
        |> List.flatten()

      {:error, _reason} ->
        []
    end
  end

  @doc """
  Takes `apps` out of the project: each one's `{:app, ...}` line out of
  `mix.exs`, its entry out of `mix.lock`, which Mix writes one entry per
  line, and what the template's config says of it (`unconfigure/2`). A
  pinned firmware build's template round (`NccWorker.Pins`): Mix merges
  every `deps.get`'s lock over the old one, so an entry left in the lock
  would stay resolved, and the optional edge into it with it; and Nerves 2
  refuses to assemble a release whose `application_sort` names an
  application it lacks. `:error` when an app has no line in `mix.exs` to
  take out; nothing is written then.
  """
  @spec remove_deps(String.t(), [String.t()]) :: :ok | :error | {:error, term()}
  # Edits only the generated worker project's mix.exs, mix.lock and config.
  # sobelow_skip ["Traversal.FileModule"]
  def remove_deps(project_dir, apps) do
    mix_exs_path = Path.join(project_dir, "mix.exs")
    lock_path = Path.join(project_dir, "mix.lock")

    with {:ok, mix_exs} <- File.read(mix_exs_path),
         {:ok, lock} <- File.read(lock_path),
         {:ok, mix_exs} <- remove_mix_lines(mix_exs, apps) do
      # A lock line Mix never wrote is nothing to take out.
      lock =
        Enum.reduce(apps, lock, fn app, acc ->
          Regex.replace(~r/^\s*"#{Regex.escape(app)}":[^\n]*\n/m, acc, "", global: false)
        end)

      with :ok <- File.write(mix_exs_path, mix_exs),
           :ok <- File.write(lock_path, lock),
           do: unconfigure_files(project_dir, apps)
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp unconfigure_files(project_dir, apps) do
    project_dir
    |> Path.join("config/*.exs")
    |> Path.wildcard()
    |> Enum.reduce_while(:ok, fn path, :ok ->
      with {:ok, content} <- File.read(path),
           :ok <- write_changed(path, content, unconfigure(content, apps, Path.basename(path))) do
        {:cont, :ok}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp write_changed(_path, content, content), do: :ok

  # A config file of the generated worker project, as `unconfigure_files/2`
  # listed it.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_changed(path, _content, changed), do: File.write(path, changed)

  @doc """
  `content`, a config file of the Nerves template named `file`, without
  `apps`: each one out of every `application_sort` list, and, in
  `runtime.exs`, which runs at boot, every line that names the application
  (`:app`) or its module (`App`, as `Macro.camelize/1` makes it). What the
  template writes (`mix nerves.new`, nerves_bootstrap 1.17.3):
  `application_sort: [init: [:logger_backends, :nerves_runtime]]` in
  `target.exs`, and `Application.ensure_all_started(:logger_backends)` and
  `LoggerBackends.add(RingLogger)` in `runtime.exs`.
  """
  @spec unconfigure(String.t(), [String.t()], String.t()) :: String.t()
  def unconfigure(content, apps, file \\ "config.exs") do
    Enum.reduce(apps, content, fn app, acc ->
      acc
      |> String.split("\n")
      |> Enum.flat_map(&unconfigure_line(&1, app, file))
      |> Enum.join("\n")
    end)
  end

  defp unconfigure_line(line, app, file) do
    atom = ~r/:#{Regex.escape(app)}(?![a-zA-Z0-9_?!])/
    module = ~r/(?<![a-zA-Z0-9_.])#{Regex.escape(Macro.camelize(app))}(?![a-zA-Z0-9_])/

    cond do
      String.contains?(line, "application_sort") -> [drop_listed(line, atom)]
      file == "runtime.exs" and (line =~ atom or line =~ module) -> []
      true -> [line]
    end
  end

  # `:app` out of every list on the line, with the comma that joined it.
  defp drop_listed(line, atom) do
    source = Regex.source(atom)

    line
    |> then(&Regex.replace(~r/#{source}\s*,\s*/, &1, ""))
    |> then(&Regex.replace(~r/,\s*#{source}/, &1, ""))
    |> then(&Regex.replace(~r/\[\s*#{source}\s*\]/, &1, "[]"))
  end

  # Every app's `mix.exs` line, once each, or `:error` when one has none.
  defp remove_mix_lines(content, apps) do
    Enum.reduce_while(apps, {:ok, content}, fn app, {:ok, acc} ->
      regex = ~r/^\s*\{:#{Regex.escape(app)},[^\n]*\n/m

      if Regex.match?(regex, acc),
        do: {:cont, {:ok, Regex.replace(regex, acc, "", global: false)}},
        else: {:halt, :error}
    end)
  end

  @doc """
  Splits optional dependencies from `NccWorker.DepsLock.unresolved_optional_deps/2`
  into `{to_add, skipped}`, where `skipped` holds the application names on
  `Compatibility.OptionalDeps.never_added/0` (see the module doc), matched by
  application or Hex package name.
  """
  @spec optional_deps_to_add([map()]) :: {[map()], [String.t()]}
  def optional_deps_to_add(deps) do
    {skipped, to_add} =
      Enum.split_with(deps, fn dep ->
        dep.app in @optional_deps_never_added or dep.package in @optional_deps_never_added
      end)

    {to_add, Enum.map(skipped, & &1.app)}
  end

  @doc false
  @spec optional_deps_never_added() :: [String.t()]
  def optional_deps_never_added, do: @optional_deps_never_added

  @typedoc """
  The project's `mix.exs` and `mix.lock` as they were before optional
  dependencies were added, for `restore/1`.
  """
  @type snapshot :: %{mix_exs: {String.t(), String.t()}, lock: {String.t(), String.t()}}

  @doc """
  Reads `mix.exs` and `mix.lock` so `restore/1` can put them back.
  """
  @spec snapshot(String.t()) :: {:ok, snapshot()} | {:error, term()}
  # Reads only the generated worker project's mix.exs and mix.lock.
  # sobelow_skip ["Traversal.FileModule"]
  def snapshot(project_dir) do
    mix_exs_path = Path.join(project_dir, "mix.exs")
    lock_path = Path.join(project_dir, "mix.lock")

    with {:ok, mix_exs} <- File.read(mix_exs_path),
         {:ok, lock} <- File.read(lock_path) do
      {:ok, %{mix_exs: {mix_exs_path, mix_exs}, lock: {lock_path, lock}}}
    end
  end

  @doc """
  Writes back the `mix.exs` and `mix.lock` a `snapshot/1` read.
  """
  @spec restore(snapshot()) :: :ok | {:error, term()}
  # Writes only the generated worker project's mix.exs and mix.lock.
  # sobelow_skip ["Traversal.FileModule"]
  def restore(%{mix_exs: {mix_exs_path, mix_exs}, lock: {lock_path, lock}}) do
    with :ok <- File.write(mix_exs_path, mix_exs) do
      File.write(lock_path, lock)
    end
  end

  @doc """
  Adds the package's unresolved optional dependencies (from
  `NccWorker.DepsLock.unresolved_optional_deps/2`) to the project and runs
  `mix deps.get` again, so they resolve alongside it the way they would in an
  application that has them in its lock.

  A full run calls this as a best-effort second pass, after the package's
  status has been decided by the build without them; a toolchain run calls
  it before its only compile and falls back to compiling without them
  (`NccWorker.Worker.toolchain_compile/5`). Either way it changes what gets
  published to the precompiled API, never a status.

  Returns `{:ok, apps}` with the application names actually injected: a
  dependency the template already declares is left alone and not listed, and
  when nothing is injected no `mix deps.get` runs. On any error, `mix.exs`
  and `mix.lock` are put back as `snapshot/1` read them and the result is
  `{:error, reason}`, so the caller builds on exactly the project it had.
  `{:error, {:restore_failed, reason, cause}}` means they could not be put
  back.

  Whatever earlier builds left of `package_name` under the build path in
  `env` (`MIX_BUILD_PATH`) is removed before `deps.get`. A package compiled
  before its optional dependency existed would not be recompiled by Mix,
  because its lock entry and marker are unchanged, and the published files
  would carry a `deps_lock` naming a dependency they never saw. After
  `deps.get`, so is the build of every dependency whose closure the new lock
  changed (`NccWorker.DepsLock.changed_closures/2`): ecto built before jason
  was locked keeps its beams unless that `deps.get` fetched jason itself.

  `deps_get` runs `mix deps.get` in the project with `env`; tests pass their
  own so they never reach the network.
  """
  @spec add_optional_deps(
          String.t(),
          String.t(),
          [map()],
          keyword() | list(),
          (String.t(), list() -> :ok | {:error, term()})
        ) :: {:ok, [String.t()]} | {:error, term()}
  def add_optional_deps(project_dir, package_name, deps, env, deps_get \\ &run_deps_get/2)

  def add_optional_deps(_project_dir, _package_name, [], _env, _deps_get), do: {:ok, []}

  def add_optional_deps(project_dir, package_name, deps, env, deps_get) do
    with {:ok, snapshot} <- snapshot(project_dir) do
      case inject_optional_deps(project_dir, deps) do
        {:ok, []} ->
          {:ok, []}

        {:ok, injected} ->
          fetch_injected(injected, snapshot, {project_dir, package_name, env}, deps_get)

        error ->
          restore_after(snapshot, error)
      end
    end
  end

  defp fetch_injected(injected, snapshot, {project_dir, package_name, env}, deps_get) do
    case fetch_optional_deps(project_dir, package_name, env, deps_get) do
      :ok -> {:ok, injected}
      error -> restore_after(snapshot, error)
    end
  end

  @doc """
  The first half of `add_optional_deps/5`: injects the optional dependencies
  into the project's `mix.exs` and returns the application names it injected.
  A dependency the template already declares is left alone and not listed;
  with nothing injected, `mix.exs` is not written. Restores nothing on an
  error: the caller holds the `snapshot/1`.
  """
  @spec inject_optional_deps(String.t(), [map()]) :: {:ok, [String.t()]} | {:error, term()}
  # Edits only the generated worker project's mix.exs.
  # sobelow_skip ["Traversal.FileModule"]
  def inject_optional_deps(project_dir, deps) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, new_content, injected} <- inject_deps(content, deps),
         :ok <- write_injected(mix_exs_path, new_content, injected) do
      {:ok, injected}
    end
  end

  defp write_injected(_path, _content, []), do: :ok

  # sobelow_skip ["Traversal.FileModule"]
  defp write_injected(path, content, _injected), do: File.write(path, content)

  @doc """
  The second half of `add_optional_deps/5`, for one build env: removes the
  package's build under that env's `MIX_BUILD_PATH`, runs `deps_get` with
  it, then removes the build of every dependency whose closure the new lock
  changed (`remove_changed_closures/3`). Restores nothing on an error.
  """
  @spec fetch_optional_deps(
          String.t(),
          String.t(),
          keyword() | list(),
          (String.t(), list() -> :ok | {:error, term()})
        ) :: :ok | {:error, term()}
  def fetch_optional_deps(project_dir, package_name, env, deps_get \\ &run_deps_get/2) do
    with {:ok, before} <- lock_for_closures(project_dir),
         :ok <- remove_stale_build(env, package_name),
         :ok <- deps_get.(project_dir, env) do
      remove_changed_closures(project_dir, before, env)
    end
  end

  @doc """
  Takes the optional dependencies out again: restores `snapshot` and removes
  the package's build under `MIX_BUILD_PATH` in `env`, so the next compile
  rebuilds it without them. The sources fetched for them stay under `deps/`,
  which Mix ignores for a dependency `mix.exs` no longer declares.

  So does the build of every dependency whose closure the restored lock
  changes. Mix fetches nothing when an optional dependency goes, so it
  marks nothing, and ecto built with jason would stay that way: the package
  rebuilt "without" jason would expand ecto's macros as ecto saw jason. A
  lock it replaces that cannot be read is still restored, then an error.
  """
  @spec drop_optional_deps(snapshot(), String.t(), keyword() | list()) :: :ok | {:error, term()}
  def drop_optional_deps(%{lock: {lock_path, _lock}} = snapshot, package_name, env) do
    project_dir = Path.dirname(lock_path)
    before = lock_for_closures(project_dir)

    with :ok <- restore(snapshot),
         {:ok, before} <- before,
         :ok <- remove_stale_build(env, package_name) do
      remove_changed_closures(project_dir, before, env)
    end
  end

  defp lock_for_closures(project_dir) do
    case DepsLock.lock_or_empty(project_dir) do
      {:ok, lock} -> {:ok, lock}
      :error -> {:error, {:rm_rf_failed, :lock_unreadable, Path.join(project_dir, "mix.lock")}}
    end
  end

  # The builds `DepsLock.changed_closures/2` names between `before` and the
  # lock now on disk, under the env's build path. A lock name that is not an
  # application name is never a path.
  defp remove_changed_closures(project_dir, before, env) do
    with {:ok, now} <- lock_for_closures(project_dir) do
      before
      |> DepsLock.changed_closures(now)
      |> Enum.filter(&Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, &1))
      |> Enum.reduce_while(:ok, fn app, :ok -> remove_or_halt(env, app) end)
    end
  end

  defp remove_or_halt(env, app) do
    case remove_stale_build(env, app) do
      :ok -> {:cont, :ok}
      error -> {:halt, error}
    end
  end

  defp restore_after(snapshot, {:error, cause}) do
    case restore(snapshot) do
      :ok -> {:error, cause}
      {:error, reason} -> {:error, {:restore_failed, reason, cause}}
    end
  end

  # Only the build path the caller named; nothing is removed when the env has
  # none.
  # sobelow_skip ["Traversal.FileModule"]
  defp remove_stale_build(env, package_name) do
    with {_, build_path} <- List.keyfind(env, "MIX_BUILD_PATH", 0),
         {:error, reason, path} <- File.rm_rf(Path.join([build_path, "lib", package_name])) do
      {:error, {:rm_rf_failed, reason, path}}
    else
      _ -> :ok
    end
  end

  @doc false
  # Prepends one `{:app, "requirement"}` entry per dependency, with `hex:`
  # when the Hex package is not the application, and returns the applications
  # it added. A dependency the template already declares is left alone: Mix
  # refuses a dependency declared twice at the top level, and the template's
  # requirement is the one every Nerves project has.
  @spec inject_deps(String.t(), [map()]) :: {:ok, String.t(), [String.t()]} | {:error, term()}
  def inject_deps(content, deps) do
    Enum.reduce_while(deps, {:ok, content, []}, fn dep, {:ok, acc, added} ->
      case inject_optional_dep(acc, dep) do
        {:ok, ^acc} -> {:cont, {:ok, acc, added}}
        {:ok, injected} -> {:cont, {:ok, injected, added ++ [dep.app]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp inject_optional_dep(content, dep) do
    if Regex.match?(~r/\{:#{Regex.escape(dep.app)},/, content),
      do: {:ok, content},
      else: prepend_dep(content, %{name: dep.app, requirement: dep.requirement, hex: dep.package})
  end

  @spec inject_dep(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defp inject_dep(content, package) do
    case repin_template_dep(content, package) do
      {:ok, repinned} -> {:ok, repinned}
      :not_in_template -> prepend_dep(content, package)
    end
  end

  # The template already depends on some packages we test (nerves itself,
  # shoehorn, nerves_runtime, the nerves_system_* deps). Adding a second entry
  # makes Mix refuse the project ("the dependency :nerves is duplicated at the
  # top level"), so the existing entry gets the tested requirement and keeps its
  # own options, such as nerves' `runtime: false` -- except `targets:`: a system
  # dep is scoped to its own target, and the tested package has to be in every
  # target's build, or the others would pass without having compiled it.
  @spec repin_template_dep(String.t(), map()) :: {:ok, String.t()} | :not_in_template
  defp repin_template_dep(content, %{name: name} = package) do
    # The whole `{:name, "...", ...}` entry on one line. The comma after the
    # name keeps `{:nerves_runtime, ...}` from matching `nerves`.
    entry = ~r/\{:#{Regex.escape(name)},\s*"[^"]*"(?<opts>[^}\n]*)\}/
    requirement = dep_tuple(package) |> String.trim_trailing("}")

    # A function, not a replacement string: `\1` in a string replacement is a
    # backreference, and the new entry must be written exactly as built.
    repin = fn _whole, opts -> requirement <> drop_targets(opts) <> "}" end

    if Regex.match?(entry, content),
      do: {:ok, Regex.replace(entry, content, repin, global: false)},
      else: :not_in_template
  end

  # `targets: :rpi4` or `targets: [:rpi3, :rpi4]`.
  defp drop_targets(opts),
    do: Regex.replace(~r/,\s*targets:\s*(\[[^\]]*\]|[^,]+)/, opts, "")

  @spec prepend_dep(String.t(), map()) :: {:ok, String.t()} | {:error, term()}
  defp prepend_dep(content, package) do
    dep_line = "      #{dep_tuple(package)},\n"

    # Insert the new dep as the first entry in the `defp deps do [...] end`
    # block. The anchor is the opening "[" of the deps list — matching there
    # survives variations in spacing and subsequent dep layout.
    case Regex.run(~r/defp\s+deps\s+do\s*\n\s*\[\s*\n/, content, return: :index) do
      [{start, len}] ->
        {before, rest} = String.split_at(content, start + len)
        {:ok, before <> dep_line <> rest}

      _ ->
        {:error, {:mix_exs_deps_list_not_found, content}}
    end
  end

  @spec dep_tuple(map()) :: String.t()
  defp dep_tuple(%{name: name, requirement: req, hex: hex})
       when is_binary(req) and req != "" and is_binary(hex) and hex != name,
       do: ~s[{:#{name}, "#{req}", hex: :#{hex}}]

  defp dep_tuple(%{name: name, version: version}) when is_binary(version) and version != "",
    do: ~s[{:#{name}, "== #{version}"}]

  defp dep_tuple(%{name: name, requirement: req}) when is_binary(req) and req != "",
    do: ~s[{:#{name}, "#{req}"}]

  defp dep_tuple(%{name: name}),
    do: ~s[{:#{name}, ">= 0.0.0"}]

  @doc false
  # One `mix deps.get` in `env`; public for `NccWorker.Pins`' caller.
  @spec run_deps_get(String.t(), list()) :: :ok | {:error, term()}
  def run_deps_get(project_dir, env) do
    case System.cmd("mix", ["deps.get"], cd: project_dir, env: env, stderr_to_stdout: true) do
      {_, 0} -> :ok
      {error, _} -> {:error, {:deps_get_failed, error}}
    end
  end

  @spec create_nerves_project(String.t(), [String.t()]) :: :ok | {:error, term()}
  # project_dir is the runner-configured work mount plus the fixed proj directory.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_nerves_project(project_dir, targets) do
    # Create the project directory
    File.mkdir_p!(project_dir)

    # Targets are named explicitly. Called bare, `mix nerves.new` falls back to
    # nerves_bootstrap's own `@default_targets` -- eleven systems, only three of
    # which we build, and which omits trellis entirely. A system missing from
    # mix.exs does not fail visibly; it fails that target on every package with
    # an unresolvable dependency, which reads like the package being broken.
    # Create the test project
    case System.cmd("mix", nerves_new_args(targets), cd: project_dir, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {error, _} ->
        {:error, {:nerves_new_failed, error}}
    end
  end

  @spec maybe_apply_systems_override(String.t(), map() | nil) :: :ok | {:error, term()}
  defp maybe_apply_systems_override(_project_dir, nil), do: :ok

  # Edits the fixed mix.exs in the generated container project; overrides are operator inputs.
  # sobelow_skip ["Traversal.FileModule"]
  defp maybe_apply_systems_override(project_dir, systems_override)
       when is_map(systems_override) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    case File.read(mix_exs_path) do
      {:ok, content} ->
        updated_content = apply_overrides(content, systems_override)
        File.write(mix_exs_path, updated_content)

      {:error, reason} ->
        {:error, {:cannot_read_mix_exs, reason}}
    end
  end

  # Edits the fixed mix.exs in the generated container project.
  # sobelow_skip ["Traversal.FileModule"]
  @spec pin_nerves_version(String.t()) :: :ok | {:error, term()}
  defp pin_nerves_version(project_dir) do
    mix_exs_path = Path.join(project_dir, "mix.exs")

    with {:ok, content} <- File.read(mix_exs_path),
         {:ok, pinned} <- pin_nerves(content) do
      File.write(mix_exs_path, pinned)
    end
  end

  @doc false
  # Fails rather than passing through when the template has no prerelease
  # `:nerves` dep: a nerves_bootstrap that ignored --prerelease would otherwise
  # silently put every build back on stable Nerves.
  @spec pin_nerves(String.t()) :: {:ok, String.t()} | {:error, term()}
  def pin_nerves(content) do
    nerves_dep = ~r/(\{:nerves\s*,\s*)"~>\s*2\.0\.0-[^"]*"/

    if Regex.match?(nerves_dep, content) do
      {:ok, String.replace(content, nerves_dep, "\\1\"== #{@nerves_version}\"")}
    else
      {:error, {:nerves_pin_failed, content}}
    end
  end

  @doc false
  @spec nerves_new_args([String.t()]) :: [String.t()]
  def nerves_new_args(targets) do
    ["nerves.new", ".", "--app", "nerves_compatibility_test", "--no-nerves-pack", "--prerelease"] ++
      Enum.flat_map(targets, &["--target", &1])
  end

  @spec apply_overrides(String.t(), map()) :: String.t()
  defp apply_overrides(content, systems_override) do
    Enum.reduce(systems_override, content, fn {system_pkg, requirement}, acc ->
      # Replace the version requirement for this system package
      # Pattern: {:nerves_system_xxx, "~> x.y.z", runtime: false, targets: :xxx}
      pattern = ~r/(:\s*#{Regex.escape(system_pkg)}\s*,\s*)"[^"]*"/

      String.replace(acc, pattern, "\\1\"#{requirement}\"")
    end)
  end
end
