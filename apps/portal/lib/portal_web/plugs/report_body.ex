defmodule PortalWeb.Plugs.ReportBody do
  @moduledoc """
  The body parser of the miss report routes: a POST must be
  `application/json` (415 otherwise, a missing content type included) and at
  most 262,144 bytes, which `Plug.Parsers` refuses with 413 while reading,
  before any JSON is decoded. Other methods carry no body and pass.

  It runs after the routes' rate limits, which is why
  `PortalWeb.Plugs.BodyParsers` leaves these routes unread in the endpoint.
  """

  @behaviour Plug

  import Plug.Conn

  @max_bytes 262_144

  @impl true
  def init(_opts),
    do: Plug.Parsers.init(parsers: [:json], pass: [], length: @max_bytes, json_decoder: Jason)

  @impl true
  def call(%Plug.Conn{method: "POST"} = conn, parsers) do
    if json?(get_req_header(conn, "content-type")) do
      Plug.Parsers.call(conn, parsers)
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(415, ~s({"error":"content-type must be application/json"}))
      |> halt()
    end
  end

  def call(conn, _parsers), do: conn

  defp json?([content_type]) do
    match?({:ok, "application", "json", _params}, Plug.Conn.Utils.content_type(content_type))
  end

  defp json?(_headers), do: false
end
