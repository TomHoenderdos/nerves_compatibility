defmodule Portal.Test.FakeHex.Plug do
  @moduledoc "The plug behind `Portal.Test.FakeHex`."

  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(agent), do: agent

  @impl Plug
  def call(conn, agent) do
    path = conn.request_path

    answer =
      Agent.get_and_update(agent, fn state ->
        {Map.get(state.answers, path, {404, %{"message" => "Page not found"}}),
         %{state | requests: [path | state.requests]}}
      end)

    respond(conn, answer)
  end

  defp respond(conn, :hang) do
    Process.sleep(5_000)
    send_resp(conn, 504, "")
  end

  defp respond(_conn, :close) do
    # The handler process dies before writing anything, so the client sees
    # the connection drop with no response at all (a raise would get a 500).
    Process.exit(self(), :kill)
  end

  defp respond(conn, {status, body}) when is_map(body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp respond(conn, {status, body}) when is_binary(body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
  end
end
