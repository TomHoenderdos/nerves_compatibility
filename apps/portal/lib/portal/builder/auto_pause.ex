defmodule Portal.Builder.AutoPause do
  @moduledoc """
  Takes this node off a build queue while a node-local precondition fails,
  and puts it back once the precondition holds again.

  A node under the disk floor, without its egress filter or build memory
  limit, with a noexec scratch root or a docker daemon that does not answer
  refuses every job of that kind, and an idle node polls fast. Snoozing each
  refused job for 15 minutes was the whole answer once: one builder a
  gigabyte under the floor took and snoozed 753 toolchain jobs that way
  while the other builders sat partly idle.

  So `Portal.Workers.Build`, `ToolchainBuild`, `HostNativeBuild` and
  `WarmNerves` hand such a refusal to `defer/3`, which snoozes the job only
  briefly, so another node takes it soon, and pauses the job's queue on this
  node alone (`local_only`). Every `:interval_ms` (a minute) this process
  re-tests the check of every queue it holds paused (`probe/1`, each check
  once, in a process of its own so this one keeps answering), and resumes a
  queue once its check passes. Both transitions are logged as warnings with
  the reason. Without this process (Oban's testing mode, or a call that times
  out) a refused job snoozes 15 minutes as before. An image without a digest
  pauses its queue only while docker does not answer (`defer_image/2`): one
  missing image is one toolchain's, not the node's.

  ## Only its own pause

  An operator's pause, Oban Web's and `ops/builder-deploy.sh`'s drain must
  never be undone here.

    * It pauses only a queue that runs. A queue already paused stays its
      pauser's, and the refused job still gets the short snooze.
    * Every pause and resume, whoever asks, is a message on Oban's `:signal`
      channel. This process listens to it as the producers do, through the
      same notifier process on this node, so it sees every signal in the
      order the producers apply them. Its own carry its tag and an id, and
      each stays pending until it comes back. Any other pause of a queue it
      holds, or of every queue, ends the hold for good: the queue is then
      someone else's to resume. So does any other resume that comes after
      its own pause.
    * A signal of someone else's that comes back while one of its own is
      still pending was applied before its own. Should its own then be a
      resume and theirs a pause, the producer ends up running against their
      wish, so it sends their pause again, and does not hold it.
    * The builder deploy calls `let_go/2` before it pauses, which ends every
      hold on its queues, so none is resumed afterwards, and a resume still
      pending then is undone by the rule above. It also asks
      `held_queues/0`: a queue paused here is no operator's pause, which
      would refuse the deploy.
    * A crash gives back the queues it holds (`terminate/2`); a node restart
      starts every queue running and this process holding nothing.

  ## What the admin page sees

  Each node announces what it holds on the notifier's `:ncc_auto_pause`
  channel whenever that changes and every interval while it holds anything,
  and keeps what it hears from the others for `:peer_ttl_ms` (three
  intervals). `cluster/1` answers for the whole fleet on the admin Builders
  tab.
  """

  use GenServer

  require Logger

  alias Portal.Builder

  @typedoc "A node-local precondition of a build, which `probe/1` re-tests."
  @type check ::
          {:disk, mode :: String.t() | nil}
          | :scratch_exec
          | :egress
          | :memory_limit
          | :docker

  @type entry :: %{
          node: String.t(),
          queue: String.t(),
          reason: String.t(),
          since: DateTime.t() | nil
        }

  # Long enough not to spin on a node that is the only one left; short
  # enough that another node takes the job soon.
  @short_snooze 60
  # What every refusal snoozed before, and still does when nothing paused.
  @long_snooze 900
  @interval_ms :timer.minutes(1)
  # A worker waits this long before falling back to the long snooze.
  @call_timeout_ms 5_000
  # Probes run apart from the server; one that hangs (a `df` on a stuck
  # mount) is killed after this, and the next interval tries again.
  @probe_timeout_ms :timer.minutes(3)
  # A signal of its own that has not come back by then is taken as lost.
  @pending_ttl_ms 30_000
  @channel :ncc_auto_pause

  @doc """
  Starts the server, or returns `:ignore` while Oban runs in testing mode.

  Options: `:name`, `:enabled`, `:oban` (the instance, `Oban`), `:node`
  (default the instance's), `:interval_ms`, `:peer_ttl_ms`, and for tests
  `:tag` (its signals' tag), `:probe` (`probe/1`) and `:ops`, a map of
  `check_queue`, `signal`, `listen` and `gossip` functions that replace the
  Oban calls.
  """
  def start_link(opts \\ []) do
    if Keyword.get_lazy(opts, :enabled, &oban_running?/0) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
    else
      :ignore
    end
  end

  defp oban_running? do
    :portal |> Application.get_env(Oban, []) |> Keyword.get(:testing, :disabled) == :disabled
  end

  @doc """
  The check a builder refusal names, `mode` being the build's
  (`Portal.Builder.build/2`), or nil when the refusal is not a node-local one.
  """
  @spec check_for(term(), String.t() | nil) :: check() | nil
  def check_for({:insufficient_disk, _free, _needed}, mode), do: {:disk, mode}
  def check_for(:scratch_noexec, _mode), do: :scratch_exec
  def check_for(:egress_filter_missing, _mode), do: :egress
  def check_for(:build_memory_limit_missing, _mode), do: :memory_limit
  def check_for(_reason, _mode), do: nil

  @doc """
  The outcome of a job refused on this node for `check`: pauses `queue` on
  this node and snoozes the job #{@short_snooze} s, or snoozes it
  #{@long_snooze} s when the queue could not be paused here.
  """
  @spec defer(String.t() | nil, check(), GenServer.server()) :: {:snooze, pos_integer()}
  def defer(queue, check, server \\ __MODULE__)

  def defer(queue, check, server) when is_binary(queue) do
    case call(server, {:hold, queue, check}, :unavailable) do
      :paused -> {:snooze, @short_snooze}
      :unavailable -> {:snooze, @long_snooze}
    end
  end

  def defer(_queue, _check, _server), do: {:snooze, @long_snooze}

  @doc """
  The outcome of a job whose image has no digest on this node
  (`Portal.Builder.image_digest/1`): `defer/3` for `:docker` when the docker
  daemon does not answer, which no job here can build without. When it
  answers, only this one image is missing (a toolchain this node does not
  configure, say), and pausing the queue would stop every other toolchain's
  builds here as well, for as long as the image stays missing: the job
  snoozes #{@long_snooze} s and the queue keeps running.
  """
  @spec defer_image(String.t() | nil, GenServer.server()) :: {:snooze, pos_integer()}
  def defer_image(queue, server \\ __MODULE__) do
    case probe(:docker) do
      :ok -> {:snooze, @long_snooze}
      {:error, _} -> defer(queue, :docker, server)
    end
  end

  @doc "The queues this process holds paused on this node, for the builder deploy."
  @spec held_queues(GenServer.server()) :: [String.t()]
  def held_queues(server \\ __MODULE__), do: call(server, :held_queues, [])

  @doc """
  Ends this process's hold on `queues`, which the builder deploy is about to
  pause: it never resumes them after this.
  """
  @spec let_go([atom() | String.t()], GenServer.server()) :: :ok
  def let_go(queues, server \\ __MODULE__),
    do: call(server, {:let_go, Enum.map(queues, &to_string/1)}, :ok)

  @doc "Every queue paused by this module on any node heard from lately, by node and queue."
  @spec cluster(GenServer.server()) :: [entry()]
  def cluster(server \\ __MODULE__), do: call(server, :cluster, [])

  defp call(server, message, fallback) do
    GenServer.call(server, message, @call_timeout_ms)
  catch
    :exit, _ -> fallback
  end

  @doc """
  `:ok` when `check` holds on this node now, as `Portal.Builder.build/2`'s
  own preflight would find it.
  """
  @spec probe(check()) :: :ok | {:error, term()}
  def probe({:disk, mode}), do: Builder.check_disk(mode)
  def probe(:scratch_exec), do: Builder.check_scratch_exec()
  def probe(:egress), do: Builder.check_egress()
  def probe(:memory_limit), do: Builder.check_memory_limit()

  def probe(:docker) do
    check =
      Application.get_env(:portal, __MODULE__, [])[:docker_check] || (&Builder.check_docker/0)

    case check.() do
      {:ok, _version} -> :ok
      error -> error
    end
  end

  @doc "What `check` failing means, for the log and the admin page."
  @spec describe(check()) :: String.t()
  def describe({:disk, mode}),
    do: "less than #{gb(Builder.min_free_bytes(mode))} GB free on the scratch disk"

  def describe(:scratch_exec), do: "the scratch root cannot execute files (mounted noexec?)"
  def describe(:egress), do: "the build egress filter is missing"
  def describe(:memory_limit), do: "no build memory limit is set"
  def describe(:docker), do: "the docker daemon does not answer"

  defp gb(bytes), do: Float.round(bytes / 1024 / 1024 / 1024, 1)

  # ── Server ────────────────────────────────────────────────────────────────

  @impl GenServer
  def init(opts) do
    oban = Keyword.get(opts, :oban, Oban)
    interval_ms = Keyword.get(opts, :interval_ms, @interval_ms)
    tag = Keyword.get_lazy(opts, :tag, fn -> Base.encode16(:crypto.strong_rand_bytes(8)) end)
    ops = Map.merge(oban_ops(oban, tag), Keyword.get(opts, :ops, %{}))

    :ok = ops.listen.()
    schedule(interval_ms)

    {:ok,
     %{
       node: Keyword.get_lazy(opts, :node, fn -> oban |> Oban.config() |> Map.fetch!(:node) end),
       tag: tag,
       ops: ops,
       probe: Keyword.get(opts, :probe, &probe/1),
       interval_ms: interval_ms,
       peer_ttl_ms: Keyword.get(opts, :peer_ttl_ms, 3 * interval_ms),
       # queue => %{check, reason, since}
       held: %{},
       # queue => [%{id, action, at}], its own signals not yet back, oldest first
       pending: %{},
       next_id: 1,
       probing: nil,
       peers: %{}
     }}
  end

  # Oban's own `pause_queue/2` cannot carry a tag, so the signal is sent as
  # it sends it, with two more keys that the producers ignore.
  defp oban_ops(oban, tag) do
    %{
      check_queue: fn queue ->
        try do
          Oban.check_queue(oban, queue: queue)
        catch
          :exit, _ -> nil
        end
      end,
      signal: fn action, queue, id ->
        conf = Oban.config(oban)

        Oban.Notifier.notify(conf, :signal, %{
          action: action,
          queue: queue,
          ident: Oban.Config.to_ident(conf),
          auto_pause: tag,
          auto_pause_id: id
        })
      end,
      listen: fn -> Oban.Notifier.listen(oban, [:signal, @channel]) end,
      gossip: fn payload -> Oban.Notifier.notify(oban, @channel, payload) end
    }
  end

  @impl GenServer
  def handle_call({:hold, queue, _check}, _from, state) when is_map_key(state.held, queue),
    do: {:reply, :paused, state}

  def handle_call({:hold, queue, check}, _from, state) do
    case state.ops.check_queue.(queue) do
      %{paused: true} ->
        {:reply, :paused, state}

      %{paused: false} ->
        pause(queue, check, state)

      _no_producer_here ->
        {:reply, :unavailable, state}
    end
  end

  def handle_call(:held_queues, _from, state),
    do: {:reply, state.held |> Map.keys() |> Enum.sort(), state}

  def handle_call({:let_go, queues}, _from, state) do
    state =
      Enum.reduce(queues, state, &release(&2, &1, "the builder deploy takes the pause over"))

    {:reply, :ok, state}
  end

  def handle_call(:cluster, _from, state) do
    own = Enum.map(state.held, fn {queue, held} -> entry(state.node, queue, held) end)

    peers =
      Enum.flat_map(state.peers, fn {node, %{held: held}} ->
        Enum.map(held, &Map.put(&1, :node, node))
      end)

    {:reply, Enum.sort_by(own ++ peers, &{&1.node, &1.queue}), state}
  end

  @impl GenServer
  def handle_info(:tick, state) do
    state = state |> expire_pending() |> expire_peers() |> start_probe()
    if state.held != %{}, do: announce(state)
    schedule(state.interval_ms)
    {:noreply, state}
  end

  def handle_info({:probed, ref, passing}, %{probing: %{ref: ref, monitor: monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    state = %{state | probing: nil}

    state =
      state.held
      |> Enum.filter(fn {_queue, held} -> held.check in passing end)
      |> Enum.reduce(state, fn {queue, held}, state -> resume(state, queue, held) end)

    {:noreply, state}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, reason},
        %{probing: %{monitor: monitor}} = state
      ) do
    Logger.warning("Auto-pause re-check stopped: #{inspect(reason)}")
    {:noreply, %{state | probing: nil}}
  end

  def handle_info(
        {:notification, :signal, %{"action" => action, "queue" => queue} = payload},
        state
      )
      when action in ["pause", "resume"] and is_binary(queue) do
    if payload["auto_pause"] == state.tag do
      {:noreply, come_back(state, queue, payload["auto_pause_id"])}
    else
      {:noreply, foreign(state, queue, if(action == "pause", do: :pause, else: :resume))}
    end
  end

  def handle_info({:notification, @channel, %{"node" => node, "held" => held}}, state)
      when is_binary(node) and is_list(held) and node != state.node do
    {:noreply, hear(state, node, held)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  # A crash would otherwise leave its queues paused with nobody to resume
  # them. Only queues it still holds, so never someone else's pause; if the
  # check still fails, the next refused job pauses the queue again.
  @impl GenServer
  def terminate(reason, _state) when reason in [:normal, :shutdown], do: :ok
  def terminate({:shutdown, _}, _state), do: :ok

  def terminate(reason, state) do
    Enum.each(state.held, fn {queue, held} ->
      Logger.warning(
        "Auto-pause stopping (#{inspect(reason)}); resuming queue #{queue} on this node " <>
          "(was: #{held.reason})"
      )

      state.ops.signal.(:resume, queue, 0)
    end)
  end

  # ── Pausing and resuming ──────────────────────────────────────────────────

  defp pause(queue, check, state) do
    reason = describe(check)

    case send_signal(state, :pause, queue) do
      {:ok, state} ->
        Logger.warning(
          "Pausing queue #{queue} on this node until the check passes: #{reason}. " <>
            "Re-checked every #{div(state.interval_ms, 1000)} s."
        )

        held = %{check: check, reason: reason, since: DateTime.utc_now()}
        state = put_in(state.held[queue], held)
        announce(state)
        {:reply, :paused, state}

      {:error, error} ->
        Logger.error("Could not pause queue #{queue} on this node: #{inspect(error)}")
        {:reply, :unavailable, state}
    end
  end

  defp resume(state, queue, held) do
    case send_signal(state, :resume, queue) do
      {:ok, state} ->
        Logger.warning(
          "Resuming queue #{queue} on this node: the check passes again (was: #{held.reason})"
        )

        state = %{state | held: Map.delete(state.held, queue)}
        announce(state)
        state

      {:error, error} ->
        Logger.error("Could not resume queue #{queue} on this node: #{inspect(error)}")
        state
    end
  end

  defp send_signal(state, action, queue) do
    id = state.next_id

    case state.ops.signal.(action, queue, id) do
      :ok ->
        sent = %{id: id, action: action, at: now_ms()}
        pending = Map.update(state.pending, queue, [sent], &(&1 ++ [sent]))
        {:ok, %{state | pending: pending, next_id: id + 1}}

      error ->
        {:error, error}
    end
  end

  # One of its own came back: it is applied, and so is everything before it.
  defp come_back(state, queue, id) do
    pending =
      case Map.get(state.pending, queue, []) |> Enum.drop_while(&(&1.id != id)) do
        [_sent | later] when later != [] -> Map.put(state.pending, queue, later)
        _ -> Map.delete(state.pending, queue)
      end

    %{state | pending: pending}
  end

  defp foreign(state, "*", action) do
    (Map.keys(state.held) ++ Map.keys(state.pending))
    |> Enum.uniq()
    |> Enum.reduce(state, &foreign(&2, &1, action))
  end

  defp foreign(state, queue, action) do
    pending = Map.get(state.pending, queue, [])

    if Map.has_key?(state.held, queue),
      do: foreign_on_held(state, queue, action, pending),
      else: foreign_on_free(state, queue, action, List.last(pending))
  end

  # Theirs from now on, whenever it came: this process will not resume what
  # they paused.
  defp foreign_on_held(state, queue, :pause, _pending),
    do: release(state, queue, "someone else paused it as well")

  # After its own pause, so the queue runs again, by their hand.
  defp foreign_on_held(state, queue, :resume, []),
    do: release(state, queue, "someone else resumed it")

  # Before its own pause, which wins: still its own to resume.
  defp foreign_on_held(state, _queue, :resume, _pending), do: state

  # Applied before a signal of its own that does the opposite: say it again,
  # after that one, so their wish stands.
  defp foreign_on_free(state, queue, action, %{action: own}) when own != action do
    Logger.warning(
      "Queue #{queue} on this node: someone else's #{action} came just before " <>
        "this node's own #{own}; repeating theirs"
    )

    case send_signal(state, action, queue) do
      {:ok, state} -> state
      {:error, _error} -> state
    end
  end

  defp foreign_on_free(state, _queue, _action, _last_own), do: state

  defp release(state, queue, why) do
    case Map.pop(state.held, queue) do
      {nil, _held} ->
        state

      {held, rest} ->
        Logger.warning(
          "Queue #{queue} on this node is no longer auto-paused: #{why}, so it is theirs " <>
            "to resume (was: #{held.reason})"
        )

        state = %{state | held: rest}
        announce(state)
        state
    end
  end

  defp expire_pending(state) do
    cutoff = now_ms() - @pending_ttl_ms

    pending =
      state.pending
      |> Enum.map(fn {queue, sent} -> {queue, Enum.reject(sent, &(&1.at <= cutoff))} end)
      |> Enum.reject(fn {_queue, sent} -> sent == [] end)
      |> Map.new()

    %{state | pending: pending}
  end

  # ── Re-checking ───────────────────────────────────────────────────────────

  defp start_probe(%{probing: %{pid: pid, monitor: monitor, at: at}} = state) do
    if now_ms() - at > @probe_timeout_ms do
      Logger.warning("Auto-pause re-check took over #{div(@probe_timeout_ms, 1000)} s; killed")
      Process.demonitor(monitor, [:flush])
      Process.exit(pid, :kill)
      %{state | probing: nil}
    else
      state
    end
  end

  defp start_probe(%{held: held} = state) when held == %{}, do: state

  defp start_probe(state) do
    server = self()
    probe = state.probe
    checks = state.held |> Map.values() |> Enum.map(& &1.check) |> Enum.uniq()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        send(server, {:probed, ref, Enum.filter(checks, &(safe_probe(probe, &1) == :ok))})
      end)

    %{state | probing: %{pid: pid, monitor: monitor, ref: ref, at: now_ms()}}
  end

  defp safe_probe(probe, check) do
    probe.(check)
  rescue
    e -> {:error, e}
  catch
    kind, value -> {:error, {kind, value}}
  end

  # ── The admin view ────────────────────────────────────────────────────────

  defp announce(state) do
    held =
      Enum.map(state.held, fn {queue, held} ->
        %{queue: queue, reason: held.reason, since: DateTime.to_iso8601(held.since)}
      end)

    changed()
    state.ops.gossip.(%{node: state.node, held: held})
  rescue
    _ -> :ok
  end

  defp hear(state, node, []) do
    if Map.has_key?(state.peers, node), do: changed()
    %{state | peers: Map.delete(state.peers, node)}
  end

  defp hear(state, node, held) do
    entries =
      for %{"queue" => queue, "reason" => reason} = entry <- held,
          is_binary(queue) and is_binary(reason) do
        %{queue: queue, reason: reason, since: parse_since(entry["since"])}
      end

    if get_in(state.peers, [node, :held]) != entries, do: changed()
    put_in(state.peers[node], %{held: entries, at: now_ms()})
  end

  defp expire_peers(state) do
    cutoff = now_ms() - state.peer_ttl_ms
    {stale, fresh} = Map.split_with(state.peers, fn {_node, peer} -> peer.at <= cutoff end)
    if stale != %{}, do: changed()
    %{state | peers: fresh}
  end

  defp parse_since(since) when is_binary(since) do
    case DateTime.from_iso8601(since) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse_since(_since), do: nil

  defp entry(node, queue, held),
    do: %{node: node, queue: queue, reason: held.reason, since: held.since}

  defp changed, do: Portal.AdminEvents.broadcast(:builders)

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp schedule(interval_ms), do: Process.send_after(self(), :tick, interval_ms)
end
