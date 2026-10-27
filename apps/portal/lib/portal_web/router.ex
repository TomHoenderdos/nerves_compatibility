defmodule PortalWeb.Router do
  use PortalWeb, :router

  import Oban.Web.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PortalWeb.Layouts, :root}
    plug :protect_from_forgery

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "base-uri 'self'; object-src 'none'; frame-ancestors 'self'"
    }
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  # `/api/openapi.json` only: `RenderSpec` reads the spec `PutApiSpec` names.
  pipeline :api_spec do
    plug :accepts, ["json"]
    plug OpenApiSpex.Plug.PutApiSpec, module: PortalWeb.ApiSpec
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

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "base-uri 'self'; object-src 'none'; frame-ancestors 'self'"
    }
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

    plug :put_secure_browser_headers, %{
      "content-security-policy" => "base-uri 'self'; object-src 'none'; frame-ancestors 'self'"
    }

    plug PortalWeb.Plugs.RequireLogin
  end

  scope "/", PortalWeb do
    pipe_through :browser

    live_session :public, on_mount: [{PortalWeb.UserAuth, :assign_current_user}] do
      live "/", DashboardLive, :index
      live "/packages", IndexLive, :index
      live "/packages/:name", PackageLive, :show
      live "/packages/:name/log/:system", LogLive, :show
      live "/failure_clusters", FailureClustersLive, :index
      live "/failing", TopFailingLive, :index
      # /warnings stays unrouted: WarningsLive is a placeholder that renders
      # "coming soon" and nothing else. Re-add this route and the nav link in
      # site_nav.ex once there are real warnings to show.
      live "/stats", StatsLive, :index
    end

    get "/badge/:name", CatalogApiController, :badge
    get "/requests/:id", RequestRedirectController, :show
    get "/request-scan", PageController, :request_scan
    get "/admin", PageController, :admin
    get "/admin/failures", PageController, :admin_failures
    get "/admin/argus", PageController, :admin_argus
    get "/admin/monitor", PageController, :oban_embed
    post "/admin/maintenance/revoke-run", PageController, :admin_revoke_run
    post "/admin/maintenance/toolchain-sweep", PageController, :admin_toolchain_sweep
    post "/admin/maintenance/repair-file-modes", PageController, :admin_repair_file_modes
    post "/admin/argus", PageController, :admin_argus_settings
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

    post "/auth/:provider/login", ProviderAuthController, :start_login
    post "/auth/:provider/login/complete", ProviderAuthController, :complete_login
    get "/auth/choose-username", ProviderAuthController, :choose_username
    post "/auth/choose-username", ProviderAuthController, :create_with_username
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
    post "/settings/password/set", PageController, :set_password

    post "/settings/providers/:provider/link", ProviderAuthController, :start_link
    post "/settings/providers/:provider/link/complete", ProviderAuthController, :complete_link
    post "/settings/providers/:provider/confirm", ProviderAuthController, :start_confirm

    post "/settings/providers/:provider/confirm/complete",
         ProviderAuthController,
         :complete_confirm

    post "/settings/providers/:provider/unlink", ProviderAuthController, :unlink

    # POST rather than DELETE for removals, matching the `post` admin routes
    # above: plain forms, no `data-method` JavaScript.
    get "/settings/security", SecurityController, :show
    post "/settings/security/reauth", SecurityController, :reauth
    post "/settings/security/passkeys/:id/delete", SecurityController, :delete_passkey
    post "/settings/security/totp/start", SecurityController, :start_totp
    post "/settings/security/totp/confirm", SecurityController, :confirm_totp
    post "/settings/security/totp/delete", SecurityController, :delete_totp
    post "/settings/security/recovery-codes", SecurityController, :regenerate_recovery_codes
    post "/settings/security/sign-out-everywhere", SecurityController, :sign_out_everywhere
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

    # `:on_mount` is not redundant with the `:admin` pipeline. The pipeline
    # runs on the initial HTTP request only; a LiveView reconnect is
    # authenticated by the signed session token from that dead render, which
    # LiveView honours for up to 14 days. Without the hook, an admin who had
    # this dashboard open before the passkey requirement shipped keeps
    # reconnecting to it. `Oban.Web.Router.__options__/2` appends its own
    # `Oban.Web.Authentication` after ours, so ours decides first.
    oban_dashboard("/oban", on_mount: [{PortalWeb.Plugs.RequireAdmin, :require_admin_passkey}])

    # Same reasoning as the Oban dashboard: the pipeline guards the first HTTP
    # request, the on_mount guards every LiveView reconnect after it.
    get "/argus/export.ndjson", PortalWeb.ArgusExportController, :export

    live_session :admin,
      on_mount: [
        {PortalWeb.UserAuth, :assign_current_user},
        {PortalWeb.Plugs.RequireAdmin, :require_admin_passkey}
      ] do
      live "/argus/findings", PortalWeb.Admin.ArgusFindingsLive, :index
      live "/users", PortalWeb.Admin.UsersLive, :index
      live "/queue", PortalWeb.Admin.QueueLive, :index
      live "/builders", PortalWeb.Admin.BuildersLive, :index
      live "/maintenance", PortalWeb.Admin.MaintenanceLive, :index
    end
  end

  # The API's own description: the machine-readable spec, and the same spec
  # rendered as an HTML page in the site layout. Neither is part of the spec
  # (`PortalWeb.ApiSpec.documented_routes/0` leaves them out).
  scope "/api" do
    pipe_through :api_spec

    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
  end

  scope "/api", PortalWeb do
    pipe_through :browser

    get "/docs", ApiDocsController, :index
  end

  # Every route in this scope must have an `operation` spec on its controller
  # action; `PortalWeb.ApiSpecTest` fails on one that does not.
  scope "/api", PortalWeb do
    pipe_through :api

    get "/packages/hex", PageController, :hex_package_search
    get "/precompiled/manifests/:package", CatalogApiController, :precompiled_manifest
    get "/precompiled/v2/manifests/:package", CatalogApiController, :precompiled_manifest_v2
    get "/precompiled/files/:sha256", CatalogApiController, :precompiled_file
    get "/precompiled/root.json", CatalogApiController, :precompiled_root
    get "/precompiled/batch.json", CatalogApiController, :precompiled_batch
    get "/precompiled/batches/:sequence", CatalogApiController, :precompiled_batch_history

    # Schema-v2 catalog JSON API (docs/INDEX_FORMAT.md). `/packages` is the
    # whole catalog; it is served from `Portal.Catalog.Cache`, so repeated hits
    # share one computation a minute instead of each loading the catalog.
    get "/packages", CatalogApiController, :packages
    get "/packages/:name", CatalogApiController, :package
    get "/stats", CatalogApiController, :stats
    get "/failing", CatalogApiController, :failing
  end
end
