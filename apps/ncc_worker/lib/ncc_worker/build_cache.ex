defmodule NccWorker.BuildCache do
  @moduledoc """
  Cross-run cache of compiled dependency artifacts.

  Compiling the dependency tree is not part of the cost of a package build, it
  is essentially all of it. Assembling the firmware image takes about 18
  seconds; compiling the tree takes 8 to 25 minutes per target, and nearly every
  one of those beams belongs to a dependency that the next package in the queue
  will compile again from scratch. On a sweep of 2500 packages the same `ash`
  gets rebuilt hundreds of times, once per target each time.

  Restoring `_build/<target>/lib/<dep>` from an earlier run removes that work:
  measured on `ash_ai`, an rpi4 build went from 13m40 to 32 seconds, with only
  the package under test recompiling. Mix accepts a restored dependency without
  argument because it decides staleness from the lock entry and file contents
  rather than from mtimes, so an artifact copied in on top of freshly unpacked
  sources is not rebuilt.

  ## What the key has to cover, and why

  Two projects can resolve the same dependency at the same version and still
  need different artifacts, because a dependency may branch on what else is
  loadable: `jason` only emits its `Decimal` encoder when `decimal` is in the
  tree, and Spark-based libraries generate different DSL modules depending on
  which extensions are present. So the key is not `(name, version)`. It is the
  dependency plus its entire resolved subtree, read from `mix deps.tree`, which
  already contains the optional dependencies that a sibling pulled in. Nothing
  outside that subtree can legally change how the dependency compiles.

  The worker image is deliberately absent from the key: the portal points the
  mount at a per-image directory, so rebuilding the image starts from an empty
  cache instead of trusting artifacts built by a different Elixir or OTP.

  ## The one thing the key cannot cover

  Where two dependencies declare each other optionally (`jason` and `decimal`
  do), whichever compiles first does not see the other, so the pair's artifacts
  depend on compile order rather than on any input. That variance exists today,
  between consecutive runs, with no cache involved: comparing two finished
  builds of sibling `ash_*` packages showed 9 of 39 shared dependencies
  differing, in 1 to 13 beams out of as many as 1317. The cache pins whichever
  variant was stored first, which makes the result stable rather than
  order-dependent. It is a change in which variant wins, not a new class of
  variance.
  """

  @cache_env "NCC_BUILD_CACHE"
  @key_version "v1"

  @type entry :: %{name: String.t(), key: String.t(), dir: String.t()}
  @type plan :: %{root: String.t(), entries: [entry()]}

  @doc """
  Works out which dependency build directories are cacheable and under what key.

  Returns `:disabled` when no cache is mounted, which is the default and leaves
  the build byte-for-byte as it was before this module existed.

  Must run after `mix deps.get` (the lock has to be final) and while nothing
  else is using the project directory: `mix deps.tree --format dot` writes
  `deps_tree.dot` into the project root, so two targets doing this at once would
  race. The callers do it in the serial preparation phase for that reason.
  """
  @spec plan(String.t(), String.t(), String.t(), keyword(), [String.t()]) :: plan() | :disabled
  def plan(project_dir, build_path, target, env, exclude) do
    with root when is_binary(root) <- cache_root(),
         {:ok, lock} <- read_lock(project_dir),
         {:ok, graph} <- dep_graph(project_dir, env) do
      excluded = MapSet.new(exclude)

      entries =
        lock
        |> Map.keys()
        |> Enum.reject(&MapSet.member?(excluded, &1))
        |> Enum.map(fn name ->
          %{
            name: name,
            key: key_for(name, target, closure(graph, name), lock),
            dir: Path.join([build_path, "lib", name])
          }
        end)

      %{root: root, entries: entries}
    else
      _ -> :disabled
    end
  end

  @doc """
  Copies every cached dependency build into place.

  Skips a dependency whose build directory already exists: this runs before the
  compile, so anything already there was put there by `mix deps.get` and is not
  ours to overwrite.

  Returns `{restored, total}` for reporting. A copy that fails is not an error
  worth failing the build over. The compiler simply rebuilds that dependency.
  """
  @spec restore(plan() | :disabled) :: {non_neg_integer(), non_neg_integer()}
  def restore(:disabled), do: {0, 0}

  def restore(%{root: root, entries: entries}) do
    restored =
      Enum.count(entries, fn %{key: key, dir: dir} ->
        source = Path.join(root, key)

        not File.dir?(dir) and File.dir?(source) and copy_tree(source, dir) == :ok
      end)

    {restored, length(entries)}
  end

  @doc """
  Stores dependency builds that the cache does not have yet.

  Written to a temporary directory and moved into place, so a reader never sees
  a half-copied entry and two workers racing on the same key both end up with a
  complete one. Only ever called for a successful build: a failed one can leave
  a dependency directory that Mix abandoned partway through.
  """
  @spec store(plan() | :disabled) :: non_neg_integer()
  def store(:disabled), do: 0

  def store(%{root: root, entries: entries}) do
    Enum.count(entries, fn %{key: key, dir: dir} ->
      target = Path.join(root, key)

      File.dir?(dir) and not File.dir?(target) and store_entry(dir, target)
    end)
  end

  defp store_entry(dir, target) do
    staging = target <> ".tmp." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

    with :ok <- copy_tree(dir, staging),
         :ok <- File.rename(staging, target) do
      true
    else
      _ ->
        File.rm_rf(staging)
        false
    end
  end

  # `cp -a` rather than `File.cp_r/2`: it is a single process instead of one
  # syscall storm per file, and it keeps permissions and symlinks, which beam
  # directories do contain.
  defp copy_tree(source, dest) do
    with :ok <- File.mkdir_p(dest),
         {_, 0} <- System.cmd("cp", ["-a", Path.join(source, "."), dest], stderr_to_stdout: true) do
      :ok
    else
      _ ->
        File.rm_rf(dest)
        :error
    end
  end

  defp cache_root do
    case System.get_env(@cache_env) do
      root when is_binary(root) and root != "" ->
        if File.dir?(root), do: root, else: nil

      _ ->
        nil
    end
  end

  # The lock is the only place with an exact version and content hash per
  # dependency. `Code.eval_file/1` is how Mix itself reads it.
  defp read_lock(project_dir) do
    path = Path.join(project_dir, "mix.lock")

    if File.regular?(path) do
      {lock, _bindings} = Code.eval_file(path)

      {:ok,
       lock
       |> Enum.flat_map(fn
         {name, {:hex, _app, version, checksum, _managers, _deps, _repo, outer}} ->
           [{to_string(name), "#{version} #{checksum} #{outer}"}]

         {name, {:hex, _app, version, checksum, _managers, _deps, _repo}} ->
           [{to_string(name), "#{version} #{checksum}"}]

         _other ->
           []
       end)
       |> Map.new()}
    else
      :error
    end
  rescue
    _ -> :error
  end

  # `--format dot` over `--format plain`: the edge list is unambiguous, while
  # the plain tree encodes depth as box-drawing indentation that has to be
  # counted back out.
  defp dep_graph(project_dir, env) do
    dot_file = Path.join(project_dir, "deps_tree.dot")

    try do
      case System.cmd("mix", ["deps.tree", "--format", "dot"],
             cd: project_dir,
             env: env,
             stderr_to_stdout: true
           ) do
        {_, 0} -> {:ok, parse_dot(File.read!(dot_file))}
        _ -> :error
      end
    rescue
      _ -> :error
    after
      File.rm(dot_file)
    end
  end

  defp parse_dot(contents) do
    ~r/"([^"]+)"\s*->\s*"([^"]+)"/
    |> Regex.scan(contents)
    |> Enum.reduce(%{}, fn [_, from, to], graph ->
      Map.update(graph, from, [to], &[to | &1])
    end)
  end

  # Everything reachable from the dependency, itself excluded. Optional
  # dependencies that a sibling satisfied show up here as ordinary edges, which
  # is exactly why the graph is the right source and the lock alone is not.
  # Cycles are real (`jason` and `decimal` point at each other), hence the
  # visited set.
  @doc false
  def closure(graph, name) do
    graph
    |> reachable(Map.get(graph, name, []), MapSet.new([name]))
    |> MapSet.delete(name)
  end

  defp reachable(_graph, [], visited), do: visited

  defp reachable(graph, [node | rest], visited) do
    if MapSet.member?(visited, node) do
      reachable(graph, rest, visited)
    else
      reachable(graph, Map.get(graph, node, []) ++ rest, MapSet.put(visited, node))
    end
  end

  @doc false
  def key_for(name, target, closure, lock) do
    [
      @key_version,
      "elixir=" <> System.version(),
      "otp=" <> to_string(:erlang.system_info(:otp_release)),
      "target=" <> target,
      "dep=" <> name <> " " <> Map.get(lock, name, "unlocked")
    ]
    |> Enum.concat(
      closure
      |> Enum.map(&(&1 <> " " <> Map.get(lock, &1, "unlocked")))
      |> Enum.sort()
    )
    |> Enum.join("\n")
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end
end
