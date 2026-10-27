defmodule NccWorker.EgressProbeTest do
  use ExUnit.Case, async: true

  alias NccWorker.EgressProbe

  test "no targets means no probe and no result key" do
    assert EgressProbe.run(nil) == nil
    assert EgressProbe.run([]) == nil
    assert EgressProbe.put_result({:ok, %{run_id: "r"}}, nil) == {:ok, %{run_id: "r"}}
  end

  test "a listening port reports connected: the filter is missing" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)

    assert [
             %{
               "address" => "127.0.0.1",
               "port" => ^port,
               "family" => "inet",
               "outcome" => "connected"
             }
           ] = EgressProbe.run([%{"address" => "127.0.0.1", "port" => port}])

    :ok = :gen_tcp.close(listen)
  end

  test "a closed port reports refused: a reset came back, so the packet got through" do
    {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)

    assert [%{"outcome" => "refused"}] =
             EgressProbe.run([%{"address" => "127.0.0.1", "port" => port}])
  end

  test "a drop times out and a missing route is unreachable, over v4 and v6" do
    connect = fn
      {100, 64, 0, 1}, 5432, 2_000 -> {:error, :timeout}
      {0xFD7A, 0x115C, 0xA1E0, 0, 0, 0, 0, 1}, 5432, 2_000 -> {:error, :enetunreach}
    end

    assert [
             %{"address" => "100.64.0.1", "family" => "inet", "outcome" => "timeout"},
             %{"address" => "fd7a:115c:a1e0::1", "family" => "inet6", "outcome" => "unreachable"}
           ] =
             EgressProbe.run(
               [
                 %{"address" => "100.64.0.1", "port" => 5432},
                 %{"address" => "fd7a:115c:a1e0::1", "port" => 5432}
               ],
               connect
             )
  end

  test "names, bad ports and junk are invalid targets and are never dialled" do
    connect = fn _ip, _port, _timeout -> flunk("dialled an invalid target") end

    outcomes =
      EgressProbe.run(
        [
          %{"address" => "db.internal", "port" => 5432},
          %{"address" => "10.0.0.1", "port" => 0},
          %{"address" => "10.0.0.1", "port" => "5432"},
          "junk"
        ],
        connect
      )

    assert Enum.map(outcomes, & &1["outcome"]) == List.duplicate("invalid_target", 4)
  end

  test "put_result/2 adds the outcomes to a result and passes an error through" do
    outcomes = [
      %{"address" => "10.0.0.1", "port" => 1, "family" => "inet", "outcome" => "timeout"}
    ]

    assert {:ok, %{egress_probe: ^outcomes}} = EgressProbe.put_result({:ok, %{}}, outcomes)
    assert {:error, :boom} = EgressProbe.put_result({:error, :boom}, outcomes)
  end
end
