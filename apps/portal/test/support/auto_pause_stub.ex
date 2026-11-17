defmodule Portal.AutoPauseStub do
  @moduledoc """
  Starts `Portal.Builder.AutoPause` under its own name for a worker test,
  against no Oban: every queue runs, every check still fails, and each pause
  or resume is sent to the test process as `{:auto_pause, action, queue}`.
  Only in `async: false` tests: the name is global.
  """

  import ExUnit.Callbacks, only: [start_supervised!: 1]

  alias Portal.Builder.AutoPause

  def start! do
    test = self()

    start_supervised!(
      {AutoPause,
       enabled: true,
       node: "portal@test",
       interval_ms: :timer.hours(1),
       probe: fn _check -> {:error, :still_failing} end,
       ops: %{
         check_queue: fn _queue -> %{paused: false} end,
         signal: fn action, queue, _id ->
           send(test, {:auto_pause, action, queue})
           :ok
         end,
         listen: fn -> :ok end,
         gossip: fn _payload -> :ok end
       }}
    )
  end

  @doc "Makes `Portal.Builder.AutoPause.probe(:docker)` answer as given, for this test."
  def docker_answers(up?) do
    previous = Application.get_env(:portal, AutoPause)
    answer = if up?, do: {:ok, "27.0"}, else: {:error, "Docker not available: down"}
    Application.put_env(:portal, AutoPause, docker_check: fn -> answer end)

    ExUnit.Callbacks.on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, AutoPause, previous),
        else: Application.delete_env(:portal, AutoPause)
    end)
  end

  @doc "The check `queue` is held paused for, or nil."
  def held_check(queue) do
    case AutoPause |> :sys.get_state() |> get_in([:held, queue]) do
      %{check: check} -> check
      nil -> nil
    end
  end
end
