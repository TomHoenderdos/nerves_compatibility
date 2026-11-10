defmodule PortalWeb.Plugs.ReportBody do
  @moduledoc """
  The body parser of the miss report routes: a POST must be
  `application/json`, with no charset or `utf-8` (415 otherwise, a missing
  content type included), and at most 262,144 bytes, which `Plug.Parsers`
  refuses with 413 while reading, before any JSON is decoded. Other methods
  carry no body and pass.

  It runs after the routes' rate limits, which is why
  `PortalWeb.Plugs.BodyParsers` leaves these routes unread in the endpoint.
  A body something else already parsed would have skipped the cap, so it is
  refused with 413 whatever the method, rather than trusted.
  """

  @behaviour Plug

  import Plug.Conn

  @max_bytes 262_144

  @impl true
  def init(_opts),
    do: Plug.Parsers.init(parsers: [:json], pass: [], length: @max_bytes, json_decoder: Jason)

  @impl true
  def call(%Plug.Conn{body_params: %Plug.Conn.Unfetched{}} = conn, parsers) do
    cond do
      conn.method != "POST" -> conn
      json?(get_req_header(conn, "content-type")) -> Plug.Parsers.call(conn, parsers)
      true -> refuse(conn, 415, "content-type must be application/json (utf-8)")
    end
  end

  def call(conn, _parsers), do: refuse(conn, 413, "body read before its size was checked")

  defp refuse(conn, status, message) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: message}))
    |> halt()
  end

  defp json?([content_type]) do
    case Plug.Conn.Utils.content_type(content_type) do
      {:ok, "application", "json", params} -> utf8?(params)
      _ -> false
    end
  end

  defp json?(_headers), do: false

  defp utf8?(params) do
    case Map.fetch(params, "charset") do
      :error -> true
      {:ok, charset} -> String.downcase(charset) == "utf-8"
    end
  end
end
