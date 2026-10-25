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

    # `complete`'s multipart body is the sum of its part caps, 8 + 64 + 8 MiB:
    # result.json (`max_result_bytes`, 8 MiB), logs.tar.gz (`max_logs_bytes`,
    # 64 MiB; the agent drops an archive over 48 MiB) and the runner log, of
    # which the agent sends the last 1 MiB (the portal reads no more), the
    # rest of its 8 MiB being headroom for the multipart framing.
    plug Plug.Parsers,
      parsers: [:json, {:multipart, length: 83_886_080}],
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
    post "/jobs/:lease_id/files/missing", JobController, :missing
    put "/jobs/:lease_id/files", JobController, :files
    post "/jobs/:lease_id/complete", JobController, :complete
  end
end
