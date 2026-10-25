defmodule PortalWeb.BuilderEndpoint do
  @moduledoc """
  The mTLS listener remote builders talk to (`Portal.Builders.Listener`
  configures its `https:`). JSON and raw bodies only; no sessions, static
  files or sockets.
  """
  use Phoenix.Endpoint, otp_app: :portal

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :builder_endpoint]

  plug Plug.Parsers,
    parsers: [:json, {:multipart, length: 80_000_000}],
    pass: ["*/*"],
    json_decoder: Phoenix.json_library(),
    length: 8_000_000

  plug PortalWeb.BuilderRouter
end
