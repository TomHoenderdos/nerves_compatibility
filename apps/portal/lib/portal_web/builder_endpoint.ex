defmodule PortalWeb.BuilderEndpoint do
  @moduledoc """
  The mTLS listener remote builders talk to (`Portal.Builders.Listener`
  configures its `https:`). JSON and multipart bodies only; no sessions, static
  files or sockets.
  """
  use Phoenix.Endpoint, otp_app: :portal

  plug Plug.RequestId
  plug Plug.Telemetry, event_prefix: [:phoenix, :builder_endpoint]

  # Body parsing lives in the router pipelines, after the certificate check,
  # so an unauthenticated client can never make the portal spool multipart.
  plug PortalWeb.BuilderRouter
end
