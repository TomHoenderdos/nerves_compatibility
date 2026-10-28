defmodule PortalWeb.Plugs.ContentSecurityPolicy do
  @moduledoc """
  Sets a strict `content-security-policy` response header with a fresh
  per-request nonce, and assigns that nonce as `:csp_nonce` so a template can
  put it on the one inline `<script>` tag that still has to run before
  `app.js` loads (the dark/light theme boot in `root.html.heex`).

  `script-src` is `'self'` plus the nonce -- never `'unsafe-inline'` or
  `'unsafe-eval'`. The only other script origin this app ever loads is the
  Umami analytics tag (`PortalWeb.Layouts.umami_script_host/0`), added only
  when that tag can actually render (an `UMAMI_WEBSITE_ID` is configured), so
  a deployment with it turned off gets the tighter policy for free.

  `Oban.Web.Router.oban_dashboard/2` is mounted with `csp_nonce_assign_key:
  :csp_nonce` in the router, so it reads the same assign to nonce its own
  (entirely separate) root layout's inline theme-boot script and bundled
  `<script src>` tag. One nonce authorises every inline script this app or
  that dependency renders for a given request.

  Place this plug after `plug :put_secure_browser_headers` in a pipeline:
  that plug already sets a default `content-security-policy`, and this one
  always overwrites it with the fuller, per-request policy below.
  """

  import Plug.Conn

  @base_uri "base-uri 'self'"
  @object_src "object-src 'none'"
  # `'self'` rather than `'none'`: `/admin/monitor` frames `/admin/oban` in an
  # iframe from the same origin, so tightening this further would blank that
  # embed while `/admin/oban` on its own stays reachable full-screen.
  @frame_ancestors "frame-ancestors 'self'"

  def init(opts), do: opts

  def call(conn, _opts) do
    nonce = nonce()

    script_src = Enum.join(["'self'", "'nonce-#{nonce}'" | extra_script_src()], " ")

    policy =
      Enum.join([@base_uri, @object_src, @frame_ancestors, "script-src " <> script_src], "; ")

    conn
    |> assign(:csp_nonce, nonce)
    |> put_resp_header("content-security-policy", policy)
  end

  defp nonce, do: Base.encode64(:crypto.strong_rand_bytes(16))

  defp extra_script_src do
    if Application.get_env(:portal, :umami_website_id) do
      [PortalWeb.Layouts.umami_script_host()]
    else
      []
    end
  end
end
