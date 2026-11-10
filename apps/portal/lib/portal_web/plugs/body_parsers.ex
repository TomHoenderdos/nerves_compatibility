defmodule PortalWeb.Plugs.BodyParsers do
  @moduledoc """
  The endpoint's `Plug.Parsers`, except on `/api/precompiled/reports`: those
  routes parse their own body after their rate limits, with a 256 KiB cap
  (`PortalWeb.Plugs.ReportBody`). Parsing it here first would read up to the
  default 8 MB of any client's body before a limit was checked.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["api", "precompiled", "reports" | _]} = conn, _opts), do: conn
  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
