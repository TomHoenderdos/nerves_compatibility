defmodule PortalWeb.BuilderRouter do
  @moduledoc "Routes of `PortalWeb.BuilderEndpoint`: open enrolment, everything else behind a client certificate."
  use PortalWeb, :router

  pipeline :open do
    plug :accepts, ["json"]

    plug Plug.Parsers,
      parsers: [:json],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 8_000_000
  end

  # The certificate is checked before any body is read.
  pipeline :builder_api do
    plug :accepts, ["json"]
    plug PortalWeb.Plugs.BuilderCert

    plug Plug.Parsers,
      parsers: [:json, {:multipart, length: 80_000_000}],
      pass: ["*/*"],
      json_decoder: Phoenix.json_library(),
      length: 8_000_000
  end

  scope "/builder/v1", PortalWeb.Builder do
    pipe_through :open
    get "/ca.pem", EnrolmentController, :ca
    post "/enroll", EnrolmentController, :enroll
  end

  scope "/builder/v1", PortalWeb.Builder do
    pipe_through :builder_api
    post "/renew", EnrolmentController, :renew
    post "/status", EnrolmentController, :status
    post "/jobs/claim", JobController, :claim
    post "/jobs/:lease_id/heartbeat", JobController, :heartbeat
  end
end
