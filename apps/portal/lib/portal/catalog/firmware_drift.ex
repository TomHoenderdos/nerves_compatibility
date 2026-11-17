defmodule Portal.Catalog.FirmwareDrift do
  @moduledoc """
  Which firmware targets of a package's latest run a targets rebuild would
  now publish a build for that a client can take, and the run's do not.

  A firmware target build is matched by its lock, as a toolchain build is
  (`Portal.Catalog.ClosureDrift`), and by its system release (client rule 1,
  "another release of your system"). Two things leave a passing target
  behind while nothing about the package changes:

    * **Closure drift.** A dependency of its closure released a version
      every requirement in the closure allows: a fresh `mix deps.get` locks
      it and the build misses for every new project. `ClosureDrift.drift/3`
      judges the target's lock, its own (`SystemResult.deps_lock`) or else
      the lock of the run that built it, exactly as it judges a toolchain
      build's.
    * **A newer system release.** Its system released a newer version in
      the same major (`0.x`: the same minor), which a fresh build resolves,
      and the target's build is not used there: it has native code that is
      not portable, or nothing recorded says what is in it, or it is
      portable but the new release, as the systems table
      (`Portal.Precompiled.SystemAbi.table/0`) describes it, lacks its
      toolchain series, an OTP at least as new, or a library or symbol
      version it needs (`served_on?/2`). A beam-only build is used on any
      release and is never rebuilt for one. While the new release is not
      in the table, or its libraries are not read yet, the client takes
      only exact-release builds, but `Portal.Workers.SystemAbiObserve`
      reads it within the hour, so the target waits rather than rebuilds.

  A third is a one-off: a target built before firmware runs recorded their
  lock has none, and format 2 never lists a build without one, so it serves
  no current client at all. Such a target is rebuilt once (a change naming
  `"*"` as its `dep`, `"unrecorded"` -> `"recorded"`).

  A beam-only target of a version that a passing host build of the same
  Elixir minor and OTP major also serves is left out: a client on a Nerves
  system takes that `pure_elixir` build (rule 1), and the toolchain phase of
  `Portal.Workers.ClosureDrift` keeps it current. On production that leaves
  out about a third of the drifted targets.

  Drift and bumps are judged against the registry, never the clock alone: a
  dependency or system whose registry entry last changed before the target
  was built is not drift, since that build's own resolve saw it. That is
  what keeps a rebuild that comes back with the same lock or release from
  being queued again. `Portal.Workers.ClosureDrift` rebuilds the targets
  `judge/4` names with a targets scope.
  """

  alias Compatibility.Elf
  alias Portal.Catalog.ClosureDrift
  alias Portal.Catalog.ToolchainBuild
  alias Portal.Repo

  # Firmware runs record their lock since a worker release of 2026-10-20,
  # which reached the last build host late on 10-21; no passing run since
  # lacks one. A target built before has none, and format 2 never lists a
  # build without one. After it, a missing lock is one the worker could not
  # read, which a rebuild would not read either.
  @locks_recorded_from ~U[2026-10-22 00:00:00Z]

  @typedoc "One passing target of a run, as `candidates/2` reads it."
  @type target :: %{
          system: String.t(),
          system_version: String.t() | nil,
          native: boolean() | nil,
          portable: boolean() | nil,
          toolchain_pkg: String.t() | nil,
          toolchain_version: String.t() | nil,
          otp_full: String.t() | nil,
          elf_needs: map() | nil,
          deps_lock: map() | nil,
          built_at: DateTime.t() | nil,
          host_served: boolean()
        }

  @typedoc "A package's latest run and its passing firmware targets."
  @type run :: %{
          required(:package) => String.t(),
          required(:version) => String.t(),
          required(:targets) => [target()],
          optional(atom()) => term()
        }

  @doc """
  Whether `run` has targets to rebuild: `{:rebuild, systems, changes}` with
  the target names, sorted, and every reason (`%{"dep", "from", "to"}`, a
  system bump naming the system as its `dep`), sorted by name; `:current`;
  or `{:error, reason}` when no target is to be rebuilt and some target's
  closure could not be read. `index` is `ClosureDrift.index/1`'s, `releases`
  answers like `Portal.HexDeps.releases/1`, and `systems` is the systems
  table.
  """
  @spec judge(run(), %{String.t() => ClosureDrift.package()}, function(), map()) ::
          {:rebuild, [String.t()], [ClosureDrift.change()]} | :current | {:error, term()}
  def judge(%{targets: targets} = run, index, releases, systems) do
    judged =
      for target <- targets,
          not host_served?(target),
          do: {target.system, changes(run, target, index, releases, systems)}

    rebuild = for {system, {:ok, [_ | _] = changes}} <- judged, do: {system, changes}

    case {rebuild, for({_system, {:error, reason}} <- judged, do: reason)} do
      {[], []} ->
        :current

      {[], [reason | _]} ->
        {:error, reason}

      {rebuild, _errors} ->
        changes =
          rebuild |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort_by(& &1["dep"])

        {:rebuild, rebuild |> Enum.map(&elem(&1, 0)) |> Enum.uniq() |> Enum.sort(), changes}
    end
  end

  # A beam-only build of a version a passing host build of the same Elixir
  # minor and OTP major also serves (`pure_elixir`, client rule 1): that
  # build is the one to keep current, and `Portal.Workers.ClosureDrift`
  # rebuilds it with the toolchain builds.
  defp host_served?(target), do: target.native == false and Map.get(target, :host_served) == true

  # A missing lock or a bump alone is enough to rebuild a target whose
  # closure cannot be read: the rebuild resolves the closure afresh anyway.
  defp changes(run, target, index, releases, systems) do
    reasons = unrecorded(target) ++ system_bump(target, index, systems)

    build = %{
      package: run.package,
      version: run.version,
      deps_lock: target.deps_lock,
      built_at: target.built_at
    }

    case ClosureDrift.drift(build, index, releases) do
      {:drift, changes} -> {:ok, reasons ++ changes}
      :current -> {:ok, reasons}
      {:error, _reason} when reasons != [] -> {:ok, reasons}
      {:error, reason} -> {:error, reason}
    end
  end

  defp system_bump(%{system: system, system_version: current} = target, index, systems) do
    with {:ok, current_version} <- parse(current),
         %{versions: versions, updated_at: updated_at} <- Map.get(index, system),
         true <- changed_since?(updated_at, target.built_at),
         [_ | _] = newer <- Enum.filter(versions, &same_series_newer?(&1, current_version)),
         to = newer |> List.last() |> to_string(),
         false <- served_on?(target, get_in(systems, [system, to])) do
      [%{"dep" => system, "from" => current, "to" => to}]
    else
      _ -> []
    end
  end

  defp unrecorded(%{deps_lock: nil, built_at: %DateTime{} = built_at}) do
    if DateTime.before?(built_at, @locks_recorded_from),
      do: [%{"dep" => "*", "from" => "unrecorded", "to" => "recorded"}],
      else: []
  end

  defp unrecorded(_target), do: []

  defp parse(version) when is_binary(version), do: Version.parse(version)
  defp parse(_version), do: :error

  defp changed_since?(nil, _built_at), do: true
  defp changed_since?(_updated_at, nil), do: true
  defp changed_since?(updated_at, built_at), do: DateTime.compare(updated_at, built_at) == :gt

  # What `~>` on the release would allow: the same major, or for 0.x the
  # same minor.
  defp same_series_newer?(%Version{major: 0} = candidate, %Version{major: 0} = current),
    do: candidate.minor == current.minor and Version.compare(candidate, current) == :gt

  defp same_series_newer?(candidate, current),
    do: candidate.major == current.major and Version.compare(candidate, current) == :gt

  # The served passing firmware targets of each package's latest run (the
  # rule `Portal.Workers.Build.latest_version_tested/1` uses), when that run
  # is of the package's newest stable release, and only runs with a target
  # whose lock has a dependency, or whose system, at anything but its
  # newest release, or no lock from before locks were recorded. A carried
  # target was built by the run it was carried from, under that run's lock,
  # toolchain and finish. `host_served` is whether a passing, unrevoked
  # plain toolchain build (`with` or `without`, the default config_variant:
  # what a project with no named config takes) of the version has that
  # toolchain's Elixir minor and OTP major (`"1.20/29"` for Elixir 1.20.3 on
  # OTP 29).
  @candidates_sql """
  WITH newest AS (
    SELECT * FROM unnest($1::text[], $2::text[]) AS n(name, version)
  ), latest AS (
    SELECT DISTINCT ON (r.package_id) r.id, r.package_id, r.version_tested, r.finished_at,
           r.deps_lock, r.revoked_at, r.builder_id, r.toolchain
    FROM catalog_runs r
    ORDER BY r.package_id, r.finished_at DESC, r.inserted_at DESC
  ), served AS (
    SELECT l.id AS run_id, p.name, l.version_tested AS version,
           coalesce(p.hex_downloads_recent, 0) AS downloads,
           s.system_pkg, s.system_version, s.native, s.portable, s.toolchain_pkg,
           s.toolchain_version, s.otp_full, s.elf_needs,
           coalesce(s.deps_lock,
                    CASE WHEN s.carried_from_run_id IS NULL THEN l.deps_lock ELSE b.deps_lock END)
             AS deps_lock,
           CASE WHEN s.carried_from_run_id IS NULL THEN l.finished_at ELSE b.finished_at END
             AS built_at,
           EXISTS (
             SELECT 1 FROM catalog_toolchain_builds t
             WHERE t.package_id = l.package_id AND t.version = l.version_tested
               AND t.status = 'pass' AND t.revoked_at IS NULL
               AND t.variant IN #{ToolchainBuild.optional_deps_variants_sql()}
               AND t.config_variant = 'default'
               AND t.toolchain = split_part(tc.elixir, '.', 1) || '.' ||
                                 split_part(tc.elixir, '.', 2) || '/' || tc.otp
           ) AS host_served
    FROM latest l
    JOIN catalog_packages p ON p.id = l.package_id
    JOIN newest n ON n.name = p.name AND n.version = l.version_tested
    JOIN catalog_system_results s ON s.run_id = l.id
    LEFT JOIN catalog_runs b ON b.id = s.carried_from_run_id
    CROSS JOIN LATERAL (
      SELECT coalesce(b.toolchain, l.toolchain)->>'elixir' AS elixir,
             coalesce(b.toolchain, l.toolchain)->>'erlang' AS otp
    ) tc
    LEFT JOIN builders rb ON rb.id = l.builder_id
    LEFT JOIN builders bb ON bb.id = b.builder_id
    WHERE l.revoked_at IS NULL
      AND s.status = 'pass' AND s.unpublished_at IS NULL
      AND s.system_pkg = ANY($3::text[])
      AND (s.carried_from_run_id IS NULL OR b.revoked_at IS NULL)
      AND (l.builder_id IS NULL OR (rb.publishing AND rb.status = 'enrolled'))
      AND (s.carried_from_run_id IS NULL OR b.builder_id IS NULL
           OR (bb.publishing AND bb.status = 'enrolled'))
  ), behind AS (
    SELECT DISTINCT s.run_id, s.name, s.downloads
    FROM served s
    WHERE (EXISTS (SELECT 1 FROM newest n
                   WHERE n.name = s.system_pkg AND n.version IS DISTINCT FROM s.system_version)
           OR (jsonb_typeof(s.deps_lock) = 'object'
               AND EXISTS (SELECT 1 FROM jsonb_each(s.deps_lock) d
                           JOIN newest n ON n.name = d.key
                           WHERE d.value->>'version' IS DISTINCT FROM n.version))
           OR (s.deps_lock IS NULL AND s.built_at < $5))
      AND ($6::bigint IS NULL OR s.downloads < $6
           OR (s.downloads = $6 AND s.name > $7::text))
    ORDER BY s.downloads DESC, s.name
    LIMIT $4
  )
  SELECT s.run_id, s.name, s.version, b.downloads, s.system_pkg, s.system_version, s.native,
         s.portable, s.toolchain_pkg, s.toolchain_version, s.otp_full, s.elf_needs, s.deps_lock,
         s.built_at, s.host_served
  FROM served s
  JOIN behind b ON b.run_id = s.run_id
  ORDER BY b.downloads DESC, b.name, s.system_pkg
  """

  @doc """
  The runs `judge/4` may find targets to rebuild in, most downloaded
  package first, at most `:limit` runs: each package's latest run, when it
  is of the newest stable release in `index`, with its served passing
  targets on one of `:systems`, for runs where some such target locks a
  dependency, or is on a release of its system, that is not the newest, or
  has no lock from before locks were recorded. Each is `%{run_id, package,
  version, downloads, targets}`.

  That filter only says a run may have drifted, and most runs pass it for
  good (a beam-only target on an older release, a dependency a requirement
  holds back), so one page can hold only current runs, day after day. The
  next page starts after `:after`, the `cursor/1` of the last run of the
  previous one.
  """
  @spec candidates(%{String.t() => ClosureDrift.package()}, keyword()) :: [run()]
  def candidates(index, opts) do
    {names, versions} =
      index
      |> Enum.flat_map(fn {name, %{newest: newest}} ->
        if newest, do: [{name, newest}], else: []
      end)
      |> Enum.unzip()

    {after_downloads, after_name} = Keyword.get(opts, :after) || {nil, nil}

    %{rows: rows} =
      Repo.query!(
        @candidates_sql,
        [
          names,
          versions,
          Keyword.fetch!(opts, :systems),
          Keyword.fetch!(opts, :limit),
          DateTime.to_naive(@locks_recorded_from),
          after_downloads,
          after_name
        ],
        timeout: :timer.minutes(2)
      )

    rows
    |> Enum.chunk_by(&hd/1)
    |> Enum.map(fn [[id, name, version, downloads | _] | _] = group ->
      %{
        run_id: Ecto.UUID.cast!(id),
        package: name,
        version: version,
        downloads: downloads,
        targets: Enum.map(group, &target/1)
      }
    end)
  end

  @doc "Where the page after `run`, the last of its page, starts (`candidates/2`'s `:after`)."
  @spec cursor(run()) :: {non_neg_integer(), String.t()}
  def cursor(%{downloads: downloads, package: package}), do: {downloads, package}

  defp target([_id, _name, _version, _downloads, system, system_version | facts]) do
    [
      native,
      portable,
      toolchain_pkg,
      toolchain_version,
      otp_full,
      elf_needs,
      lock,
      built_at,
      host
    ] =
      facts

    %{
      system: system,
      system_version: system_version,
      native: native,
      portable: portable,
      toolchain_pkg: toolchain_pkg,
      toolchain_version: toolchain_version,
      otp_full: otp_full,
      elf_needs: elf_needs,
      deps_lock: lock,
      built_at: utc(built_at),
      host_served: host
    }
  end

  defp utc(%NaiveDateTime{} = at), do: DateTime.from_naive!(at, "Etc/UTC")
  defp utc(at), do: at

  @doc """
  Whether a client takes `target`'s build on another release of its system,
  the one `entry` (a systems table entry) describes, by rule 1 of its
  matching (`guides/matching.md`): `true`, `false`, or `:unknown` while
  `entry` cannot say. A beam-only build is taken on any release; a native
  one only when it is portable and the release has its toolchain package
  in the same `major.minor` series, the same OTP major at a version no
  older than the build's, and every library and symbol version it needs.
  Anything else (native code that is not portable, or a build with no
  recorded facts) is taken on its own release only.
  """
  @spec served_on?(target(), map() | nil) :: boolean() | :unknown
  def served_on?(%{native: false}, _entry), do: true

  def served_on?(%{native: true, portable: true} = target, %{
        "toolchain" => %{"series" => series} = toolchain,
        "otp" => otp,
        "libs" => libs
      })
      when is_binary(series) and is_binary(otp) and is_map(libs) do
    same_toolchain?(target, toolchain["package"], series) and otp_runs?(target.otp_full, otp) and
      libs_provided?(target.elf_needs, libs)
  end

  def served_on?(%{native: true, portable: true}, _entry), do: :unknown
  def served_on?(_target, _entry), do: false

  defp same_toolchain?(%{toolchain_pkg: package, toolchain_version: version}, release_pkg, series)
       when is_binary(package) and is_binary(version),
       do: package == release_pkg and Elf.series_from_version(version) == series

  defp same_toolchain?(_target, _release_pkg, _series), do: false

  # Part by part, as the client compares them: 29.0.6 code runs on 29.1.2.
  defp otp_runs?(built, release) when is_binary(built) do
    case {otp_parts(built), otp_parts(release)} do
      {[major | _] = b, [major | _] = r} -> b <= r
      _ -> false
    end
  end

  defp otp_runs?(_built, _release), do: false

  defp otp_parts(version) do
    parts = String.split(version, ".")

    if Enum.all?(parts, &(&1 =~ ~r/^\d+$/)),
      do: Enum.map(parts, &String.to_integer/1),
      else: nil
  end

  defp libs_provided?(needs, libs) when is_map(needs) do
    Enum.all?(needs, fn {soname, versions} ->
      case Map.fetch(libs, soname) do
        {:ok, defined} when is_list(defined) and is_list(versions) ->
          Elf.satisfied?(versions, defined) == :ok

        _ ->
          false
      end
    end)
  end

  defp libs_provided?(_needs, _libs), do: false
end
