defmodule NccAgent.Test.FakeBlobs do
  @moduledoc """
  A plain-http stand-in for the L2 bucket behind the presigned URLs the
  portal offers (`NccAgent.BuildCache`): Bandit on a loopback port serving
  `put/3`'s bodies at their paths, any query string accepted. Every GET is
  reported to the test process as `{:blob_get, path, query}`.
  """

  @behaviour Plug

  import Plug.Conn

  @doc "Starts the server under the calling test; returns its base URL and agent."
  def start(test_pid) do
    {:ok, agent} = Agent.start_link(fn -> %{} end)

    pid =
      ExUnit.Callbacks.start_supervised!(
        {Bandit,
         plug: {__MODULE__, %{agent: agent, test_pid: test_pid}},
         scheme: :http,
         port: 0,
         ip: {127, 0, 0, 1},
         startup_log: false},
        id: make_ref()
      )

    {:ok, {_ip, port}} = ThousandIsland.listener_info(pid)
    %{url: "http://127.0.0.1:#{port}", agent: agent}
  end

  @doc "Serves `body` at `path` (`/bucket/slug/key.tar.gz`); `status` other than 200 answers that."
  def put(%{agent: agent}, path, body, status \\ 200),
    do: Agent.update(agent, &Map.put(&1, path, {status, body}))

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, %{agent: agent, test_pid: test_pid}) do
    send(test_pid, {:blob_get, conn.request_path, conn.query_string})

    case Agent.get(agent, &Map.get(&1, conn.request_path)) do
      {status, body} -> send_resp(conn, status, body)
      nil -> send_resp(conn, 404, "")
    end
  end
end
