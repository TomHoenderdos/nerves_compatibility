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
  not validate. A lock's `make` manager says nothing: erlang.mk packages such
  as cowboy list it and are pure Erlang.

  A pure-BEAM set is built on the toolchain path (phase 1, target
  `pure_elixir`). A set with a member that is a native marker
  (`Portal.NativeClosure.markers/0`) or a `nerves*` package, as
  `Portal.NativeClosure` reads a closure, is built on the firmware path
  (phase 2, `Portal.Pins.FirmwareBuild`): one target, the lock's
  `nerves_system_*` entry (`nerves_system_br` aside), at its exact release.
  A lock with several needs `system:` naming one, or every native set is
  skipped as `ambiguous_system`; one with none skips them as `no_system`.
  The release must be one this release can build exactly: a system the
  worker builds (`unsupported_system` otherwise), a Nerves 2 release, whose
  own `nerves` requirement in the lock accepts the Nerves the worker's
  template pins (`Compatibility.Nerves.buildable?/1`; `unbuildable_system`
  otherwise: a Nerves 1 era system requires `nerves ~> 1.11`; a release's
  major says nothing, trellis numbers its Nerves 2 releases 0.6.x), in the ABI table
  with its OTP (`system_abi_unknown` otherwise; a `system_abi` run reads
  it), and on the firmware image's OTP major (`system_otp` otherwise, phase
  4). Each reason names the system and release.

  Then, in package order, each set is skipped when its build is already
  `judged` (a pinned build row of the key, its target and release included,
  that is not an `error`), `served` (on the toolchain path, a toolchain build
  of the version on the toolchain, of any builder version or variant,
  passing, unrevoked, with exactly these `deps`, itself or as an earlier
  build; on the firmware path, that or a passing, served system result of
  the version for the target at the release, of a run on the firmware
  toolchain, whose own lock or a published variant's is exactly these
  `deps`), or `queued_dup` (a pinned build job of the key still
  incomplete). The rest are checked against the signed registry
  (`Portal.HexDeps`): the package's and every pin's outer checksum must be
  the lock's, and none may be retired as `security` or `invalid`. At most
  `cap:` (50) are queued over both paths, at priority 3: a toolchain build
  on the toolchain queue `Portal.Toolchains.MemoryRouting` picks, a firmware
  build on `:builds`; the rest are listed as `cap`. That is level with the
  speculative toolchain backlog and anonymous scan requests, and Oban runs
  one priority in `scheduled_at` order, so pinned builds run in the order
  they were queued instead of starving below a backlog that is refilled all
  the time (which kept the first 252 pinned jobs at 9 from ever running),
  and never ahead of an owner's or a GitHub scan request (0 and 1).

  With `deterministic: true`, and only while the `deterministic_builds_enabled`
  setting is on (`Portal.Deterministic`), a closure served or judged by a
  build without a deterministic sibling is queued for one: a pinned build
  of the set asks for its sibling as any build does while the setting is
  on, and its sibling is listed in the version's `deterministic` key, the
  only lists a client whose project sets `ERL_COMPILER_OPTIONS=deterministic`
  reads. A set then counts as `served` only when the format-2 manifest
  lists a sibling of exactly its closure on the path's toolchain, at
  `pure_elixir` or, on the firmware path, at its target and release: the
  manifest's own selection, so whatever keeps a sibling out of it
  (`Portal.Deterministic.served/1`, `served_pinned/1`, a firmware sibling
  beside a build that lost its key) keeps it out here. Its key's pinned row
  stays `judged` unless it is a served pass (passing, neither revoked nor
  withdrawn) whose sibling was never tried for
  (`Portal.Catalog.PinnedBuild`'s `sibling_attempted`), that owns no
  sibling row, revoked or not, and whose closure no listed sibling serves.
  A closure with a revoked sibling of any owner
  (`Portal.Precompiled.DeterministicRevocation`) is never queued for one
  again (`sibling_revoked`). Any other set served without a sibling is
  queued as a sibling backfill (the job's `sibling_backfill`), and the
  key's row records the attempt in the transaction that queues it, so a
  closure is queued for its sibling once whether its rebuild ever ingests
  or not. The rebuild replaces the row only with a pass whose sibling held;
  any other outcome leaves the row as it was (`Portal.Workers.PinnedBuild`).
  A key without a row gets the rebuild's own verdict row, with the attempt,
  and an `error` row that records one is `judged` too; any other `error`
  row is no verdict, with or without the option. A pinned build runs no
  optional pass (`optional_deps: "pinned"`), so the firmware sibling's
  refusal of a target that kept or dropped optional dependencies never
  applies to it. The report then says whether the setting held sets to
  siblings (`deterministic`), counts the sets queued for a sibling alone
  (`no_sibling`) and marks each queued set with it.

  Run `deterministic: true` on a node that holds the artifact store (the
  web host): a set is served with a sibling only when the rendered manifest
  lists it, and the manifest lists only files this node holds, so on a node
  without them every served closure looks sibling-less and is queued once.
  Before the first call with `dry_run: false`, every node that runs
  `:toolchain` or `:builds` must run this release: a node before it ignores
  `sibling_backfill` and may write a failed or skipped rebuild over the
  served row (the attempt recorded when the job was queued still holds, so
  the closure is not queued again).

  It only lists unless given `dry_run: false`. Options: `target:` (the
  toolchain path's, `"host"`), `toolchain:` (the toolchain path's, the first
  configured toolchain by default), `system:` (a `nerves_system_*` the lock
  holds), `system_release:` (the firmware path at another release of that
  system: the lock's sets as they are, the release and its own `nerves`
  requirement from the signed registry, `{:error, {:unknown_system_release,
  name, release}}` for one it does not list), `cap:`, `deterministic:`
  (`false` by default), `hex:` (a module with `releases/2`, for tests).

  A call with `dry_run: false` on a lock with a Nerves system stores the
  lock (`Portal.Pins.Locks`) with its options and its own release of the
  system, and `Portal.Workers.PinRefeed` feeds it again with
  `system_release:` when the system releases (stream S11).
  """

  require Ash.Query

  alias Compatibility.Pins, as: Set
  alias Portal.Pins.Lock

  @default_cap 50
  # Level with the toolchain backlog and anonymous scan requests (3),
  # behind owner and GitHub scan requests (0, 1); see the moduledoc.
  @priority 3
  # The firmware image's toolchain, `"<Elixir minor>/<OTP major>"`: every
  # firmware pinned build is keyed on it, and its OTP major is the one a
  # release's must be (`Portal.Catalog.Ingestion` refuses a result built on
  # another).
  @firmware_toolchain "1.20/29"
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
  `{:error, reason}` for a lock that cannot be read, an unknown target or
  toolchain, a `cap:` that is not a non-negative integer, or a
  `deterministic:` that is not a boolean.
  """
  @spec from_lock(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def from_lock(lock, opts \\ []) when is_binary(lock) do
    hex = Keyword.get(opts, :hex, Portal.HexDeps)

    with {:ok, content} <- read(lock),
         {:ok, entries} <- Lock.parse(content),
         {:ok, target} <- target(Keyword.get(opts, :target, "host")),
         {:ok, toolchain, image} <- toolchain(Keyword.get(opts, :toolchain)),
         {:ok, cap} <- cap(Keyword.get(opts, :cap, @default_cap)),
         {:ok, deterministic} <- deterministic(Keyword.get(opts, :deterministic, false)),
         {:ok, own_system} <- system(entries, Keyword.get(opts, :system)),
         {:ok, entries, system} <-
           at_release(entries, own_system, Keyword.get(opts, :system_release), hex) do
      lines = Map.new(systems(entries), fn {name, _version} -> {name, nerves(entries[name])} end)

      {sets, refused} = derive(entries)

      ctx = %{
        pure: %{
          path: :toolchain,
          target: target,
          system_version: "",
          toolchain: toolchain,
          image: image
        },
        firmware: firmware(system, lines),
        cap: cap,
        # `nil` without the option, else whether the setting holds sets to
        # their siblings.
        deterministic: deterministic && Portal.Deterministic.enabled?()
      }

      report = decide(sets, refused, ctx, opts)
      unless report.dry_run, do: store(content, own_system, ctx.pure.toolchain, deterministic)
      {:ok, report}
    end
  end

  # A real feed of a lock with a Nerves system is stored
  # (`Portal.Pins.Locks`), with the lock's own release of it, so a newer
  # release feeds it again (`Portal.Workers.PinRefeed`).
  defp store(content, {name, version}, toolchain, deterministic) when is_binary(name) do
    Portal.Pins.Locks.store(content, %{
      system: name,
      release: version,
      toolchain: toolchain,
      deterministic: deterministic == true
    })
  end

  defp store(_content, _system, _toolchain, _deterministic), do: :ok

  # `system_release:` (`Portal.Workers.PinRefeed`): the lock's system entry
  # at that release, with that release's own `nerves` requirement from the
  # signed registry; the sets and their closures are the lock's, only the
  # firmware path's release moves. nil keeps the lock as it is.
  defp at_release(entries, system, nil, _hex), do: {:ok, entries, system}

  defp at_release(_entries, {:none, _reason}, _release, _hex),
    do: {:error, :system_release_needs_system}

  defp at_release(entries, {name, _version}, release, hex) when is_binary(release) do
    with {:ok, releases} <- hex.releases(name, []),
         %{deps: deps} <- Enum.find(releases, &(&1.version == release)) do
      requirement =
        Enum.find_value(deps, fn dep -> if dep.package == "nerves", do: dep.requirement end)

      entry = entries[name]

      edges =
        [
          %{
            app: "nerves",
            hex: "nerves",
            requirement: requirement,
            optional: false,
            repo: "hexpm"
          }
        ] ++
          Enum.reject(entry.deps, &(&1.app == "nerves"))

      {:ok, Map.put(entries, name, %{entry | version: release, deps: edges}), {name, release}}
    else
      {:error, :hex_registry_unavailable} -> {:error, {:registry_unavailable, name}}
      _ -> {:error, {:unknown_system_release, name, release}}
    end
  end

  defp at_release(_entries, _system, release, _hex),
    do: {:error, {:invalid_system_release, release}}

  @doc "The firmware image's toolchain, which every firmware pinned build is keyed on."
  @spec firmware_toolchain() :: String.t()
  def firmware_toolchain do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:firmware_toolchain, @firmware_toolchain)
  end

  # The lock's system: `{name, version}`, or `{:none, reason}` when native
  # sets have none to build on.
  defp system(entries, nil) do
    case systems(entries) do
      [] -> {:ok, {:none, "no_system"}}
      [{name, version}] -> {:ok, {name, version}}
      many -> {:ok, {:none, "ambiguous_system: " <> Enum.map_join(many, ", ", &elem(&1, 0))}}
    end
  end

  defp system(entries, name) do
    case List.keyfind(systems(entries), name, 0) do
      {^name, version} -> {:ok, {name, version}}
      nil -> {:error, {:system_not_in_lock, name}}
    end
  end

  # Every public `nerves_system_*` release the lock holds but the Buildroot
  # base every system depends on.
  defp systems(entries) do
    for {app, %{source: :hex, repo: "hexpm", hex: hex, version: version}} <- entries,
        String.starts_with?(app, "nerves_system_"),
        hex == app and app != "nerves_system_br",
        do: {app, version}
  end

  # A system entry's own `nerves` requirement, nil without one.
  defp nerves(%{deps: deps}) do
    case Enum.find(deps, &(&1.app == "nerves")) do
      %{requirement: requirement} -> requirement
      nil -> nil
    end
  end

  # The firmware path's context for the lock's system, or the reason every
  # native set is refused (see the moduledoc). `lines` is each system's own
  # `nerves` requirement, which says the release's Nerves line: a Nerves 2
  # release of any major (trellis 0.6.x, x86_64 1.35.x, rpi4 2.x) accepts the
  # worker's Nerves (`Compatibility.Nerves.buildable?/1`), a Nerves 1 era one
  # does not.
  defp firmware({:none, reason}, _lines), do: {:refused, reason, nil}

  defp firmware({name, version} = system, lines) do
    release = "#{name} #{version}"

    cond do
      name not in Portal.Workers.PinnedBuild.firmware_targets() ->
        {:refused, "unsupported_system: " <> name, system}

      not Compatibility.Nerves.buildable?(lines[name]) ->
        {:refused, "unbuildable_system: " <> release, system}

      true ->
        abi(system, release)
    end
  end

  defp abi({name, version} = system, release) do
    toolchain = firmware_toolchain()
    [_elixir, otp_major] = String.split(toolchain, "/")

    case abi_otp(name, version) do
      nil ->
        {:refused, "system_abi_unknown: " <> release, system}

      otp ->
        if hd(String.split(otp, ".")) == otp_major,
          do:
            {:ok, %{path: :firmware, target: name, system_version: version, toolchain: toolchain},
             system},
          else: {:refused, "system_otp: #{release} (OTP #{otp})", system}
    end
  end

  defp abi_otp(name, version) do
    Portal.Catalog.SystemAbi
    |> Ash.Query.filter(system_pkg == ^name and version == ^version)
    |> Ash.Query.select([:otp])
    |> Ash.read_one!(domain: Portal.Catalog)
    |> case do
      %{otp: otp} when is_binary(otp) -> otp
      _ -> nil
    end
  end

  # A count, or the call is refused: `length(queue) < cap` holds for every
  # integer against `nil` or a string, which would lift the bound.
  defp cap(cap) when is_integer(cap) and cap >= 0, do: {:ok, cap}
  defp cap(cap), do: {:error, {:invalid_cap, cap}}

  defp deterministic(false), do: {:ok, nil}
  defp deterministic(true), do: {:ok, true}
  defp deterministic(value), do: {:error, {:invalid_deterministic, value}}

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

      app in markers or entry.hex in markers or String.starts_with?(entry.hex, "nerves")
    end)
  end

  defp decide(sets, refused, ctx, opts) do
    dry_run = Keyword.get(opts, :dry_run, true)
    hex = Keyword.get(opts, :hex, Portal.HexDeps)
    queue_for = Portal.Toolchains.MemoryRouting.router(Enum.map(sets, & &1.package))

    {queue, skipped} =
      Enum.reduce(sets, {[], []}, fn set, {queue, skipped} ->
        case verdict(set, ctx, hex, length(queue) < ctx.cap) do
          {:queue, path, need} -> {[{set, path, need} | queue], skipped}
          reason -> {queue, [skip(set, reason) | skipped]}
        end
      end)

    queue = Enum.reverse(queue)
    {queued, conflicts} = if dry_run, do: {queue, []}, else: insert(queue, queue_for)
    skipped = Enum.reverse(skipped) ++ conflicts ++ refused

    %{
      dry_run: dry_run,
      target: ctx.pure.target,
      toolchain: ctx.pure.toolchain,
      system: system_summary(ctx.firmware),
      queue: Enum.map(queued, &summary(&1, ctx.deterministic)),
      skipped: skipped,
      counts:
        skipped
        |> Enum.frequencies_by(&(&1.reason |> String.split(":") |> hd()))
        |> Map.put("queue", length(queued))
    }
    |> put_deterministic(queued, ctx.deterministic)
  end

  # Only with `deterministic: true`, so a call without it reports what it
  # always did: whether the setting held sets to their siblings, and how
  # many were queued for a sibling alone.
  defp put_deterministic(report, _queued, nil), do: report

  defp put_deterministic(report, queued, held?) do
    report
    |> Map.put(:deterministic, held?)
    |> put_in([:counts, "no_sibling"], Enum.count(queued, &match?({_, _, :no_sibling}, &1)))
  end

  defp system_summary({:ok, _path, {name, version}}),
    do: %{name: name, version: version, refused: nil}

  defp system_summary({:refused, reason, system}) do
    {name, version} = system || {nil, nil}
    %{name: name, version: version, refused: reason}
  end

  # A native set takes the firmware path, or its refusal; every check
  # after that is the path's own.
  defp verdict(%{native: true} = set, %{firmware: {:ok, path, _system}} = ctx, hex, room?),
    do: path_verdict(set, path, ctx.deterministic == true, hex, room?)

  defp verdict(%{native: true}, %{firmware: {:refused, reason, _system}}, _hex, _room?),
    do: reason

  defp verdict(set, ctx, hex, room?),
    do: path_verdict(set, ctx.pure, ctx.deterministic == true, hex, room?)

  defp path_verdict(set, path, siblings?, hex, room?) do
    case need(set, path, siblings?) do
      {:skip, reason} -> reason
      need -> queue_verdict(set, path, need, hex, room?)
    end
  end

  # A set that needs a build: its job still queued, the cap, the registry.
  defp queue_verdict(set, path, need, hex, room?) do
    cond do
      queued?(set, path) -> "queued_dup"
      not room? -> "cap"
      true -> with(:queue <- registry(set, hex), do: {:queue, path, need})
    end
  end

  # Whether the set needs a build: `{:skip, "judged" | "served"}`, else
  # `:unserved`, or, holding sets to their siblings, `:no_sibling` for a
  # closure served without a listed sibling (see the moduledoc).
  defp need(set, path, false) do
    cond do
      match?(%{verdict?: true}, pinned_row(set, path)) -> {:skip, "judged"}
      served?(set, path) -> {:skip, "served"}
      true -> :unserved
    end
  end

  defp need(set, path, true) do
    case pinned_row(set, path) do
      %{verdict?: true, bare?: true} -> sibling(set, path, "judged", false)
      %{verdict?: true} -> {:skip, "judged"}
      row -> if served?(set, path), do: served_sibling(set, path, row), else: :unserved
    end
  end

  # A closure served by a regular build: an `error` row of its key that
  # records a sibling attempt is that backfill's own row.
  defp served_sibling(set, path, row),
    do: sibling(set, path, "served", match?(%{attempted?: true}, row))

  defp sibling(set, path, served_as, attempted?) do
    cond do
      sibling_listed?(set, path) -> {:skip, served_as}
      attempted? -> {:skip, "judged"}
      sibling_revoked?(set) -> {:skip, "sibling_revoked"}
      true -> :no_sibling
    end
  end

  defp skip(set, reason), do: %{package: set.package, version: set.version, reason: reason}

  defp summary({set, path, need}, deterministic) do
    entry = %{
      package: set.package,
      version: set.version,
      target: path.target,
      system_version: path.system_version,
      pin_hash: set.pins["hash"],
      deps: length(set.pins["deps"])
    }

    if deterministic == nil, do: entry, else: Map.put(entry, :no_sibling, need == :no_sibling)
  end

  defp args(set, path) do
    %{
      "package" => set.package,
      "version" => set.version,
      "toolchain" => path.toolchain,
      "builder_version" => Portal.Toolchains.builder_version(),
      "target" => path.target,
      "pin_hash" => set.pins["hash"],
      "pins" => set.pins
    }
    |> put_path(path)
  end

  # The toolchain path names its image; the firmware path its release, and
  # its build host its own worker image.
  defp put_path(args, %{path: :toolchain, image: image}), do: Map.put(args, "image", image)

  defp put_path(args, %{path: :firmware, system_version: version}),
    do: Map.put(args, "system_version", version)

  defp insert(queue, queue_for) do
    Enum.reduce(queue, {[], []}, fn {set, path, need} = item, {queued, conflicts} ->
      set
      |> args(path)
      |> put_backfill(need)
      |> Portal.Workers.PinnedBuild.new(priority: @priority, queue: queue(path, set, queue_for))
      |> insert_job(need)
      |> case do
        {:ok, %Oban.Job{conflict?: true}} -> {queued, [skip(set, "queued_dup") | conflicts]}
        {:ok, _job} -> {[item | queued], conflicts}
        {:error, error} -> {queued, [skip(set, "insert_failed: " <> inspect(error)) | conflicts]}
      end
    end)
    |> then(fn {queued, conflicts} -> {Enum.reverse(queued), Enum.reverse(conflicts)} end)
  end

  # A set queued only for its missing sibling is a sibling backfill: its
  # rebuild replaces the key's row only with a pass whose sibling held
  # (`Portal.Workers.PinnedBuild`).
  defp put_backfill(args, :no_sibling), do: Map.put(args, "sibling_backfill", true)
  defp put_backfill(args, _need), do: args

  # A backfill's job and the attempt on its key's row, in one transaction:
  # the attempt holds whether the rebuild ever ingests or not, and whatever
  # release ingests it (`Portal.Catalog.PinnedBuild`'s upsert never lowers
  # it). A conflict marks nothing: the key's job already queued is not this
  # one.
  defp insert_job(changeset, :no_sibling) do
    Portal.Repo.transaction(fn ->
      case Oban.insert(changeset) do
        {:ok, %Oban.Job{conflict?: true} = job} -> job
        {:ok, job} -> mark_attempted(job)
        {:error, error} -> Portal.Repo.rollback(error)
      end
    end)
  end

  defp insert_job(changeset, _need), do: Oban.insert(changeset)

  # Under the key's lock, as every write of a pinned row; a key without a
  # row has nothing to mark, and its rebuild writes its verdict with the
  # attempt.
  defp mark_attempted(%Oban.Job{args: args} = job) do
    identity = Portal.Workers.PinnedBuild.identity(args)
    :ok = Portal.Catalog.Ingestion.lock_pinned_identity(identity)

    with %{id: package_id} <- package(args["package"]),
         {:error, error} <- Portal.Catalog.Ingestion.backfill_attempted(package_id, identity) do
      Portal.Repo.rollback(error)
    else
      _marked -> job
    end
  end

  defp package(name) do
    Portal.Catalog.Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.Query.select([:id])
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  defp queue(%{path: :firmware}, _set, _queue_for), do: :builds
  defp queue(%{path: :toolchain}, set, queue_for), do: queue_for.(set.package)

  # The key's pinned build row: whether it is a verdict (anything but an
  # `error`), a served pass whose sibling was never tried for (no attempt
  # recorded, and no sibling row of its own, revoked or not: a row written
  # before attempts were recorded may own one), and whether it records a
  # sibling attempt.
  @pinned_row_sql """
  SELECT pb.status <> 'error',
         pb.status = 'pass' AND pb.revoked_at IS NULL AND pb.unpublished_at IS NULL
           AND NOT pb.sibling_attempted
           AND NOT EXISTS (SELECT 1 FROM catalog_deterministic_builds d
                           WHERE d.pinned_build_id = pb.id),
         pb.sibling_attempted
  FROM catalog_pinned_builds pb
  JOIN catalog_packages p ON p.id = pb.package_id
  WHERE p.name = $1 AND pb.version = $2 AND pb.pin_hash = $3 AND pb.target = $4
    AND pb.system_version = $7 AND pb.toolchain = $5 AND pb.builder_version = $6
    AND pb.config_variant = 'default'
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

  # A regular firmware build of the version for the target at the release,
  # passing and served (an unrevoked run and, for a carried result, the run
  # that built it; built here or by an enrolled, publishing builder), of a
  # run on the firmware toolchain, whose own lock (else its run's) or a
  # published variant's serves exactly this closure.
  @served_target_sql """
  SELECT 1 FROM catalog_system_results s
  JOIN catalog_runs r ON r.id = s.run_id
  JOIN catalog_packages p ON p.id = r.package_id
  LEFT JOIN catalog_runs b ON b.id = s.carried_from_run_id
  CROSS JOIN LATERAL (
    SELECT CASE WHEN s.carried_from_run_id IS NULL THEN r.toolchain ELSE b.toolchain END AS tc,
           CASE WHEN s.carried_from_run_id IS NULL THEN r.builder_id ELSE b.builder_id END AS bid,
           coalesce(s.deps_lock,
                    CASE WHEN s.carried_from_run_id IS NULL THEN r.deps_lock ELSE b.deps_lock END)
             AS lock
  ) x
  WHERE p.name = $1 AND r.version_tested = $2 AND s.system_pkg = $3 AND s.system_version = $4
    AND s.status = 'pass' AND s.unpublished_at IS NULL AND r.revoked_at IS NULL
    AND (s.carried_from_run_id IS NULL OR b.revoked_at IS NULL)
    AND (x.bid IS NULL
         OR EXISTS (SELECT 1 FROM builders bb
                    WHERE bb.id = x.bid AND bb.publishing AND bb.status = 'enrolled'))
    AND split_part(x.tc->>'elixir', '.', 1) || '.' || split_part(x.tc->>'elixir', '.', 2) ||
          '/' || split_part(x.tc->>'erlang', '.', 1) = $6
    AND (x.lock = $5::jsonb
         OR EXISTS (SELECT 1 FROM unnest(coalesce(s.published_variants, '{}')) AS v
                    WHERE v->'deps_lock' = $5::jsonb))
  LIMIT 1
  """

  # A revoked sibling (`Portal.Precompiled.DeterministicRevocation`) of the
  # version built over exactly this closure, by any owner: a toolchain or
  # pinned build's own lock, a system result's own lock or else its run's.
  @sibling_revoked_sql """
  SELECT 1 FROM catalog_deterministic_builds d
  JOIN catalog_packages p ON p.id = d.package_id
  LEFT JOIN catalog_toolchain_builds t ON t.id = d.toolchain_build_id
  LEFT JOIN catalog_pinned_builds pb ON pb.id = d.pinned_build_id
  LEFT JOIN catalog_system_results s ON s.id = d.system_result_id
  LEFT JOIN catalog_runs r ON r.id = s.run_id
  WHERE p.name = $1 AND d.version = $2 AND d.revoked_at IS NOT NULL
    AND coalesce(t.deps_lock, pb.deps_lock, s.deps_lock, r.deps_lock) = $3::jsonb
  LIMIT 1
  """

  @queued_sql """
  SELECT 1 FROM oban_jobs
  WHERE worker = 'Portal.Workers.PinnedBuild' AND state::text = ANY($1::text[]) AND args @> $2::jsonb
  LIMIT 1
  """

  # The key's row as `%{verdict?, bare?, attempted?}` (`bare?` a served pass
  # whose run never tried for a sibling, `Portal.Catalog.PinnedBuild`'s
  # `sibling_attempted`), `nil` without one.
  defp pinned_row(set, path) do
    params = [
      set.package,
      set.version,
      set.pins["hash"],
      path.target,
      path.toolchain,
      Portal.Toolchains.builder_version(),
      path.system_version
    ]

    case Portal.Repo.query!(@pinned_row_sql, params).rows do
      [] ->
        nil

      [[verdict?, bare?, attempted?]] ->
        %{verdict?: verdict?, bare?: bare?, attempted?: attempted?}
    end
  end

  defp served?(set, path) do
    lock = Set.to_lock(set.pins["deps"])

    Portal.Repo.query!(@served_sql, [set.package, set.version, path.toolchain, lock]).rows != [] or
      served_target?(set, path, lock)
  end

  defp served_target?(_set, %{path: :toolchain}, _lock), do: false

  defp served_target?(set, path, lock) do
    params = [set.package, set.version, path.target, path.system_version, lock, path.toolchain]
    Portal.Repo.query!(@served_target_sql, params).rows != []
  end

  # Whether the format-2 manifest lists a deterministic sibling of exactly
  # this closure (`Portal.Catalog.precompiled_manifest_v2/1`, under the
  # version's `deterministic` key): the manifest's own selection, so a
  # sibling the setting, a revocation, a withdrawal of its build, a withheld
  # closure or a missing file keeps out, or a firmware one beside a build
  # that lost its key (`Portal.Deterministic`), is none here either. A
  # toolchain build's sibling serves either path, as its build does
  # (`@served_sql`); a firmware target's only its own target and release.
  # The default config variant only, as `@served_sql`'s.
  defp sibling_listed?(set, path) do
    lock = Set.to_lock(set.pins["deps"])

    case Portal.Catalog.precompiled_manifest_v2(set.package) do
      %{"versions" => %{} = versions} ->
        lists = get_in(versions, [set.version, "deterministic"]) || %{}

        ~w(builds builds_with_inputs builds_closure)
        |> Enum.flat_map(&List.wrap(lists[&1]))
        |> Enum.any?(&sibling_of?(&1, path, lock))

      _ ->
        false
    end
  end

  defp sibling_of?(%{"target" => target, "build" => %{} = build}, path, lock) do
    build["deps"] == lock and build["config_variant"] in [nil, "default"] and
      Portal.Toolchains.from_versions(build["elixir"], build["otp"]) == path.toolchain and
      at_target?(target, build, path)
  end

  defp sibling_of?(_entry, _path, _lock), do: false

  defp at_target?("pure_elixir", _build, _path), do: true

  defp at_target?(target, build, %{path: :firmware, target: target} = path),
    do: build["system_version"] == path.system_version

  defp at_target?(_target, _build, _path), do: false

  # A revoked sibling stays withdrawn: its closure is never built again for
  # one, on any path.
  defp sibling_revoked?(set) do
    params = [set.package, set.version, Set.to_lock(set.pins["deps"])]
    Portal.Repo.query!(@sibling_revoked_sql, params).rows != []
  end

  defp queued?(set, path) do
    keys = ["package", "version", "pin_hash", "target", "toolchain", "builder_version"]
    keys = if path.path == :firmware, do: ["system_version" | keys], else: keys
    key = set |> args(path) |> Map.take(keys)

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
