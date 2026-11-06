defmodule PortalWeb.BuilderEndpoint.StarterTest do
  # Real sockets on fixed ports: not async.
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  alias PortalWeb.BuilderEndpoint.Starter

  defmodule Plug200 do
    def init(o), do: o
    def call(conn, _), do: Plug.Conn.send_resp(conn, 200, "ok")
  end

  # A real Phoenix endpoint, so the test pins the error shape Phoenix and
  # Bandit really return for a port in use, not a guess at it.
  defmodule HeldEndpoint do
    use Phoenix.Endpoint, otp_app: :portal
    plug Plug200
  end

  defp free_port do
    {:ok, s} = :gen_tcp.listen(0, [:binary, reuseaddr: true, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(s)
    :gen_tcp.close(s)
    port
  end

  defp hold(port), do: :gen_tcp.listen(port, [:binary, reuseaddr: true, ip: {127, 0, 0, 1}])

  defp endpoint_child(port) do
    Application.put_env(:portal, HeldEndpoint,
      adapter: Bandit.PhoenixAdapter,
      server: true,
      http: [ip: {127, 0, 0, 1}, port: port],
      secret_key_base: String.duplicate("a", 64)
    )

    HeldEndpoint
  end

  defp eventually(fun, tries \\ 40) do
    if fun.() or tries == 0,
      do: fun.(),
      else:
        (
          Process.sleep(50)
          eventually(fun, tries - 1)
        )
  end

  test "a free port binds at once" do
    port = free_port()

    pid =
      start_supervised!({Starter, child: endpoint_child(port), name: :starter_free, retry_ms: 50})

    assert Starter.status(:starter_free) == :bound
    assert Process.alive?(pid)
  end

  test "a held port waits, then binds once released" do
    port = free_port()
    {:ok, held} = hold(port)

    log =
      capture_log(fn ->
        start_supervised!(
          {Starter, child: endpoint_child(port), name: :starter_held, retry_ms: 50}
        )

        assert {:waiting, %DateTime{}} = Starter.status(:starter_held)
        :gen_tcp.close(held)
        assert eventually(fn -> Starter.status(:starter_held) == :bound end)
      end)

    assert log =~ "port #{port} is in use"
  end

  test "the real Phoenix/Bandit start error for a port in use is recognised" do
    port = free_port()
    {:ok, held} = hold(port)
    on_exit(fn -> :gen_tcp.close(held) end)
    Process.flag(:trap_exit, true)

    assert {:error, reason} =
             Supervisor.start_link([endpoint_child(port)], strategy: :one_for_one)

    assert Starter.eaddrinuse?(reason), "unrecognised shape: #{inspect(reason)}"
  end

  test "any other start error stops the starter" do
    Process.flag(:trap_exit, true)
    bad = %{id: :bad, start: {Kernel, :apply, [fn -> {:error, :boom} end, []]}}
    assert {:error, _} = Starter.start_link(child: bad, name: :starter_bad)
  end

  test "warnings while waiting are rate-limited, not one per retry" do
    port = free_port()
    {:ok, held} = hold(port)
    on_exit(fn -> :gen_tcp.close(held) end)

    log =
      capture_log(fn ->
        start_supervised!(
          {Starter,
           child: endpoint_child(port), name: :starter_quiet, retry_ms: 10, warn_every_ms: 60_000}
        )

        Process.sleep(200)
      end)

    assert length(String.split(log, "is in use")) - 1 == 1
  end

  test "serving? false reports :off once started" do
    port = free_port()

    start_supervised!(
      {Starter, child: endpoint_child(port), name: :starter_off, serving?: fn -> false end}
    )

    assert Starter.status(:starter_off) == :off
  end

  test "status of a starter that is not running is :off" do
    assert Starter.status(:no_such_starter) == :off
  end

  test "eaddrinuse? walks nested tuples, lists, maps and strings" do
    assert Starter.eaddrinuse?({:shutdown, {:failed_to_start_child, :x, {:listen, :eaddrinuse}}})
    assert Starter.eaddrinuse?([{:a, %{reason: :eaddrinuse}}])
    assert Starter.eaddrinuse?("listen failed: :eaddrinuse")
    refute Starter.eaddrinuse?({:shutdown, {:failed_to_start_child, :x, :eacces}})
  end
end
