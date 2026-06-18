defmodule PortalWeb.Router do
  use PortalWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PortalWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PortalWeb do
    pipe_through :browser

    get "/", PageController, :request_scan
    get "/request-scan", PageController, :request_scan
    get "/admin", PageController, :admin
    post "/admin/requests/:id/approve", PageController, :approve_anonymous_request
    post "/admin/requests/:id/reject", PageController, :reject_anonymous_request
    get "/register", PageController, :register
    post "/register", PageController, :create_account
    get "/login", PageController, :login
    post "/login", PageController, :create_session
    post "/logout", PageController, :logout
    get "/auth/hex/start", PageController, :request_scan
    post "/auth/hex/start", PageController, :hex_start
    get "/auth/hex/complete", PageController, :request_scan
    post "/auth/hex/complete", PageController, :hex_complete
    post "/auth/github/start", PageController, :github_start
    get "/auth/github/complete", PageController, :request_scan
    post "/auth/github/complete", PageController, :github_complete
    post "/requests/anonymous", PageController, :anonymous_request
  end

  scope "/api", PortalWeb do
    pipe_through :api

    get "/packages/hex", PageController, :hex_package_search
  end
end
