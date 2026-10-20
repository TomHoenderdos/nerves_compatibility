defmodule PortalWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  # Every request reaches the endpoint through Apache's mod_proxy_http, which
  # speaks HTTP/1.1 to it. Bandit's HTTP/2 is reachable only by whoever can
  # open the loopback port, and HTTP/2 has had its own advisories
  # (EEF-CVE-2026-105659, fixed in Bandit 1.13). Off, that stack is not
  # reachable at all, whatever the proxy becomes.
  test "the endpoint does not speak HTTP/2" do
    http = Application.fetch_env!(:portal, PortalWeb.Endpoint)[:http]
    assert http[:http_2_options][:enabled] == false
  end
end
