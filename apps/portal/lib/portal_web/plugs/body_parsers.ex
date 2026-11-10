defmodule PortalWeb.Plugs.BodyParsers do
  @moduledoc """
  The endpoint's `Plug.Parsers`, except on `/api/precompiled/reports`: those
  routes parse their own body after their rate limits, with a 256 KiB cap
  (`PortalWeb.Plugs.ReportBody`). Parsing it here first would read up to the
  default 8 MB of any client's body before a limit was checked. Segments are
  compared percent-decoded, as the router matches them.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(conn, opts) do
    if report_route?(conn.path_info), do: conn, else: Plug.Parsers.call(conn, opts)
  end

  # `path_info` is still percent-encoded, and the router decodes it before
  # matching: `/api/precompiled/%72eports` reaches the report routes too.
  defp report_route?(path_info) do
    match?(["api", "precompiled", "reports" | _], Enum.map(path_info, &decode/1))
  end

  defp decode(segment) do
    URI.decode(segment)
  rescue
    ArgumentError -> segment
  end
end
