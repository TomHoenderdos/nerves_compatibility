defmodule Portal.NodeQueue do
  @moduledoc """
  This node's own Oban queue, `node_<slug>`, for the work that has to run on
  the node whose disk it touches:

    * `Portal.Workers.Ingest` of a local build. `Portal.Workers.Build`,
      `Portal.Workers.ToolchainBuild` and `Portal.Workers.HostNativeBuild`
      hand their result over through the run's scratch dir on this node's
      disk, so the ingest has to run here. While several build hosts shared
      one `:ingest` queue, any of them could take it, find no `result.json`
      and give up: 19 of 42 builds on 2026-10-10 lost their result that way.
    * `Portal.Workers.Sweep`, which reclaims this node's scratch trees and
      caches, queued here every hour by this node itself
      (`Portal.Oban.NodeSweep`). While it was a cron job on the shared
      `:ingest` queue, each hour's sweep ran on whichever builder fetched it
      first, and the other builders' disks went unswept.

  Every node that runs builds runs its node queue, as wide as the `node`
  entry of `OBAN_QUEUES` (default 2); a node that runs no builds (the web
  host) has none, and so never sweeps directories it does not have. A sweep
  takes at most one of the slots: it is unique per queue.

  `Portal.Workers.WarmNerves` keeps a queue of its own per node, with limit 1
  (`Portal.Workers.WarmNerves.local_queue/1`). Oban without Pro has no
  per-worker limit inside a queue, so on this one up to its width in warms
  could run side by side, each a container writing the one read-write Nerves
  cache, and each, minutes long, would hold an ingest's slot.

  ## From the previous release (one release only)

  This queue replaced each node's `ingest_<slug>` and the shared `:ingest`
  queue. So that nothing the previous release queued is stranded across the
  deploy:

    * `with_queue/2` still runs `legacy_ingest/1`, as wide as the node queue:
      the ingests the previous release put there (a build that finished
      while the deploy drained, a retry) run on the node whose disk has their
      scratch dir. Its name is the node's own, so no other node takes them.
    * An `ingest:N` entry in `OBAN_QUEUES` is read as `node:N` and logged:
      no node runs the shared queue any more, and the hosts need no config
      change in the same deploy. The follow-up renames it to `node:N`.
    * `Portal.Oban.NodeSweep` cancels a sweep the previous release's cron
      left on the shared queue once no node has claimed it for two hours.
  """

  require Logger

  @default_limit 2

  @doc "This node's own queue."
  @spec name(node()) :: String.t()
  def name(node \\ node()), do: "node_" <> slug(node)

  @doc """
  The queue the previous release ran for this node's ingests, drained by
  this release only.
  """
  @spec legacy_ingest(node()) :: String.t()
  def legacy_ingest(node \\ node()), do: "ingest_" <> slug(node)

  @doc "`node`'s name as it appears in its per-node queue names."
  @spec slug(node()) :: String.t()
  def slug(node),
    do: node |> Atom.to_string() |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "_")

  @doc "Whether a node with these Oban `queues` runs builds."
  @spec build_node?(keyword() | false | nil) :: boolean()
  def build_node?(queues) when is_list(queues), do: Keyword.get(queues, :builds, 0) > 0
  def build_node?(_queues), do: false

  @doc """
  How wide the node queue runs, given this node's configured Oban `queues`:
  its `node` entry, else a legacy `ingest` one, else #{@default_limit}; nil
  when the node runs no builds.
  """
  @spec limit(keyword() | false | nil) :: pos_integer() | keyword() | nil
  def limit(queues) do
    if build_node?(queues),
      do: Keyword.get_lazy(queues, :node, fn -> Keyword.get(queues, :ingest, @default_limit) end),
      else: nil
  end

  @doc """
  `oban_config` with its `node` and legacy `ingest` entries replaced by
  `node`'s own queue and, for one release, its legacy ingest queue, both
  `limit/1` wide, when the node runs builds. Oban wants queue names as
  keyword keys, so this makes two atoms per node, from the node's own name.
  """
  @spec with_queue(keyword(), node()) :: keyword()
  def with_queue(oban_config, node \\ node()) do
    case Keyword.get(oban_config, :queues) do
      queues when is_list(queues) ->
        limit = limit(queues)
        log_legacy_ingest(queues, limit, node)
        rest = Keyword.drop(queues, [:node, :ingest])
        Keyword.replace!(oban_config, :queues, rest ++ node_queues(rest, limit, node))

      _off ->
        oban_config
    end
  end

  defp node_queues(_queues, nil, _node), do: []

  # The atoms come from the node name the release was started with, not from
  # any request: two per build host, created once at boot.
  # sobelow_skip ["DOS.StringToAtom"]
  defp node_queues(queues, limit, node) do
    warn_if_unnamed(node)

    for name <- [name(node), legacy_ingest(node)],
        queue = String.to_atom(name),
        not Keyword.has_key?(queues, queue),
        do: {queue, limit}
  end

  defp log_legacy_ingest(queues, limit, node) do
    with {:ok, width} <- Keyword.fetch(queues, :ingest) do
      gone =
        "OBAN_QUEUES names ingest:#{inspect(width)}; no node runs a shared ingest queue any more"

      cond do
        limit == nil ->
          Logger.warning("#{gone}, and this node runs no builds, so it is ignored. Remove it.")

        Keyword.has_key?(queues, :node) ->
          Logger.warning("#{gone}, and node:#{inspect(limit)} sizes #{name(node)}. Remove it.")

        true ->
          Logger.warning(
            "#{gone}, so it is read as node:#{inspect(width)} and sizes #{name(node)}. " <>
              "Rename it to node:#{inspect(width)}."
          )
      end
    end
  end

  # A single unnamed node (dev, one-host installs) is fine. Several build hosts
  # without names would all be `nonode@nohost` and share one "node" queue --
  # the cross-host ingest this exists to prevent -- so say so at boot.
  defp warn_if_unnamed(:nonode@nohost) do
    Logger.warning(
      "this node runs builds without a node name; its queue " <>
        "#{name(:nonode@nohost)} is only node-local while it is the only build host"
    )
  end

  defp warn_if_unnamed(_node), do: :ok
end
