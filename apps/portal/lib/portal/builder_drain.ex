defmodule Portal.BuilderDrain do
  @moduledoc """
  Whether this node's builder queues have drained, for a builder deploy
  (`ops/builder-deploy.sh`), which pauses them and waits.

  The producer's running list alone is not the answer. A build's process
  once hung in a `docker kill` that never returned; Lifeline rescued its
  row and another node retried it, but the hung process kept its place in
  this node's running list, and the deploy waited for it until it timed
  out. A job counts as running only while its row is still `executing`
  under this very producer (`attempted_by` is `[node, producer uuid]`).
  Any other job the producer lists is an orphan: its row was rescued,
  retried, discarded or deleted, so restarting this node loses nothing of
  it. Orphans do not hold the drain, and `report/2` names each one so the
  deploy log says what was left; nothing here kills anything.
  """

  import Ecto.Query

  alias Portal.Repo

  @type orphan :: %{
          queue: String.t(),
          id: integer(),
          worker: String.t() | nil,
          state: String.t(),
          attempted_by: [String.t()] | nil,
          args: map()
        }

  @doc """
  `%{drained:, waiting:, orphans:}` for `queues`: drained when every queue
  is paused and no job is still executing under its producer. `:check`
  (a queue -> `Oban.check_queue/1` answer function) is for tests.
  """
  @spec status([atom() | String.t()], keyword()) :: %{
          drained: boolean(),
          waiting: [integer()],
          orphans: [orphan()]
        }
  def status(queues, opts \\ []) do
    check = Keyword.get(opts, :check, &Oban.check_queue(queue: &1))

    Enum.reduce(queues, %{drained: true, waiting: [], orphans: []}, fn queue, acc ->
      case check.(queue) do
        %{paused: true, running: running} = meta ->
          {waiting, orphans} = classify(to_string(queue), running, meta)

          %{
            drained: acc.drained and waiting == [],
            waiting: acc.waiting ++ waiting,
            orphans: acc.orphans ++ orphans
          }

        _not_paused_or_missing ->
          %{acc | drained: false}
      end
    end)
  end

  @doc """
  Prints `status/2` for the deploy script: `true` or `false` on the first
  line, then one `orphan ...` line per orphan.
  """
  @spec report([atom() | String.t()], keyword()) :: :ok
  def report(queues, opts \\ []) do
    %{drained: drained, orphans: orphans} = status(queues, opts)
    IO.puts(to_string(drained))
    Enum.each(orphans, &IO.puts(orphan_line(&1)))
  end

  defp classify(_queue, [], _meta), do: {[], []}

  defp classify(queue, running, meta) do
    rows =
      from(j in Oban.Job,
        where: j.id in ^running,
        select:
          {j.id, %{worker: j.worker, state: j.state, attempted_by: j.attempted_by, args: j.args}}
      )
      |> Repo.all()
      |> Map.new()

    Enum.reduce(running, {[], []}, fn id, {waiting, orphans} ->
      row = Map.get(rows, id)

      if live?(row, meta) do
        {waiting ++ [id], orphans}
      else
        {waiting, orphans ++ [orphan(queue, id, row)]}
      end
    end)
  end

  defp live?(%{state: "executing", attempted_by: [node, uuid | _]}, %{node: node, uuid: uuid}),
    do: true

  defp live?(_row, _meta), do: false

  defp orphan(queue, id, nil),
    do: %{queue: queue, id: id, worker: nil, state: "missing", attempted_by: nil, args: %{}}

  defp orphan(queue, id, row), do: Map.merge(row, %{queue: queue, id: id})

  defp orphan_line(orphan) do
    [
      "orphan queue=#{orphan.queue} job=#{orphan.id}",
      "worker=#{orphan.worker || "-"}",
      "state=#{orphan.state}",
      "attempted_by=#{Enum.join(orphan.attempted_by || [], ",")}"
    ]
    |> Kernel.++(container(orphan.args))
    |> Enum.join(" ")
  end

  # `Portal.Workers.Build` names its container `ncc-<package>-<version>-<ms>`.
  defp container(%{"package" => package, "version" => version})
       when is_binary(package) and is_binary(version),
       do: ["container=ncc-#{Portal.Builder.safe_name("#{package}-#{version}-")}*"]

  defp container(_args), do: []
end
