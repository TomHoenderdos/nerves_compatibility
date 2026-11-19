defmodule Portal.Pins do
  @moduledoc """
  The operator's entry point to pinned builds (lock-driven builds spec,
  phase 1): from a project's `mix.lock`, the pin set of every package in it
  (`Compatibility.Pins`), and a `Portal.Workers.PinnedBuild` for each whose
  closure is not served yet.

      Portal.Pins.from_lock("/path/to/mix.lock", toolchain: "1.20/29")
      Portal.Pins.from_lock(File.read!("mix.lock"), dry_run: false, cap: 20)

  The lock is read without being evaluated (`Portal.Pins.Lock`). For each
  Hex entry of the public repository, the package's closure is walked along
  the lock's own edges: an edge whose target the lock holds is pinned at the
  lock's version, required or optional, unless it is an optional edge into a
  test or doc tool (`Compatibility.Pins.dev_only/0`), which a lock cannot
  mark `only: :test`; a required edge whose target is absent refuses the set
  (`member_missing`). A set is refused when a member is not a Hex release of
  the public repository (`non_hex`: a git, path or private dependency), is
  Nerves tooling (`tooling`), does not satisfy an edge's requirement into it
  (`unsatisfied`, which is what an `override: true` leaves), or the set does
  not validate. Phase 1 builds only pure-BEAM sets: a set with a native
  marker (`Portal.NativeClosure.markers/0`), a `nerves*` member or a `make`
  manager is left for phase 2 (`native`).

  Then, in package order, each set is skipped when its build is already
  `judged` (a pinned build row of the key that is not an `error`),
  `served` (a toolchain build of the version on the toolchain, of any
  builder version or variant, passing, unrevoked, with exactly these `deps`,
  itself or as an earlier build), or `queued_dup` (a pinned build job of
  the key still incomplete). The rest are checked against the signed
  registry (`Portal.HexDeps`): the package's and every pin's outer checksum
  must be the lock's, and none may be retired as `security` or `invalid`.
  At most `cap:` (50) are queued, at priority 9, on the toolchain queue
  `Portal.Toolchains.MemoryRouting` picks; the rest are listed as `cap`.

  It only lists unless given `dry_run: false`. Options: `target:` (`"host"`,
  the only one phase 1 builds), `toolchain:` (the first configured
  toolchain by default), `cap:`, `hex:` (a module with `releases/2`, for
  tests).
  """

  alias Compatibility.Pins, as: Set
  alias Portal.Pins.Lock

  @default_cap 50
  @priority 9
  @dev_only Set.dev_only()
  @incomplete ~w(available scheduled executing retryable suspended)

  @type set :: %{
          app: String.t(),
          package: String.t(),
          version: String.t(),
          pins: Set.t(),
          native: boolean()
        }

  @doc """
  Derives, dedupes and (with `dry_run: false`) queues the lock's pinned
  builds; see the moduledoc. `{:ok, report}`, with `queue` (queued, or that
  would be) and `skipped` (each `%{package, version, reason}`), or
  `{:error, reason}` for a lock that cannot be read or an unknown target or
  toolchain.
  """
  @spec from_lock(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_lock(lock, opts \\ []) when is_binary(lock) do
    with {:ok, content} <- read(lock),
         {:ok, entries} <- Lock.parse(content),
         {:ok, target} <- target(Keyword.get(opts, :target, "host")),
         {:ok, toolchain, image} <- toolchain(Keyword.get(opts, :toolchain)) do
      {sets, refused} = derive(entries)
      {:ok, decide(sets, refused, %{target: target, toolchain: toolchain, image: image}, opts)}
    end
  end

  # A lock's text, or a path to one: the operator's rpc call names a file
  # on the host it runs on.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(lock) do
    if String.starts_with?(String.trim_leading(lock), "%{") do
      {:ok, lock}
    else
      case File.read(lock) do
        {:ok, content} -> {:ok, content}
        {:error, reason} -> {:error, {:unreadable, reason}}
      end
    end
  end

  defp target(target) when target in ["host", "pure_elixir"], do: {:ok, "pure_elixir"}
  defp target(target), do: {:error, {:unsupported_target, target}}

  defp toolchain(name) do
    images = Portal.Toolchains.images()

    case Enum.find(images, &(name == nil or &1.toolchain == name)) do
      %{toolchain: toolchain, image: image} -> {:ok, toolchain, image}
      nil -> {:error, {:unknown_toolchain, name}}
    end
  end

  @doc """
  Every package's set from a parsed lock (`Portal.Pins.Lock.parse/1`), as
  `{sets, refused}`, both in package order; `refused` holds
  `%{package, version, reason}`. Public for tests.
  """
  @spec derive(%{String.t() => map()}) :: {[set()], [map()]}
  def derive(entries) do
    entries
    |> Enum.sort_by(fn {app, _entry} -> app end)
    |> Enum.flat_map(fn {app, entry} -> candidate(app, entry, entries) end)
    |> Enum.split_with(&match?({:ok, _}, &1))
    |> then(fn {sets, refused} ->
      {Enum.map(sets, &elem(&1, 1)), Enum.map(refused, &elem(&1, 1))}
    end)
  end

  defp candidate(app, %{source: :hex, repo: "hexpm"} = entry, entries) do
    if Set.tooling?(app) or Set.tooling?(entry.hex) or
         Portal.Catalog.ToolingSkip.tooling?(entry.hex),
       do: [refused(entry.hex, entry.version, "tooling")],
       else: [set(app, entry, entries)]
  end

  # A git, path or private-repository entry is never pinned.
  defp candidate(app, entry, _entries), do: [refused(app, entry[:version], "non_hex")]

  defp refused(package, version, reason),
    do: {:refused, %{package: package, version: version, reason: reason}}

  defp set(app, entry, entries) do
    case walk([app], entries, MapSet.new([app])) do
      {:ok, members} ->
        members = MapSet.delete(members, app)
        deps = members |> Enum.sort() |> Enum.map(&pin(&1, entries[&1]))
        checksum = String.downcase(entry.checksum)

        pins = %{
          "hash" =>
            Set.hash(%{
              package: entry.hex,
              version: entry.version,
              package_checksum: checksum,
              deps: deps
            }),
          "package_checksum" => checksum,
          "deps" => deps
        }

        with_valid(entry, pins, native?([app | MapSet.to_list(members)], entries))

      {:refused, reason} ->
        refused(entry.hex, entry.version, reason)
    end
  end

  defp with_valid(entry, pins, native) do
    case Set.validate(entry.hex, entry.version, pins) do
      {:ok, pins} ->
        {:ok,
         %{app: entry.hex, package: entry.hex, version: entry.version, pins: pins, native: native}}

      {:error, {:invalid_pins, why}} ->
        refused(entry.hex, entry.version, "invalid: " <> inspect(why, limit: 5))
    end
  end

  defp pin(app, entry),
    do: %{
      "name" => app,
      "hex" => entry.hex,
      "version" => entry.version,
      "checksum" => String.downcase(entry.checksum)
    }

  # The closure along the lock's edges, or the first reason it cannot be
  # pinned.
  defp walk([], _entries, seen), do: {:ok, seen}

  defp walk([app | rest], entries, seen) do
    Enum.reduce_while(entries[app].deps, {:ok, rest, seen}, fn dep, {:ok, queue, seen} ->
      case {edge(dep, entries[dep.app]), MapSet.member?(seen, dep.app)} do
        {:skip, _seen?} -> {:cont, {:ok, queue, seen}}
        {:follow, true} -> {:cont, {:ok, queue, seen}}
        {:follow, false} -> {:cont, {:ok, [dep.app | queue], MapSet.put(seen, dep.app)}}
        {{:refused, reason}, _seen?} -> {:halt, {:refused, reason}}
      end
    end)
    |> case do
      {:ok, queue, seen} -> walk(queue, entries, seen)
      refused -> refused
    end
  end

  defp edge(%{optional: true}, nil), do: :skip
  defp edge(dep, nil), do: {:refused, "member_missing: " <> dep.app}

  defp edge(%{optional: true, app: app}, _target) when app in @dev_only, do: :skip

  defp edge(dep, %{source: :hex, repo: "hexpm"} = target) do
    cond do
      Set.tooling?(dep.app) or Set.tooling?(target.hex) -> {:refused, "tooling: " <> dep.app}
      target.hex != dep.hex -> {:refused, "non_hex: " <> dep.app}
      not satisfies?(target.version, dep.requirement) -> {:refused, "unsatisfied: " <> dep.app}
      true -> :follow
    end
  end

  defp edge(dep, _target), do: {:refused, "non_hex: " <> dep.app}

  defp satisfies?(version, requirement) do
    case Version.parse_requirement(requirement) do
      {:ok, requirement} -> Version.match?(version, requirement)
      :error -> false
    end
  rescue
    _ -> false
  end

  defp native?(apps, entries) do
    markers = Portal.NativeClosure.markers()

    Enum.any?(apps, fn app ->
      entry = entries[app]

      app in markers or entry.hex in markers or String.starts_with?(app, "nerves") or
        "make" in entry.managers
    end)
  end

  defp decide(sets, refused, ctx, opts) do
    dry_run = Keyword.get(opts, :dry_run, true)
    cap = Keyword.get(opts, :cap, @default_cap)
    hex = Keyword.get(opts, :hex, Portal.HexDeps)
    queue_for = Portal.Toolchains.MemoryRouting.router(Enum.map(sets, & &1.package))

    {queue, skipped} =
      Enum.reduce(sets, {[], []}, fn set, {queue, skipped} ->
        case verdict(set, ctx, hex, length(queue) < cap) do
          :queue -> {[set | queue], skipped}
          reason -> {queue, [skip(set, reason) | skipped]}
        end
      end)

    queue = Enum.reverse(queue)
    {queued, conflicts} = if dry_run, do: {queue, []}, else: insert(queue, ctx, queue_for)
    skipped = Enum.reverse(skipped) ++ conflicts ++ refused

    %{
      dry_run: dry_run,
      target: ctx.target,
      toolchain: ctx.toolchain,
      queue: Enum.map(queued, &summary/1),
      skipped: skipped,
      counts:
        skipped
        |> Enum.frequencies_by(&(&1.reason |> String.split(":") |> hd()))
        |> Map.put("queue", length(queued))
    }
  end

  defp verdict(set, ctx, hex, room?) do
    cond do
      set.native -> "native (phase 2)"
      judged?(set, ctx) -> "judged"
      served?(set, ctx) -> "served"
      queued?(set, ctx) -> "queued_dup"
      not room? -> "cap"
      true -> registry(set, hex)
    end
  end

  defp skip(set, reason), do: %{package: set.package, version: set.version, reason: reason}

  defp summary(set),
    do: %{
      package: set.package,
      version: set.version,
      pin_hash: set.pins["hash"],
      deps: length(set.pins["deps"])
    }

  defp args(set, ctx) do
    %{
      "package" => set.package,
      "version" => set.version,
      "toolchain" => ctx.toolchain,
      "image" => ctx.image,
      "builder_version" => Portal.Toolchains.builder_version(),
      "target" => ctx.target,
      "pin_hash" => set.pins["hash"],
      "pins" => set.pins
    }
  end

  defp insert(queue, ctx, queue_for) do
    Enum.reduce(queue, {[], []}, fn set, {queued, conflicts} ->
      set
      |> args(ctx)
      |> Portal.Workers.PinnedBuild.new(priority: @priority, queue: queue_for.(set.package))
      |> Oban.insert()
      |> case do
        {:ok, %Oban.Job{conflict?: true}} -> {queued, [skip(set, "queued_dup") | conflicts]}
        {:ok, _job} -> {[set | queued], conflicts}
        {:error, error} -> {queued, [skip(set, "insert_failed: " <> inspect(error)) | conflicts]}
      end
    end)
    |> then(fn {queued, conflicts} -> {Enum.reverse(queued), Enum.reverse(conflicts)} end)
  end

  @judged_sql """
  SELECT 1 FROM catalog_pinned_builds pb
  JOIN catalog_packages p ON p.id = pb.package_id
  WHERE p.name = $1 AND pb.version = $2 AND pb.pin_hash = $3 AND pb.target = $4
    AND pb.system_version = '' AND pb.toolchain = $5 AND pb.builder_version = $6
    AND pb.config_variant = 'default' AND pb.status <> 'error'
  LIMIT 1
  """

  # A default build of the version on the toolchain, any builder version or
  # variant, that serves exactly this closure, itself or as an earlier build.
  @served_sql """
  SELECT 1 FROM catalog_toolchain_builds t
  JOIN catalog_packages p ON p.id = t.package_id
  WHERE p.name = $1 AND t.version = $2 AND t.toolchain = $3
    AND t.status = 'pass' AND t.revoked_at IS NULL AND t.config_variant = 'default'
    AND t.variant IN #{Portal.Catalog.ToolchainBuild.variants_sql()}
    AND (t.deps_lock = $4::jsonb
         OR EXISTS (SELECT 1 FROM unnest(t.earlier_builds) AS e WHERE e->'deps_lock' = $4::jsonb))
  LIMIT 1
  """

  @queued_sql """
  SELECT 1 FROM oban_jobs
  WHERE worker = 'Portal.Workers.PinnedBuild' AND state::text = ANY($1::text[]) AND args @> $2::jsonb
  LIMIT 1
  """

  defp judged?(set, ctx) do
    params = [
      set.package,
      set.version,
      set.pins["hash"],
      ctx.target,
      ctx.toolchain,
      Portal.Toolchains.builder_version()
    ]

    Portal.Repo.query!(@judged_sql, params).rows != []
  end

  defp served?(set, ctx) do
    lock = Set.to_lock(set.pins["deps"])
    Portal.Repo.query!(@served_sql, [set.package, set.version, ctx.toolchain, lock]).rows != []
  end

  defp queued?(set, ctx) do
    key =
      set
      |> args(ctx)
      |> Map.take(["package", "version", "pin_hash", "target", "toolchain", "builder_version"])

    Portal.Repo.query!(@queued_sql, [@incomplete, key]).rows != []
  end

  # The signed registry's word on the package and every pin: the lock's
  # outer checksum, and not retired as security or invalid. `:queue` when
  # all hold, else the first reason.
  defp registry(set, hex) do
    members =
      [{set.package, set.version, set.pins["package_checksum"]}] ++
        Enum.map(set.pins["deps"], &{&1["hex"], &1["version"], &1["checksum"]})

    Enum.find_value(members, :queue, fn {name, version, checksum} ->
      case hex.releases(name, []) do
        {:ok, releases} -> release(Enum.find(releases, &(&1.version == version)), name, checksum)
        {:error, :hex_registry_unavailable} -> "registry_unavailable: " <> name
        {:error, _reason} -> "unknown_release: " <> name
      end
    end)
  end

  defp release(nil, name, _checksum), do: "unknown_release: " <> name

  defp release(%{outer_checksum: checksum} = release, name, checksum) do
    if Map.get(release, :retired_reason) in ["security", "invalid"],
      do: "retired: " <> name,
      else: nil
  end

  defp release(_release, name, _checksum), do: "checksum: " <> name
end
