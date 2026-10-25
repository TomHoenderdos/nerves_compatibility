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

  @type pair :: %{String.t() => String.t()}

  @doc false
  @spec warm_pairs_per_run() :: pos_integer()
  def warm_pairs_per_run, do: @warm_pairs_per_run

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
        |> Stream.filter(fn {name, _version} -> owned_by_nerves?(name, owners) end)
        |> Enum.take(@warm_pairs_per_run)
        |> Enum.map(fn {name, version} -> %{"name" => name, "version" => version} end)

      _ ->
        []
    end
  end

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

  defp owned_by_nerves?(name, owners) do
    case owners.(name) do
      {:ok, usernames} when is_list(usernames) -> @warm_owner in usernames
      _ -> false
    end
  end

  defp owners_lookup do
    :portal
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:owners, &Portal.HexPm.owners/1)
  end

  # Every state but discarded and cancelled, as `WarmNerves`' uniqueness.
  @warm_states ~w(suspended available scheduled executing retryable completed)

  @doc """
  Queues a `Portal.Workers.WarmNerves` job for `result`'s `warm_pairs/2` on
  this node, skipping pairs `recently_warmed/1` names. `{:ok, []}` when there
  is nothing to warm. Options as `warm_pairs/2`.
  """
  @spec request_warm(map(), String.t(), keyword()) :: {:ok, [pair()]} | {:error, term()}
  def request_warm(result, image_digest, opts \\ []) do
    case result do
      %{"nerves_cache" => %{"misses" => [_ | _]}} ->
        recent = Keyword.get_lazy(opts, :recently_warmed, fn -> recently_warmed(image_digest) end)

        result
        |> warm_pairs(Keyword.put(opts, :recently_warmed, recent))
        |> enqueue_warm(image_digest)

      _ ->
        {:ok, []}
    end
  end

  defp enqueue_warm([], _image_digest), do: {:ok, []}

  defp enqueue_warm(pairs, image_digest) do
    case WarmNerves.enqueue(image_digest, pairs) do
      {:ok, _job} -> {:ok, pairs}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  `{name, version}` of every pair in a `WarmNerves` job on this node's queue
  for `image_digest` inserted in the last day and not discarded or cancelled.
  Per pair, where the job's uniqueness is per set of pairs, and still there
  after `Oban.Plugins.Pruner` has deleted the finished job row (it keeps them
  6 h). A database error answers the empty set: the job's own uniqueness still
  bounds repeats.
  """
  @spec recently_warmed(String.t()) :: MapSet.t({String.t(), String.t()})
  def recently_warmed(image_digest) do
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
end
