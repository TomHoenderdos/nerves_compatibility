defmodule Portal.Catalog.ModuleIndex do
  @moduledoc """
  Which popular Hex packages define a module (otp-probe round 3, R2-1), and
  the ingest refusal it backs.

  The worker's judge passes a package's compile-time probe of a module that
  only a declared, optional and absent dependency defines
  (`NccWorker.Portability.Declared`): a user with that dependency has
  another closure, so the client never serves them the build. It cannot
  tell whether another package, which nothing in the build declares,
  defines the same module: a user with that one has the build's closure and
  finds the module, and their compile differs (bitcrowd_ecto's `Money`,
  declared from ex_money, also defined by money). So the judge records each
  such probe (`compile_observations.declared_absent`: the module, the
  declared packages that define it, how it was asked), and ingest refuses
  the build when this index shows another package with at least
  `min_recent/0` recent downloads defining the module, unless the lock holds
  it or the probe's record names it as declared (`refusal/2`).

  The index lives here, not in the worker, because:

    * it needs Hex-wide data the worker does not have: every popular
      package's modules, and the download counts `catalog_packages` keeps
      (refreshed weekly by `Portal.Workers.HexMetaRefresh`);
    * ingest is the one place every build passes through, local and remote
      alike, so the decision is the same whichever builder ran the build,
      and needs no builder protocol change;
    * the recorded probes stay on the row, so the same index can re-check
      served rows when it changes, and client 0.9 can check them itself.

  The index is the latest release of each package with
  `hex_downloads_recent >= min_recent/0`, its tarball checked against the
  registry's outer checksum before its modules are read
  (`Compatibility.HexModules`), refreshed weekly
  (`Portal.Workers.ModuleIndexRefresh`). Until the first refresh has
  indexed anything (`built?/0`), every recorded declared-absent probe
  refuses, as round 1's rule did: no build passes on an empty index.
  """

  alias Portal.Repo

  @min_recent 1_000
  @max_concurrency 4
  @package_timeout_ms 120_000

  @doc "The recent-download count from which another package defining a probed module refuses."
  @spec min_recent() :: pos_integer()
  def min_recent, do: @min_recent

  @doc "Whether the index has indexed any package."
  @spec built?() :: boolean()
  def built? do
    %{rows: [[built]]} =
      Repo.query!("SELECT EXISTS (SELECT 1 FROM catalog_module_index_packages)", [])

    built
  end

  @doc "The indexed packages that define `module`, sorted."
  @spec definers(String.t()) :: [String.t()]
  def definers(module) when is_binary(module) do
    %{rows: rows} =
      Repo.query!(
        "SELECT package FROM catalog_module_definers WHERE module = $1 ORDER BY package",
        [module]
      )

    List.flatten(rows)
  end

  @doc """
  The refusal of a build whose judge recorded `items` (its
  `compile_observations.declared_absent`) and whose lock names `locked`
  (package names), or `nil`. A module item refuses when an indexed package
  with at least `min_recent/0` recent downloads defines the module and
  neither the item's `declared` packages nor `locked` name it; any item
  when the index is not built; a `truncated` item always.
  """
  @spec refusal([map()] | nil, [String.t()]) :: String.t() | nil
  def refusal(items, locked) when is_list(items) and items != [] do
    built = built?()
    Enum.find_value(items, &item_refusal(&1, MapSet.new(locked), built))
  end

  def refusal(_items, _locked), do: nil

  defp item_refusal(%{"kind" => "truncated"}, _locked, _built),
    do: Compatibility.Portability.dependency_probe() <> "too many declared-absent probes recorded"

  defp item_refusal(%{"kind" => "module_absent", "module" => module} = item, locked, built)
       when is_binary(module) do
    via = if is_binary(item["via"]), do: item["via"], else: "a probe"
    declared = MapSet.new(List.wrap(item["declared"]))

    others =
      if built,
        do:
          Enum.reject(
            popular_definers(module),
            &(MapSet.member?(declared, &1) or MapSet.member?(locked, &1))
          ),
        else: :not_built

    case others do
      :not_built -> reason(module, via, "module index not built")
      [] -> nil
      others -> reason(module, via, "also defined by " <> Enum.join(others, ", "))
    end
  end

  defp item_refusal(_item, _locked, _built),
    do: Compatibility.Portability.dependency_probe() <> "unreadable declared-absent probe record"

  defp reason(module, via, why),
    do: Compatibility.Portability.dependency_probe() <> "#{module} via #{via} (#{why})"

  defp popular_definers(module) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT d.package FROM catalog_module_definers d
        JOIN catalog_packages p ON p.name = d.package
        WHERE d.module = $1 AND coalesce(p.hex_downloads_recent, 0) >= $2
        ORDER BY d.package
        """,
        [module, @min_recent]
      )

    List.flatten(rows)
  end

  @doc """
  Reads the latest release of every package with at least `min_recent/0`
  recent downloads whose indexed release is another one, and replaces its
  modules. A tarball that cannot be fetched, or does not hash to the
  registry's outer checksum, leaves the package as it was, to be tried again
  by the next run.

  Safe to start by hand on a host short on memory (round 4):

    * `dry_run: true` reads nothing from Hex and writes nothing: it returns
      `%{to_fetch, unchanged, below_threshold}`;
    * at most `max_concurrency/0` (4) packages are fetched and parsed at
      once (`:concurrency` may lower it, never raise it), each with its
      tarball in memory only while it is read (at most
      `Compatibility.StaticPriv.max_tarball_bytes/0`, parsed under
      `Compatibility.HexModules`' caps), and killed after 2 minutes;
    * each package is stored in a transaction of its own as soon as it is
      read, most downloaded first, so a run that is stopped or restarted
      keeps what it stored and the next run fetches only the rest.

  Options: `:tarball` and `:outer_checksum` (`fn name, version -> {:ok,
  value} | {:error, why} end`, default `Portal.HexDeps`), `:limit`,
  `:concurrency`, `:dry_run`.
  """
  @spec refresh(keyword()) :: %{atom() => non_neg_integer()}
  def refresh(opts \\ []) do
    rows = candidates(Keyword.get(opts, :limit, 100_000))

    {todo, unchanged} =
      Enum.split_with(rows, fn [_name, version, indexed] -> version != indexed end)

    if Keyword.get(opts, :dry_run, false) do
      %{to_fetch: length(todo), unchanged: length(unchanged), below_threshold: below_threshold()}
    else
      fetch_all(todo, length(unchanged), opts)
    end
  end

  @doc "The most packages `refresh/1` fetches and parses at once."
  @spec max_concurrency() :: pos_integer()
  def max_concurrency, do: @max_concurrency

  defp fetch_all(todo, unchanged, opts) do
    tarball = Keyword.get(opts, :tarball, &Portal.HexDeps.tarball/2)
    checksum = Keyword.get(opts, :outer_checksum, &Portal.HexDeps.outer_checksum/2)

    concurrency =
      opts |> Keyword.get(:concurrency, @max_concurrency) |> min(@max_concurrency) |> max(1)

    todo
    |> Task.async_stream(
      fn [name, version, _] -> index_release(name, version, tarball, checksum) end,
      max_concurrency: concurrency,
      timeout: @package_timeout_ms,
      on_timeout: :kill_task,
      ordered: false
    )
    |> Enum.reduce(%{indexed: 0, unchanged: unchanged, failed: 0}, fn
      {:ok, :ok}, acc -> Map.update!(acc, :indexed, &(&1 + 1))
      _other, acc -> Map.update!(acc, :failed, &(&1 + 1))
    end)
  end

  defp candidates(limit) do
    %{rows: rows} =
      Repo.query!(
        """
        SELECT p.name, p.hex_latest_version, i.version
        FROM catalog_packages p
        LEFT JOIN catalog_module_index_packages i ON i.package = p.name
        WHERE coalesce(p.hex_downloads_recent, 0) >= $1 AND p.hex_latest_version IS NOT NULL
        ORDER BY p.hex_downloads_recent DESC, p.name
        LIMIT $2
        """,
        [@min_recent, limit]
      )

    rows
  end

  defp below_threshold do
    %{rows: [[n]]} =
      Repo.query!(
        """
        SELECT count(*) FROM catalog_packages
        WHERE coalesce(hex_downloads_recent, 0) < $1 AND hex_latest_version IS NOT NULL
        """,
        [@min_recent]
      )

    n
  end

  defp index_release(name, version, tarball, checksum) do
    with {:ok, bytes} <- tarball.(name, version),
         {:ok, sum} <- checksum.(name, version),
         true <- :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == sum do
      store(name, version, Compatibility.HexModules.modules(bytes))
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp store(name, version, modules) do
    {:ok, :ok} =
      Repo.transaction(fn ->
        Repo.query!("DELETE FROM catalog_module_definers WHERE package = $1", [name])

        modules
        |> Enum.chunk_every(5_000)
        |> Enum.each(fn chunk ->
          Repo.insert_all(
            "catalog_module_definers",
            Enum.map(chunk, &%{module: &1, package: name}),
            on_conflict: :nothing
          )
        end)

        Repo.query!(
          """
          INSERT INTO catalog_module_index_packages (package, version, modules, refreshed_at)
          VALUES ($1, $2, $3, now())
          ON CONFLICT (package) DO UPDATE
          SET version = EXCLUDED.version, modules = EXCLUDED.modules, refreshed_at = now()
          """,
          [name, version, length(modules)]
        )

        :ok
      end)

    :ok
  end
end
