defmodule PortalWeb.Router do
  use PortalWeb, :router

  import Oban.Web.Router

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

  # For endpoints a browser calls with `fetch`, not by navigating: they need a
  # session and a CSRF check like any other browser route, but they answer
  # JSON. `:browser` cannot serve them -- it opens with `plug :accepts,
  # ["html"]`, which 406s the `accept: application/json` that `webauthn.js`
  # sends, before the controller runs. Same hazard as the sitemap scope below,
  # opposite direction. Adding "json" to `:browser` instead would teach every
  # HTML route in the app to negotiate JSON, which is not a trade worth making
  # for two endpoints.
  pipeline :browser_json do
    plug :accepts, ["json"]
    plug :fetch_session
    # `PasskeyController` sets a flash for the page the browser navigates to
    # next, and `put_flash/3` raises "flash not fetched" without this. It is
    # `:fetch_live_flash` rather than `:fetch_flash` so the value lands in the
    # same session key `:browser` reads back.
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin do
    plug :browser
    plug PortalWeb.Plugs.RequireAdmin
  end

  pipeline :authenticated do
    plug :browser
    plug PortalWeb.Plugs.RequireLogin
  end

  # `:browser_json` for signed-in callers. Same reasoning as above: the four
  # `/settings/security` endpoints `webauthn.js` reaches with `fetch` answer
  # JSON, and `:authenticated` opens with `:browser`'s `plug :accepts,
  # ["html"]`, which raises `Phoenix.NotAcceptableError` on the `accept:
  # application/json` those calls send, before the controller ever runs.
  # `RequireLogin` is safe here only because `:fetch_live_flash` is above it —
  # it announces the bounce to `/login` with `put_flash/3`, which raises
  # without a fetched flash.
  pipeline :authenticated_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PortalWeb.Plugs.RequireLogin
  end

  scope "/", PortalWeb do
    pipe_through :browser

    live_session :public, on_mount: [{PortalWeb.UserAuth, :assign_current_user}] do
      live "/", DashboardLive, :index
      live "/packages", IndexLive, :index
      live "/packages/:name", PackageLive, :show
      live "/packages/:name/log/:system", LogLive, :show
      live "/requests/:id", RequestLive, :show
      live "/failure_clusters", FailureClustersLive, :index
      # /warnings stays unrouted: WarningsLive is a placeholder that renders
      # "coming soon" and nothing else. Re-add this route and the nav link in
      # site_nav.ex once there are real warnings to show.
      live "/stats", StatsLive, :index
    end

    get "/badge/:name", CatalogApiController, :badge
    get "/request-scan", PageController, :request_scan
    get "/admin", PageController, :admin
    get "/admin/monitor", PageController, :oban_embed
    post "/admin/requests/:id/approve", PageController, :approve_anonymous_request
    post "/admin/requests/:id/reject", PageController, :reject_anonymous_request
    post "/admin/requests/:id/priority", PageController, :reprioritise_request
    post "/admin/scan", PageController, :admin_queue_package
    post "/admin/update-check", PageController, :admin_update_check
    get "/register", PageController, :register
    post "/register", PageController, :create_account
    get "/login", PageController, :login
    post "/login", PageController, :create_session
    get "/login/totp", MfaController, :totp_challenge
    post "/login/totp", MfaController, :totp_verify
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

  scope "/", PortalWeb do
    pipe_through :browser_json

    post "/auth/passkey/challenge", PasskeyController, :login_challenge
    post "/auth/passkey/verify", PasskeyController, :login_verify
  end

  # No pipeline on purpose. `:browser` starts with `plug :accepts, ["html"]`,
  # which would 406 a crawler that asks for `application/xml`, and neither
  # response needs a session, flash or CSRF token. `robots.txt` moved out of
  # `PortalWeb.static_paths/0` to get here — see `SitemapController`.
  scope "/", PortalWeb do
    get "/sitemap.xml", SitemapController, :index
    get "/robots.txt", SitemapController, :robots
  end

  scope "/", PortalWeb do
    pipe_through :authenticated

    get "/settings", PageController, :settings
    post "/settings", PageController, :update_settings

    # POST rather than DELETE for removals, matching the
    # `post "/admin/requests/:id/approve"` convention above: plain forms, no
    # `data-method` JavaScript.
    get "/settings/security", SecurityController, :show
    post "/settings/security/reauth", SecurityController, :reauth
    post "/settings/security/passkeys/:id/delete", SecurityController, :delete_passkey
    post "/settings/security/totp/start", SecurityController, :start_totp
    post "/settings/security/totp/confirm", SecurityController, :confirm_totp
    post "/settings/security/totp/delete", SecurityController, :delete_totp
    post "/settings/security/recovery-codes", SecurityController, :regenerate_recovery_codes
  end

  scope "/", PortalWeb do
    pipe_through :authenticated_json

    post "/settings/security/reauth/passkey/challenge", SecurityController, :reauth_challenge
    post "/settings/security/reauth/passkey", SecurityController, :reauth_passkey
    post "/settings/security/passkeys/challenge", SecurityController, :registration_challenge
    post "/settings/security/passkeys", SecurityController, :create_passkey
  end

  scope "/admin" do
    pipe_through [:admin]

    oban_dashboard("/oban")
  end

  scope "/api", PortalWeb do
    pipe_through :api

    get "/packages/hex", PageController, :hex_package_search
    get "/precompiled/manifests/:package", CatalogApiController, :precompiled_manifest
    get "/precompiled/files/:sha256", CatalogApiController, :precompiled_file
    get "/packages", CatalogApiController, :packages
    get "/packages/:name", CatalogApiController, :package
    get "/stats", CatalogApiController, :stats
  end
end
