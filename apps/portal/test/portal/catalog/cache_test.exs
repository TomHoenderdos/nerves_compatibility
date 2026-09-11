defmodule Portal.Catalog.CacheTest do
  # Not async: these drive `Portal.Catalog.Cache`'s TTL through the application
  # environment, and the cache itself is a singleton with one shared ETS table.
  use ExUnit.Case, async: false

  alias Portal.Catalog.Cache

  setup do
    original = Application.get_env(:portal, Cache, [])
    Cache.flush()

    on_exit(fn ->
      Application.put_env(:portal, Cache, original)
      Cache.flush()
    end)

    :ok
  end

  defp set_ttl(ms), do: Application.put_env(:portal, Cache, ttl_ms: ms)

  # Every test needs its own key: the table is shared and `on_exit` flushing
  # does not help a test that runs while another is mid-refresh.
  defp key(name), do: {name, System.unique_integer([:positive])}

  defp counting_fun(value) do
    test = self()

    fn ->
      send(test, {:computed, value})
      value
    end
  end

  describe "with the cache disabled (ttl_ms: 0)" do
    test "calls through on every fetch and stores nothing" do
      set_ttl(0)
      k = key(:disabled)

      assert Cache.fetch(k, counting_fun(:a)) == :a
      assert Cache.fetch(k, counting_fun(:b)) == :b

      assert_received {:computed, :a}
      assert_received {:computed, :b}
    end
  end

  describe "with a live TTL" do
    test "computes once and serves the cached value afterwards" do
      set_ttl(:timer.seconds(60))
      k = key(:fresh)

      assert Cache.fetch(k, counting_fun(:first)) == :first
      assert_received {:computed, :first}

      # A different function body proves the second call never ran.
      assert Cache.fetch(k, counting_fun(:second)) == :first
      refute_received {:computed, :second}
    end

    test "distinct keys do not share an entry" do
      set_ttl(:timer.seconds(60))

      assert Cache.fetch(key(:one), fn -> :one end) == :one
      assert Cache.fetch(key(:two), fn -> :two end) == :two
    end

    test "serves the stale value immediately and refreshes behind it" do
      set_ttl(20)
      k = key(:stale)

      assert Cache.fetch(k, counting_fun(:old)) == :old
      assert_received {:computed, :old}

      Process.sleep(50)

      # The stale value comes back without waiting for the recomputation...
      assert Cache.fetch(k, counting_fun(:new)) == :old
      # ...which then runs in the background.
      assert_receive {:computed, :new}, 1_000

      set_ttl(:timer.seconds(60))
      assert Cache.fetch(k, counting_fun(:unused)) == :new
      refute_received {:computed, :unused}
    end

    test "concurrent callers for one key share a single computation" do
      set_ttl(:timer.seconds(60))
      k = key(:stampede)
      test = self()

      slow = fn ->
        send(test, :computing)
        Process.sleep(100)
        :shared
      end

      results =
        1..5
        |> Enum.map(fn _ -> Task.async(fn -> Cache.fetch(k, slow) end) end)
        |> Task.await_many(5_000)

      assert results == List.duplicate(:shared, 5)

      assert_received :computing
      refute_received :computing
    end
  end

  describe "when the computation raises" do
    setup do
      set_ttl(:timer.seconds(60))
      :ok
    end

    test "re-raises in the caller rather than in the cache" do
      assert_raise RuntimeError, "boom", fn ->
        Cache.fetch(key(:raising), fn -> raise "boom" end)
      end
    end

    test "keeps the cache process alive so the next page load still works" do
      pid = Process.whereis(Cache)

      assert_raise RuntimeError, fn -> Cache.fetch(key(:raising), fn -> raise "boom" end) end

      assert Process.alive?(pid)
      assert Process.whereis(Cache) == pid
      assert Cache.fetch(key(:after_raise), fn -> :works end) == :works
    end

    # A `catch`/`rescue` placed around the whole of `fetch/2` rather than around
    # the table access alone swallows this and runs the computation a second
    # time -- an ArgumentError is exactly what a missing ETS table raises.
    test "an ArgumentError from the computation propagates and does not re-run it" do
      test = self()

      assert_raise ArgumentError, "from the computation", fn ->
        Cache.fetch(key(:arg_error), fn ->
          send(test, :ran)
          raise ArgumentError, "from the computation"
        end)
      end

      assert_received :ran
      refute_received :ran
    end

    test "does not cache the failure" do
      k = key(:retry)

      assert_raise RuntimeError, fn -> Cache.fetch(k, fn -> raise "boom" end) end
      assert Cache.fetch(k, fn -> :recovered end) == :recovered
    end
  end

  # `Task.async` would link the computation to the cache, so a kill from outside
  # would take the cache -- and every entry in the table -- down with it. A slow
  # dashboard query is a bad page; a dead cache process is a broken one.
  test "a killed computation fails its waiters without taking down the cache" do
    set_ttl(:timer.seconds(60))
    k = key(:killed)
    test = self()
    cache = Process.whereis(Cache)

    spawn(fn ->
      outcome =
        try do
          {:ok,
           Cache.fetch(k, fn ->
             send(test, {:computing, self()})
             Process.sleep(30_000)
             :never_returned
           end)}
        catch
          kind, reason -> {:failed, kind, reason}
        end

      send(test, {:caller_done, outcome})
    end)

    assert_receive {:computing, computing_pid}, 2_000
    Process.exit(computing_pid, :kill)

    # The caller is failed rather than left blocked on a reply that never comes.
    assert_receive {:caller_done, {:failed, :exit, :killed}}, 2_000

    assert Process.alive?(cache)
    assert Process.whereis(Cache) == cache
    assert Cache.fetch(key(:after_kill), fn -> :still_works end) == :still_works
  end

  test "flush/0 drops cached entries" do
    set_ttl(:timer.seconds(60))
    k = key(:flushed)

    assert Cache.fetch(k, counting_fun(:before)) == :before
    Cache.flush()

    assert Cache.fetch(k, counting_fun(:after)) == :after
    assert_received {:computed, :after}
  end
end
