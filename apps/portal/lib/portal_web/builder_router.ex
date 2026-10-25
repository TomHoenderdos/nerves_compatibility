defmodule PortalWeb.BuilderRouter do
  @moduledoc "Routes of `PortalWeb.BuilderEndpoint`: open enrolment, everything else behind a client certificate."
  use PortalWeb, :router

  pipeline :open do
    plug :accepts, ["json"]
  end

  pipeline :builder_api do
    plug :accepts, ["json"]
    plug PortalWeb.Plugs.BuilderCert
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
  end
end
