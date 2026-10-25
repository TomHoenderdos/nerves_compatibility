defmodule NccWorker.EgressProbe do
  @moduledoc """
  The in-build half of the per-host egress check (isolation spec, section 3).

  With `NCC_INPUT.egress_probe` set, the worker tries a TCP connect to each
  target before any `mix` runs and records what happened, so an operator can
  see from a real build's `result.json` that the host's egress filter stops a
  build reaching a private address (`Portal.EgressCheck`). Advisory: it never
  changes a status or fails a run.

  A target is `%{"address" => ip_literal, "port" => 1..65535}`. An outcome is
  `"connected"` (nothing stopped it), `"refused"` (a reset came back, so the
  packet got through too), `"timeout"` (dropped, which is what the filter
  does), `"unreachable"` (no route, which is what IPv6 gets in a namespace
  without one), `"invalid_target"`, or the socket error's name.
  """

  @connect_timeout_ms 2_000

  @type target :: %{String.t() => String.t() | pos_integer()}
  @type outcome :: %{String.t() => String.t() | pos_integer() | nil}
  @type connect_fun ::
          (:inet.ip_address(), :inet.port_number(), timeout() ->
             :connected | {:error, term()})

  @doc "Probes every target; nil when there are none, so `result.json` has no key."
  @spec run([target()] | nil, connect_fun()) :: [outcome()] | nil
  def run(targets, connect \\ &connect/3)

  def run([_ | _] = targets, connect), do: Enum.map(targets, &probe(&1, connect))
  def run(_targets, _connect), do: nil

  @doc "Puts the outcomes on a successful run's result."
  @spec put_result({:ok, map()} | term(), [outcome()] | nil) :: {:ok, map()} | term()
  def put_result({:ok, result}, [_ | _] = outcomes),
    do: {:ok, Map.put(result, :egress_probe, outcomes)}

  def put_result(other, _outcomes), do: other

  @doc false
  @spec connect(:inet.ip_address(), :inet.port_number(), timeout()) ::
          :connected | {:error, term()}
  def connect(ip, port, timeout) do
    family = if tuple_size(ip) == 8, do: :inet6, else: :inet

    case :gen_tcp.connect(ip, port, [family, :binary, active: false], timeout) do
      {:ok, socket} ->
        :ok = :gen_tcp.close(socket)
        :connected

      {:error, _reason} = error ->
        error
    end
  end

  defp probe(%{"address" => address, "port" => port}, connect)
       when is_binary(address) and is_integer(port) and port in 1..65_535 do
    case :inet.parse_strict_address(String.to_charlist(address)) do
      {:ok, ip} ->
        %{
          "address" => address,
          "port" => port,
          "family" => if(tuple_size(ip) == 8, do: "inet6", else: "inet"),
          "outcome" => describe(connect.(ip, port, @connect_timeout_ms))
        }

      {:error, _reason} ->
        invalid(address, port)
    end
  end

  defp probe(%{"address" => address, "port" => port}, _connect) when is_binary(address),
    do: invalid(address, if(is_integer(port), do: port))

  defp probe(target, _connect), do: invalid(inspect(target), nil)

  defp invalid(address, port),
    do: %{"address" => address, "port" => port, "family" => nil, "outcome" => "invalid_target"}

  defp describe(:connected), do: "connected"
  defp describe({:error, :timeout}), do: "timeout"
  defp describe({:error, :econnrefused}), do: "refused"
  defp describe({:error, reason}) when reason in [:enetunreach, :ehostunreach], do: "unreachable"
  defp describe({:error, reason}) when is_atom(reason), do: Atom.to_string(reason)
  defp describe(other), do: inspect(other)
end
