defmodule PortalWeb.ContentSecurityPolicyTest do
  @moduledoc """
  Asserts the strict `content-security-policy` header
  `PortalWeb.Plugs.ContentSecurityPolicy` sets on every representative
  browser route, that the nonce it carries is the exact nonce on every inline
  `<script>` tag the page renders, and that no inline `<script>` tag ever
  renders without one.

  Not async: several tests toggle the `:portal, :umami_website_id`
  application env the plug and the root layout both read, the same
  precaution `PortalWeb.AnalyticsTagTest` takes.
  """
  use PortalWeb.ConnCase, async: false

  import Portal.Test.AccountsFixtures

  alias Portal.Catalog.Ingestion

  setup do
    previous = Application.get_env(:portal, :umami_website_id)
    on_exit(fn -> Application.put_env(:portal, :umami_website_id, previous) end)
    :ok
  end

  defp ingest_package(name) do
    result =
      Path.join([__DIR__, "..", "support", "fixtures", "result.json"])
      |> File.read!()
      |> Jason.decode!()
      |> put_in(["package", "name"], name)

    dir = Path.join(System.tmp_dir!(), "csp-test-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: "csp-test-#{name}-1",
        image_digest: "sha256:csp-test",
        files_dir: dir,
        scan_request_id: nil,
        log: "csp test log"
      })

    :ok
  end

  defp nonce_from_policy(policy) do
    [[_, nonce]] = Regex.scan(~r/'nonce-([^']+)'/, policy)
    nonce
  end

  defp inline_script_tags(html) do
    ~r/<script([^>]*)>/
    |> Regex.scan(html)
    |> Enum.map(fn [_, attrs] -> attrs end)
    |> Enum.reject(&(&1 =~ ~r/\ssrc=/))
  end

  # Common shape every representative page must satisfy: a strict header,
  # the same nonce on every inline script tag the page renders, and no
  # inline script tag that lacks one.
  defp assert_strict_csp(conn) do
    assert [policy] = get_resp_header(conn, "content-security-policy")
    assert policy =~ "base-uri 'self'"
    assert policy =~ "object-src 'none'"
    assert policy =~ "frame-ancestors 'self'"
    assert policy =~ ~r/script-src 'self' 'nonce-[^']+'/
    refute policy =~ "unsafe-inline"
    refute policy =~ "unsafe-eval"

    nonce = nonce_from_policy(policy)
    html = html_response(conn, 200)

    inline = inline_script_tags(html)
    assert inline != [], "expected at least one inline <script> tag (the theme boot script)"

    for attrs <- inline do
      assert attrs =~ ~s(nonce="#{nonce}"),
             "inline <script#{attrs}> is missing the request's nonce"
    end

    %{policy: policy, nonce: nonce, html: html}
  end

  test "home page", %{conn: conn} do
    assert_strict_csp(get(conn, ~p"/"))
  end

  test "package index", %{conn: conn} do
    assert_strict_csp(get(conn, ~p"/packages"))
  end

  test "package detail page", %{conn: conn} do
    ingest_package("csp_test_pkg")
    assert_strict_csp(get(conn, ~p"/packages/csp_test_pkg"))
  end

  test "login page", %{conn: conn} do
    assert_strict_csp(get(conn, ~p"/login"))
  end

  test "api docs page", %{conn: conn} do
    assert_strict_csp(get(conn, ~p"/api/docs"))
  end

  test "settings/security for a signed-in user", %{conn: conn} do
    user = user_fixture()
    conn = init_test_session(conn, user_id: user.id, login_method: :password)

    assert_strict_csp(get(conn, ~p"/settings/security"))
  end

  test "admin overview for an admin signed in with a passkey", %{conn: conn} do
    admin = admin_with_passkey_fixture()
    conn = init_test_session(conn, user_id: admin.id, login_method: :passkey)

    assert_strict_csp(get(conn, ~p"/admin"))
  end

  test "script-src allows the Umami host only when the tag can render", %{conn: conn} do
    Application.put_env(:portal, :umami_website_id, "site-id-123")
    %{policy: with_umami} = assert_strict_csp(get(conn, ~p"/"))
    assert with_umami =~ PortalWeb.Layouts.umami_script_host()

    Application.delete_env(:portal, :umami_website_id)
    %{policy: without_umami} = assert_strict_csp(get(conn, ~p"/"))
    refute without_umami =~ PortalWeb.Layouts.umami_script_host()
  end

  test "the Oban dashboard route is wired to read the same per-request nonce" do
    route =
      PortalWeb.Router.__routes__()
      |> Enum.find(&(&1.path == "/admin/oban"))

    assert %{metadata: %{phoenix_live_view: {_view, _action, _opts, %{extra: extra}}}} = route

    assert {Oban.Web.Router, :__session__, mfa_args} = extra.session

    # `__session__/8`'s 6th positional argument is the csp assign key;
    # `router.ex` passes `csp_nonce_assign_key: :csp_nonce` to `oban_dashboard/2`.
    assert Enum.at(mfa_args, 5) == :csp_nonce

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.assign(:csp_nonce, "probe-nonce")

    session = apply(Oban.Web.Router, :__session__, [conn | mfa_args])

    assert %{"csp_nonces" => %{img: "probe-nonce", style: "probe-nonce", script: "probe-nonce"}} =
             session
  end
end
