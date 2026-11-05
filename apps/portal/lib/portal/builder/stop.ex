defmodule Portal.Builder.Stop do
  @moduledoc """
  Stops a build container that outlived `Portal.Builder`'s wall clock, off
  the build's own process.

  A gVisor sandbox can wedge so that docker cannot stop it: `docker kill`,
  `docker stop` and `runsc kill` all block on it, and only SIGKILL of its
  `runsc-sandbox` and `runsc-gofer` processes ends it. `Portal.Builder`
  therefore returns from a timed-out build at once and hands the container
  to `start/1`, which runs in a supervised task, every docker call under
  its own deadline (`Portal.Builder.Cmd`):

    1. find the running container's full id by its exact name (`docker
       ps`, which answers from the daemon's lock-free view even while a
       kill of the container hangs); nothing running means nothing to do
    2. `docker kill <id>`, then wait for it to stop running

  The portal cannot signal root's runsc processes. A container that is
  still running after that is logged as an error and left to the builder
  host's build reaper (`ops/build-reaper.sh`, a root timer), which kills
  the scope cgroup of any build container active past the ceiling plus a
  grace; `Portal.Workers.Sweep` reports any such container meanwhile
  (`overdue/2`).

  Every outcome is logged and emitted as `[:portal, :builder,
  :container_stop]` (`%{duration_ms}`, `%{container, outcome}`).
  """

  require Logger

  @defaults [
    kill_timeout_ms: 30_000,
    cmd_timeout_ms: 15_000,
    wait_ms: 60_000,
    poll_ms: 2_000
  ]

  # The `Portal.Builder` config key of each option.
  @config_keys [
    kill_timeout_ms: :stop_kill_timeout_ms,
    cmd_timeout_ms: :stop_cmd_timeout_ms,
    wait_ms: :stop_wait_ms,
    poll_ms: :stop_poll_ms
  ]

  @type outcome :: :gone | :killed | :still_running | :unknown

  @doc """
  Stops `container` in a task under `Portal.TaskSupervisor`, waiting at
  most `await_ms` for it: long enough for a container docker can kill, so
  the caller's cleanup does not race it, and never on a hung one. Where the
  supervisor is not running (a release `eval`) the task is an unlinked
  process and is not waited for.
  """
  @spec start(String.t(), non_neg_integer()) :: :ok
  def start(container, await_ms \\ 0) do
    fun = fn -> escalate(container) end

    case Process.whereis(Portal.TaskSupervisor) do
      nil ->
        spawn(fun)

      _sup ->
        task = Task.Supervisor.async_nolink(Portal.TaskSupervisor, fun)
        if Task.yield(task, await_ms) == nil, do: Task.ignore(task)
    end

    :ok
  end

  @doc """
  Stops `container` as the moduledoc describes and answers how it ended:
  `:gone` (not running to begin with), `:killed` (by `docker kill`),
  `:still_running` (left to the build reaper), or `:unknown` (docker could
  not say). Options override `Portal.Builder` config, for tests:
  `:docker`, `:kill_timeout_ms`, `:cmd_timeout_ms`, `:wait_ms`, `:poll_ms`.
  """
  @spec escalate(String.t(), keyword()) :: outcome()
  def escalate(container, opts \\ []) do
    opts = options(opts)
    started = System.monotonic_time(:millisecond)
    outcome = do_escalate(container, opts)

    :telemetry.execute(
      [:portal, :builder, :container_stop],
      %{duration_ms: System.monotonic_time(:millisecond) - started},
      %{container: container, outcome: outcome}
    )

    log_outcome(container, outcome)
    outcome
  end

  defp do_escalate(container, opts) do
    case running_id(container, opts) do
      {:ok, nil} -> :gone
      {:ok, id} -> kill(container, id, opts)
      :error -> :unknown
    end
  end

  defp kill(container, id, opts) do
    case docker(opts, ["kill", id], opts[:kill_timeout_ms]) do
      {:ok, _out, 0} -> :ok
      other -> Logger.warning("docker kill #{container} (#{id}): #{inspect(other)}")
    end

    if stopped?(container, id, opts), do: :killed, else: :still_running
  end

  # Polls until `id` no longer runs under `container`, for at most `:wait_ms`.
  defp stopped?(container, id, opts) do
    deadline = System.monotonic_time(:millisecond) + opts[:wait_ms]
    poll_stopped(container, id, opts, deadline)
  end

  defp poll_stopped(container, id, opts, deadline) do
    case running_id(container, opts) do
      {:ok, ^id} ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(opts[:poll_ms])
          poll_stopped(container, id, opts, deadline)
        else
          false
        end

      {:ok, _other_or_nil} ->
        true

      :error ->
        false
    end
  end

  @doc false
  # The full id of the running container named exactly `container`, nil
  # when none runs, `:error` when docker cannot say. docker's name filter
  # is a regex over substrings, so the names it returns are compared here.
  @spec running_id(String.t(), keyword()) :: {:ok, String.t() | nil} | :error
  def running_id(container, opts) do
    args = [
      "ps",
      "--no-trunc",
      "--filter",
      "name=#{container}",
      "--format",
      "{{.ID}}\t{{.Names}}"
    ]

    case docker(opts, args, opts[:cmd_timeout_ms]) do
      {:ok, out, 0} ->
        {:ok,
         Enum.find_value(String.split(out, "\n", trim: true), fn line ->
           case String.split(line, "\t") do
             [id, ^container] -> if container_id?(id), do: id
             _ -> nil
           end
         end)}

      _ ->
        :error
    end
  end

  @doc """
  The `ncc-*` containers running for longer than `:limit_ms` at `now`, with
  how long each has run, oldest first, or `:error` when docker cannot say.
  `Portal.Workers.Sweep` reports them: no build runs that long, so one that
  does is a container whose stop failed or whose builder died.
  """
  @spec overdue(DateTime.t(), keyword()) :: {:ok, [{String.t(), non_neg_integer()}]} | :error
  def overdue(now, opts) do
    opts = options(opts)
    args = ["ps", "--filter", "name=ncc-", "--format", "{{.Names}}\t{{.CreatedAt}}"]

    case docker(opts, args, opts[:cmd_timeout_ms]) do
      {:ok, out, 0} ->
        {:ok,
         out
         |> String.split("\n", trim: true)
         |> Enum.flat_map(&overdue_line(&1, now, opts[:limit_ms]))
         |> Enum.sort_by(fn {_name, age} -> -age end)}

      _ ->
        :error
    end
  end

  # Past the ceiling a build's own stop takes a few minutes at most.
  @overdue_grace_ms :timer.minutes(15)

  @doc "How long an `ncc-*` container may run before `overdue/2` names it."
  @spec overdue_limit_ms() :: pos_integer()
  def overdue_limit_ms, do: Portal.Builder.total_timeout_ms() + @overdue_grace_ms

  @doc """
  Logs each container `overdue/2` found as an error and emits
  `[:portal, :builder, :container_overdue]` (`%{age_ms}`, `%{container}`)
  for it. Answers the names.
  """
  @spec report_overdue({:ok, [{String.t(), non_neg_integer()}]} | :error) :: [String.t()]
  def report_overdue({:ok, containers}) do
    for {name, age_ms} <- containers do
      Logger.error(
        "Build container #{name} has run for #{div(age_ms, 60_000)} minutes, past the " <>
          "#{div(Portal.Builder.total_timeout_ms(), 60_000)}-minute build ceiling: its stop " <>
          "failed or its builder died; it needs the operator (see Portal.Builder.Stop)"
      )

      :telemetry.execute(
        [:portal, :builder, :container_overdue],
        %{age_ms: age_ms},
        %{container: name}
      )

      name
    end
  end

  def report_overdue(:error), do: []

  defp overdue_line(line, now, limit_ms) do
    with ["ncc-" <> _ = name, created] <- String.split(line, "\t", parts: 2),
         {:ok, at} <- parse_created(created),
         age when age > limit_ms <- DateTime.diff(now, at, :millisecond) do
      [{name, age}]
    else
      _ -> []
    end
  end

  # docker's CreatedAt: "2006-01-02 15:04:05 -0700 MST".
  defp parse_created(text) do
    with [_, date, time, sign, hh, mm] <-
           Regex.run(~r/^(\d{4}-\d\d-\d\d) (\d\d:\d\d:\d\d) ([+-])(\d\d)(\d\d)/, text),
         {:ok, naive} <- NaiveDateTime.from_iso8601("#{date} #{time}") do
      offset = (String.to_integer(hh) * 3600 + String.to_integer(mm) * 60) * sign(sign)
      {:ok, naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.add(-offset, :second)}
    else
      _ -> :error
    end
  end

  defp sign("+"), do: 1
  defp sign("-"), do: -1

  defp container_id?(id), do: String.match?(id, ~r/\A[0-9a-f]{64}\z/)

  defp docker(opts, args, timeout_ms) do
    exe = opts[:docker] || System.find_executable("docker") || "docker"
    Portal.Builder.Cmd.run(exe, args, timeout_ms)
  end

  defp options(opts) do
    @defaults
    |> Enum.map(fn {key, default} -> {key, config(@config_keys[key], default)} end)
    |> Keyword.merge(opts)
  end

  defp config(key, default) do
    :portal |> Application.get_env(Portal.Builder, []) |> Keyword.get(key, default)
  end

  defp log_outcome(container, :killed),
    do: Logger.warning("Timed-out build container #{container} stopped by docker kill")

  defp log_outcome(_container, :gone), do: :ok

  defp log_outcome(container, :unknown),
    do:
      Logger.error(
        "Timed-out build container #{container}: docker could not say whether it still runs"
      )

  defp log_outcome(container, :still_running),
    do:
      Logger.error(
        "Timed-out build container #{container} is still running after docker kill: " <>
          "the host's build reaper (ops/build-reaper.sh) kills it past the ceiling plus " <>
          "a grace; without one it needs the operator"
      )
end
