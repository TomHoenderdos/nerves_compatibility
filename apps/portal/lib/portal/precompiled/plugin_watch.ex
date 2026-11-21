defmodule Portal.Precompiled.PluginWatch do
  @moduledoc """
  Serves a build that ran a rebar3 plugin only while every release Hex has
  of that plugin package, and of each plugin dependency the build ran, was
  reviewed (`Compatibility.RebarPlugins.reviewed?/2`; review S5 S1).

  ## Why

  rebar3 installs a dependency's `plugins` from Hex at whatever release its
  own registry cache resolves, with their dependencies, and no lock names
  them. The worker lets a build run only a pinned release
  (`NccWorker.Portability.RebarPlugins`), which guards our build. A user who
  compiles from source runs whatever release their rebar3 resolves: when a
  plugin publishes a release nobody reviewed, which could change what a
  compile produces, a build made with a reviewed one may no longer be what
  that user compiles. Such builds are withheld until the release is reviewed
  and pinned.

  ## How

    * Every build records the plugin releases it ran
      (`compile_observations.rebar3_plugins`); ingest copies them by run id
      into `rebar3_plugin_runs` (`record/2`), so an earlier build kept on a
      row is found by its own run, and a truncated observation map loses
      nothing.
    * `Portal.Workers.UpdateCheck` reads the whole registry every hour and
      writes, for each reviewed package, the releases Hex has that the review
      does not cover into `rebar3_plugin_watch` (`refresh/1`): any such
      release, the newest, a prerelease or a backport alike. A package the
      registry read does not list keeps what it had.
    * Every selector of published files leaves out a toolchain, pinned or
      host-native build whose run ran a watched package (`served_clause/1` in
      SQL, `withheld_runs/1` in Elixir), and the watch is part of every
      manifest fingerprint (`fingerprint_sql/0`), so a change renders the
      batch again. Deterministic siblings are served only beside their build.

  Reviewing a new release: the S5 design note's "Reviewing a new plugin
  release". Once a release that adds it to `Compatibility.RebarPlugins`
  deploys, the next update check clears the watch and the builds are served
  again; nothing is rebuilt.

  A build made before builds recorded their plugins records none, so the
  watch cannot see it: such a build ran at most a `rebar3_hex` release
  (the only plugin the judge let through before).
  """

  require Logger

  alias Compatibility.RebarPlugins

  @name ~r/\A[a-z][a-z0-9_]{0,63}\z/
  @version ~r/\A[0-9A-Za-z][0-9A-Za-z.+-]{0,63}\z/
  @sha ~r/\A[0-9a-f]{64}\z/
  # The worker's bound (`NccWorker.Portability.RebarPlugins.max_releases/0`).
  @max_releases 64
  # The record of a run that ran plugin releases this cannot list: withheld
  # whatever the watch holds (`served_clause/1`).
  @unrecorded {"*", "unrecorded", nil}

  @doc "The most distinct plugin releases one run's record holds."
  @spec max_releases() :: pos_integer()
  def max_releases, do: @max_releases

  @doc """
  Records the plugin releases run `run_id` ran, from its build's
  `compile_observations` (`"rebar3_plugins"`: `%{"name", "version",
  "sha256"}` each). Deduplicated first and never cut (review S5 R3): a
  record of more than `max_releases/0` releases, or one with any malformed
  entry, records the withholding mark instead, `*`, which no watch state
  serves. Observations without the key record nothing (a build from before
  the record). Idempotent.
  """
  @spec record(String.t() | nil, term()) :: :ok
  def record(run_id, %{"rebar3_plugins" => plugins}) when is_binary(run_id) and run_id != "" do
    Enum.each(releases(plugins), fn {name, version, sha} ->
      Portal.Repo.query!(
        "INSERT INTO rebar3_plugin_runs (run_id, package, version, sha256) " <>
          "VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING",
        [run_id, name, version, sha]
      )
    end)
  end

  def record(_run_id, _observations), do: :ok

  defp releases(plugins) when is_list(plugins) do
    parsed = Enum.map(plugins, &release/1)
    unique = parsed |> Enum.reject(&(&1 == :error)) |> Enum.uniq_by(&Tuple.delete_at(&1, 2))

    if :error in parsed or length(unique) > @max_releases, do: [@unrecorded], else: unique
  end

  defp releases(_plugins), do: [@unrecorded]

  defp release(%{"name" => name, "version" => version} = plugin)
       when is_binary(name) and is_binary(version) do
    if Regex.match?(@name, name) and Regex.match?(@version, version),
      do: {name, version, sha(plugin["sha256"])},
      else: :error
  end

  defp release(_plugin), do: :error

  defp sha(sha) when is_binary(sha), do: if(Regex.match?(@sha, sha), do: sha)
  defp sha(_sha), do: nil

  @doc "The plugin releases run `run_id` ran, as `{package, version}`, sorted."
  @spec ran(String.t()) :: [{String.t(), String.t()}]
  def ran(run_id) do
    %{rows: rows} =
      Portal.Repo.query!(
        "SELECT package, version FROM rebar3_plugin_runs WHERE run_id = $1 " <>
          "ORDER BY package, version",
        [run_id]
      )

    Enum.map(rows, &List.to_tuple/1)
  end

  @doc """
  Writes the watch from `registry` (`Portal.HexRegistry.snapshot/1` with
  `all_versions: true`): for each reviewed package the registry lists, the
  releases outside the review, or no row when there are none. A package it
  does not list keeps its row. Returns the watch as it is then:
  `%{package => [version]}`.
  """
  @spec refresh([map()]) :: %{String.t() => [String.t()]}
  def refresh(registry) do
    by_name = Map.new(registry, &{&1.name, &1})
    now = DateTime.utc_now()

    Portal.Repo.transaction(fn ->
      for package <- RebarPlugins.packages(), entry = by_name[package], entry != nil do
        versions = Map.get(entry, :versions) || [entry.latest_version]
        unreviewed = versions |> Enum.reject(&RebarPlugins.reviewed?(package, &1)) |> Enum.uniq()
        write(package, Enum.sort(unreviewed), now)
      end
    end)

    watched = watched()

    if watched != %{} do
      Logger.warning(
        "rebar3 plugin releases not reviewed, builds that ran them are withheld: " <>
          Enum.map_join(watched, "; ", fn {p, vs} -> "#{p} #{Enum.join(vs, ", ")}" end)
      )
    end

    watched
  end

  defp write(package, [], _now),
    do: Portal.Repo.query!("DELETE FROM rebar3_plugin_watch WHERE package = $1", [package])

  defp write(package, unreviewed, now) do
    Portal.Repo.query!(
      "INSERT INTO rebar3_plugin_watch (package, unreviewed, checked_at) " <>
        "VALUES ($1, $2, $3) ON CONFLICT (package) DO UPDATE " <>
        "SET unreviewed = EXCLUDED.unreviewed, checked_at = EXCLUDED.checked_at",
      [package, unreviewed, now]
    )
  end

  @doc "The watch: `%{package => [version]}` of each package with releases outside the review."
  @spec watched() :: %{String.t() => [String.t()]}
  def watched do
    %{rows: rows} =
      Portal.Repo.query!(
        "SELECT package, unreviewed FROM rebar3_plugin_watch ORDER BY package",
        []
      )

    Map.new(rows, fn [package, versions] -> {package, versions} end)
  end

  @doc """
  A subquery of one row and one column, `watch`: the watch as text for the
  manifest fingerprints (`Portal.Catalog.precompiled_fingerprints/0`), NULL
  while nothing is watched, so a fingerprint is then what it was before.
  Literal SQL only.
  """
  @spec fingerprint_sql() :: String.t()
  def fingerprint_sql do
    "SELECT string_agg(package || ':' || array_to_string(unreviewed, ','), ';' " <>
      "ORDER BY package) AS watch FROM rebar3_plugin_watch"
  end

  @doc "The ones of `run_ids` whose run ran a watched package."
  @spec withheld_runs([String.t() | nil]) :: MapSet.t()
  def withheld_runs(run_ids) do
    case Enum.filter(run_ids, &is_binary/1) |> Enum.uniq() do
      [] ->
        MapSet.new()

      ids ->
        %{rows: rows} =
          Portal.Repo.query!(
            "SELECT DISTINCT bp.run_id FROM rebar3_plugin_runs bp " <>
              "WHERE bp.run_id = ANY($1::text[]) AND #{withholds("bp")}",
            [ids]
          )

        MapSet.new(rows, &hd/1)
    end
  end

  @doc """
  The SQL predicate that serves a build whose run id is the expression
  `run_id` only while its run ran no watched package and its record is not
  the withholding mark. Literal SQL only.
  """
  @spec served_clause(String.t()) :: String.t()
  def served_clause(run_id) do
    "NOT EXISTS (SELECT 1 FROM rebar3_plugin_runs bp " <>
      "WHERE bp.run_id = #{run_id} AND #{withholds("bp")})"
  end

  # Whether the record row aliased `bp` withholds its run: the mark, or a
  # watched package.
  defp withholds(bp) do
    "(#{bp}.package = '*' OR EXISTS (SELECT 1 FROM rebar3_plugin_watch pw " <>
      "WHERE pw.package = #{bp}.package))"
  end
end
