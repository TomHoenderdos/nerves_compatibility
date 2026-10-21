defmodule Portal.AdminEvents do
  @moduledoc """
  Tells open admin pages that what they list has changed. The message
  carries no data: a page refetches through its own query, so it never
  shows a row its filters would not return.

  A bulk rebuild changes thousands of requests within seconds, so pages
  refresh through `throttle/3`: at most once at the start of a burst and once
  at its end.
  """

  require Logger

  @topics %{queue: "admin:queue", sweeps: "admin:sweeps"}

  @type topic :: :queue | :sweeps

  @doc "Subscribe the calling process to one admin topic."
  @spec subscribe(topic()) :: :ok
  def subscribe(topic), do: Phoenix.PubSub.subscribe(Portal.PubSub, Map.fetch!(@topics, topic))

  @doc """
  Tell every subscriber of one admin topic that it changed.

  Callers include Oban workers (`Portal.Workers.RequestSync`) for whom this
  is a side note on a write that already committed, not the point of the job
  -- so a `Phoenix.PubSub` hiccup here is logged and swallowed rather than
  raised, and never turns a successful sync into a failed/retried job.
  """
  @spec broadcast(topic()) :: :ok
  def broadcast(topic) do
    Phoenix.PubSub.broadcast(Portal.PubSub, Map.fetch!(@topics, topic), {:admin_changed, topic})
    :ok
  rescue
    error ->
      Logger.warning("Portal.AdminEvents.broadcast(#{inspect(topic)}) failed: #{inspect(error)}")
      :ok
  end

  @doc """
  Leading + trailing throttle for a `{:admin_changed, topic}` handler.

  The first call in a window returns `:refresh`, so the caller can refetch
  immediately. Every other call inside the same window returns `:skip`, and
  the first of those schedules a single `{:admin_refresh, topic}` message to
  the caller for the end of the window, so a burst that keeps coming in still
  ends in one more refresh instead of none.
  """
  @spec throttle(Phoenix.LiveView.Socket.t(), topic(), pos_integer()) ::
          {:refresh | :skip, Phoenix.LiveView.Socket.t()}
  def throttle(socket, topic, interval_ms \\ 1000) do
    state = Map.get(socket.assigns, :admin_throttle, %{})
    now = System.monotonic_time(:millisecond)

    case Map.get(state, topic) do
      %{until: until} = entry when now < until ->
        entry = schedule_trailing_refresh(entry, topic, until - now)
        {:skip, put_throttle(socket, state, topic, entry)}

      _expired_or_absent ->
        entry = %{until: now + interval_ms, pending?: false}
        {:refresh, put_throttle(socket, state, topic, entry)}
    end
  end

  # The first `:skip` in a window schedules the trailing refresh and marks
  # itself pending; later calls in the same window see `pending?: true` and
  # leave the timer alone, so a burst schedules exactly one refresh.
  defp schedule_trailing_refresh(%{pending?: true} = entry, _topic, _delay_ms), do: entry

  defp schedule_trailing_refresh(entry, topic, delay_ms) do
    Process.send_after(self(), {:admin_refresh, topic}, delay_ms)
    %{entry | pending?: true}
  end

  defp put_throttle(socket, state, topic, entry) do
    Phoenix.Component.assign(socket, :admin_throttle, Map.put(state, topic, entry))
  end
end
