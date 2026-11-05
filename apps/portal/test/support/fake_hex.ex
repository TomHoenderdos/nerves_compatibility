defmodule Portal.Test.FakeHex do
  @moduledoc """
  An in-process stand-in for the hex.pm API: Bandit on an ephemeral loopback
  port plus an Agent holding the answer for each request path and a log of
  the paths requested. Both are linked to the caller, so ExUnit stops them
  with the test.

  An answer is one of:

    * `{status, body}` - a JSON body (a map is encoded, a binary sent as is)
    * `:hang` - accept the request and never answer within the test
    * `:close` - drop the connection without a response

  A path with no answer gets a 404.
  """

  @type answer :: {pos_integer(), map() | binary()} | :hang | :close
  @type t :: %{agent: pid(), base_url: String.t()}

  @spec start(%{String.t() => answer()}) :: t()
  def start(answers \\ %{}) do
    {:ok, agent} = Agent.start_link(fn -> %{answers: answers, requests: []} end)

    {:ok, pid} =
      Bandit.start_link(
        plug: {Portal.Test.FakeHex.Plug, agent},
        scheme: :http,
        ip: {127, 0, 0, 1},
        port: 0,
        startup_log: false
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{agent: agent, base_url: "http://127.0.0.1:#{port}/api"}
  end

  @doc "The request paths seen so far, oldest first (the raw, still-encoded path)."
  @spec requests(t()) :: [String.t()]
  def requests(%{agent: agent}), do: agent |> Agent.get(& &1.requests) |> Enum.reverse()
end
