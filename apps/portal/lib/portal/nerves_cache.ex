defmodule Portal.NervesCache do
  @moduledoc """
  Host-side policy for the shared Nerves cache (isolation spec, section 1).

  Builds mount the cache read-only (`Portal.Builder.nerves_cache_mode/1`) and
  report what they had to extract themselves as `result.json`
  `nerves_cache.misses`, next to their locked Nerves packages
  (`nerves_cache.lock`). That report comes from a container running untrusted
  package code, so what gets warmed is decided here, under limits that do not
  depend on it. `warm_pairs/2` keeps a miss only when:

    * the same report's lock names it (a forged lock still has to pass the
      next two);
    * the Hex user `nerves` owns the package (`Portal.HexPm.owners/2`, cached
      for a day);
    * it was not warmed for this image on this host in the last day;
    * it is among the first four, in lock order (sorted by name, the order Mix
      writes `mix.lock` in).

  A system published by anyone else keeps working through the build's private
  extraction; it is just never cached.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Portal.Repo
  alias Portal.Workers.WarmNerves

  @warm_pairs_per_run 4

  # Distinct misses looked at before any Hex lookup. A real run has at most one
  # system per default target plus their toolchains, about thirteen; the cap
  # only stops a forged report from turning one build into many owner lookups.
  @max_misses_considered 16

  @warm_owner "nerves"
  @pair_name ~r/\Anerves_(system|toolchain)_[a-z0-9_]+\z/

  # Node-local memo of pairs a successful `request_warm/3` has queued, keyed
  # by `{image_digest, name, version}`, so `recently_warmed/2` still bounds
  # repeats once `Oban.Plugins.Pruner` deletes the completed job row it also
  # reads (6 h, `apps/portal/config/config.exs`) -- well inside the day this
  # moduledoc promises.
  @warmed_memo :portal_nerves_cache_warmed
  @warmed_memo_ttl_ms :timer.hours(24)

  @type pair :: %{String.t() => String.t()}

  @doc false
  @spec warm_pairs_per_run() :: pos_integer()
  def warm_pairs_per_run, do: @warm_pairs_per_run

  @doc """
  Creates the node-local ETS table `recently_warmed/2` and `request_warm/3`
  share, the same way `Portal.HexPm.create_package_owners_table/0` does for
  the owners memo. Call once, from `Portal.Application.start/2`.
  """
  @spec create_warmed_table() :: :ok
  def create_warmed_table do
    _ = :ets.new(@warmed_memo, [:named_table, :public, :set, read_concurrency: true])
    :ok
  end

  @doc """
  The pairs worth warming from a build's `result` (see the moduledoc), as
  `%{"name", "version"}` maps sorted by name. `opts[:owners]` replaces the Hex
  owners lookup (default: `config :portal, Portal.NervesCache, owners: fun`,
  then `Portal.HexPm.owners/1`); `opts[:recently_warmed]` is a `MapSet` of
  `{name, version}` to skip.
  """
  @spec warm_pairs(map(), keyword()) :: [pair()]
  def warm_pairs(result, opts \\ []) when is_map(result) do
    owners = Keyword.get_lazy(opts, :owners, &owners_lookup/0)
    recent = Keyword.get(opts, :recently_warmed, MapSet.new())

    case Map.get(result, "nerves_cache") do
      %{"misses" => misses, "lock" => lock} when is_list(misses) and is_list(lock) ->
        locked = lock |> Enum.flat_map(&pair_tuple/1) |> MapSet.new()

        misses
        |> Enum.flat_map(&pair_tuple/1)
        |> Enum.uniq()
        |> Enum.filter(&MapSet.member?(locked, &1))
        |> Enum.reject(&MapSet.member?(recent, &1))
        |> Enum.sort()
        |> Enum.take(@max_misses_considered)
        |> owned_by_nerves(owners)
        |> Enum.map(fn {name, version} -> %{"name" => name, "version" => version} end)

      _ ->
        []
    end
  end

  # Stops asking Hex as soon as four pairs are owned, same as the old
  # `Stream.filter |> Enum.take/2` -- and, unlike it, also stops on the first
  # `:hex_api_unavailable` instead of working through the rest of the misses
  # one blocking lookup at a time. A build with a dozen locked misses during a
  # Hex outage would otherwise make that many sequential 5+5s lookups, none of
  # which can come back owned, before ingest gets enqueued.
  defp owned_by_nerves(candidates, owners) do
    candidates
    |> Enum.reduce_while([], fn {name, _version} = pair, acc ->
      if length(acc) >= @warm_pairs_per_run do
        {:halt, acc}
      else
        add_if_owned(pair, name, owners.(name), acc)
      end
    end)
    |> Enum.reverse()
  end

  defp add_if_owned(pair, _name, {:ok, usernames}, acc) when is_list(usernames) do
    {:cont, if(@warm_owner in usernames, do: [pair | acc], else: acc)}
  end

  defp add_if_owned(_pair, _name, {:error, :hex_api_unavailable}, acc), do: {:halt, acc}
  defp add_if_owned(_pair, _name, _other, acc), do: {:cont, acc}

  @doc false
  # `{name, version}` for a well-formed Nerves system or toolchain pair, else
  # nothing. Shared with the recently-warmed lookup over Oban args.
  @spec pair_tuple(term()) :: [{String.t(), String.t()}]
  def pair_tuple(%{"name" => name, "version" => version})
      when is_binary(name) and is_binary(version) and byte_size(version) <= 64 do
    if Regex.match?(@pair_name, name) and match?({:ok, _}, Version.parse(version)),
      do: [{name, version}],
      else: []
  end

  def pair_tuple(_pair), do: []

  defp owners_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:owners, &Portal.HexPm.owners/1)
  end

  # Every state but discarded and cancelled, as `WarmNerves`' uniqueness.
  @warm_states ~w(suspended available scheduled executing retryable completed)

  @doc """
  Queues a `Portal.Workers.WarmNerves` job for `result`'s `warm_pairs/2` on
  this node, skipping pairs `recently_warmed/2` names. `{:ok, []}` when there
  is nothing to warm, `{:ok, :already_queued}` when every pair chosen is
  already covered by another unique job (`recently_warmed/2` should have
  filtered these out already, so this is rare, not routine). Options as
  `warm_pairs/2`, plus `opts[:now_ms]` (default `System.monotonic_time/1`) for
  the memo this writes on a genuine enqueue.
  """
  @spec request_warm(map(), String.t(), keyword()) ::
          {:ok, [pair()] | :already_queued} | {:error, term()}
  def request_warm(result, image_digest, opts \\ []) do
    case result do
      %{"nerves_cache" => %{"misses" => [_ | _]}} ->
        now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)

        recent =
          Keyword.get_lazy(opts, :recently_warmed, fn ->
            recently_warmed(image_digest, now_ms: now)
          end)

        result
        |> warm_pairs(Keyword.put(opts, :recently_warmed, recent))
        |> enqueue_warm(image_digest, now)

      _ ->
        {:ok, []}
    end
  end

  defp enqueue_warm([], _image_digest, _now), do: {:ok, []}

  defp enqueue_warm(pairs, image_digest, now) do
    case WarmNerves.enqueue(image_digest, pairs) do
      {:ok, %{conflict?: true}} ->
        {:ok, :already_queued}

      {:ok, _job} ->
        remember_warmed(image_digest, pairs, now)
        {:ok, pairs}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp remember_warmed(image_digest, pairs, now) do
    Enum.each(pairs, fn pair ->
      case pair_tuple(pair) do
        [{name, version}] -> :ets.insert(@warmed_memo, {{image_digest, name, version}, now})
        [] -> :ok
      end
    end)
  rescue
    ArgumentError -> :ok
  end

  # Unexpired entries of `@warmed_memo` for `image_digest`, read with a
  # partial-key `match_object/2` rather than scanning the whole table.
  defp memoized_warmed(image_digest, now) do
    :ets.match_object(@warmed_memo, {{image_digest, :_, :_}, :_})
    |> Enum.filter(fn {_key, at} -> now - at < @warmed_memo_ttl_ms end)
    |> Enum.map(fn {{_digest, name, version}, _at} -> {name, version} end)
    |> MapSet.new()
  rescue
    ArgumentError -> MapSet.new()
  end

  @doc """
  `{name, version}` of every pair `request_warm/3` has queued for
  `image_digest` on this node in the last day, as the union of two sources:

    * a node-local ETS memo written the moment a warm is queued, which keeps
      the day-long bound even after `Oban.Plugins.Pruner` deletes the
      completed job row (6 h, `apps/portal/config/config.exs`);
    * a live `Portal.Workers.WarmNerves` job on this node's queue, not
      discarded or cancelled -- which the memo above does not cover when the
      table was not yet created (for example, a release eval that starts no
      applications).

  A database error drops only the second source: the job's own uniqueness and
  the memo still bound repeats. `opts[:now_ms]` (default
  `System.monotonic_time/1`) is the memo's clock.
  """
  @spec recently_warmed(String.t(), keyword()) :: MapSet.t({String.t(), String.t()})
  def recently_warmed(image_digest, opts \\ []) do
    now = Keyword.get_lazy(opts, :now_ms, fn -> System.monotonic_time(:millisecond) end)
    MapSet.union(memoized_warmed(image_digest, now), oban_warmed(image_digest))
  end

  defp oban_warmed(image_digest) do
    cutoff = DateTime.add(DateTime.utc_now(), -86_400, :second)
    queue = WarmNerves.local_queue()

    from(j in Oban.Job,
      where: j.worker == "Portal.Workers.WarmNerves",
      where: j.queue == ^queue,
      where: j.state in ^@warm_states,
      where: j.inserted_at > ^cutoff,
      where: fragment("?->>'image_digest' = ?", j.args, ^image_digest),
      select: j.args
    )
    |> Repo.all()
    |> Enum.flat_map(fn args ->
      args |> Map.get("pairs") |> List.wrap() |> Enum.flat_map(&pair_tuple/1)
    end)
    |> MapSet.new()
  rescue
    exception ->
      Logger.warning("Could not load recent Nerves cache warms: #{Exception.message(exception)}")
      MapSet.new()
  end

  @template_file "template.json"

  @doc "The file under the cache root naming what the template currently resolves."
  @spec template_file() :: String.t()
  def template_file, do: @template_file

  @doc """
  The `<name>-<version>` entries the template resolved at the last deploy-time
  warm (`deploy_warm/1`), which `Portal.Workers.Sweep` never evicts. `:error`
  when the file is missing, not a regular file or not what `write_template/3`
  writes; Sweep then evicts nothing.
  """
  @spec template_entries(Path.t()) :: {:ok, MapSet.t(String.t())} | :error
  # root is the operator-configured Nerves cache; the file name is fixed.
  # sobelow_skip ["Traversal.FileModule"]
  def template_entries(root) do
    path = Path.join(root, @template_file)

    with {:ok, %File.Stat{type: :regular}} <- File.lstat(path),
         {:ok, body} <- File.read(path),
         {:ok, %{"entries" => entries}} when is_list(entries) <- Jason.decode(body),
         true <- Enum.all?(entries, &is_binary/1) do
      {:ok, MapSet.new(entries)}
    else
      _ -> :error
    end
  end

  @doc "Writes `template_file/0` atomically (temp file, then rename)."
  @spec write_template(Path.t(), String.t(), [String.t()]) :: :ok | {:error, term()}
  # root is the operator-configured Nerves cache; the file names are fixed.
  # sobelow_skip ["Traversal.FileModule"]
  def write_template(root, image_digest, entries) do
    path = Path.join(root, @template_file)
    tmp = path <> ".tmp"

    body =
      Jason.encode_to_iodata!(%{"image_digest" => image_digest, "entries" => Enum.sort(entries)})

    with :ok <- File.mkdir_p(root),
         :ok <- File.write(tmp, body) do
      File.rename(tmp, path)
    end
  end

  @trusted_marker ".ncc-trusted-v1"

  @doc """
  Makes sure everything under `root` was written by a warm. Until this release
  every build extracted into the shared cache, so on the first call
  `artifacts/` and `dl/` are removed (`File.rm_rf/1` removes a symlink, never
  its target) and `#{@trusted_marker}` is written; later calls do nothing.
  """
  @spec ensure_trusted(Path.t()) :: :ok
  # root is the operator-configured Nerves cache; the names below it are fixed.
  # sobelow_skip ["Traversal.FileModule"]
  def ensure_trusted(root) do
    marker = Path.join(root, @trusted_marker)

    case File.lstat(marker) do
      {:ok, %File.Stat{type: :regular}} ->
        :ok

      _ ->
        File.mkdir_p!(root)
        File.rm_rf!(Path.join(root, "artifacts"))
        File.rm_rf!(Path.join(root, "dl"))

        File.write!(
          marker,
          "Every entry under artifacts/ was written by a warm run (Portal.NervesCache).\n"
        )

        :ok
    end
  end

  @doc """
  The deploy-time warm, run by `ops/builder-deploy.sh` through the new
  release's `eval` after the new worker image is live and before the restart:
  `ensure_trusted/1`, then one synchronous `mode: "warm_nerves"` container
  with no pairs, so what the template resolves is cached before the first
  build, and its `warm.resolved` recorded with `write_template/3` for
  `Portal.Workers.Sweep`. A docker run, not an Oban job: a job would run on
  whichever host polled first. `opts[:builder]` and `opts[:root]` replace
  `Portal.Builder` and its `nerves_cache/0` in tests.
  """
  @spec deploy_warm(keyword()) :: :ok | {:error, term()}
  def deploy_warm(opts \\ []) do
    builder =
      Keyword.get_lazy(opts, :builder, fn ->
        Application.get_env(:portal, :build_runner, Portal.Builder)
      end)

    root = Keyword.get_lazy(opts, :root, &Portal.Builder.nerves_cache/0)
    digest = builder.image_digest(builder.docker_image())
    run_id = "warm_nerves-#{System.system_time(:millisecond)}"

    :ok = ensure_trusted(root)

    try do
      case builder.build(%{
             run_id: run_id,
             mode: "warm_nerves",
             nerves_packages: [],
             image_digest: digest
           }) do
        {:ok, %{exit_code: 0, result: %{"warm" => %{"resolved" => resolved}}}}
        when is_list(resolved) ->
          write_template(root, digest, Enum.filter(resolved, &is_binary/1))

        {:ok, %{exit_code: 0}} ->
          {:error, :missing_warm_result}

        {:ok, %{exit_code: code}} ->
          {:error, {:warm_exit, code}}

        {:error, reason} ->
          {:error, reason}
      end
    after
      builder.cleanup(run_id)
    end
  end
end
