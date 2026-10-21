defmodule Portal.AdminEventsTest do
  use ExUnit.Case, async: true
  alias Portal.AdminEvents

  test "broadcast reaches subscribers of that topic only" do
    :ok = AdminEvents.subscribe(:queue)
    :ok = AdminEvents.broadcast(:sweeps)
    :ok = AdminEvents.broadcast(:queue)
    assert_receive {:admin_changed, :queue}
    refute_receive {:admin_changed, :sweeps}
  end

  test "an unknown topic raises instead of being swallowed as a PubSub failure" do
    assert_raise KeyError, fn -> AdminEvents.broadcast(:nope) end
  end

  test "a burst refreshes once now and once at the end of the window" do
    # A window wide enough that 500 trivial map/reduce calls land inside it
    # even when the test suite's other async cases are contending for the
    # scheduler -- a 50ms window (as sketched in the brief) occasionally lost
    # that race under full-suite load and made this test flaky.
    interval_ms = 300
    socket = %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}}}
    {first, socket} = AdminEvents.throttle(socket, :queue, interval_ms)
    assert first == :refresh

    {results, _socket} =
      Enum.map_reduce(1..500, socket, fn _, s -> AdminEvents.throttle(s, :queue, interval_ms) end)

    assert Enum.all?(results, &(&1 == :skip))
    assert_receive {:admin_refresh, :queue}, 1000
    refute_receive {:admin_refresh, :queue}, 200
  end
end
