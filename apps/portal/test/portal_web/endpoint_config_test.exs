defmodule PortalWeb.EndpointConfigTest do
  use ExUnit.Case, async: true

  # Every request reaches the endpoint through Apache's mod_proxy_http, which
  # speaks HTTP/1.1 to it. Bandit's HTTP/2 is reachable only by whoever can
  # open the loopback port, and EEF-CVE-2026-105659 (stream deadlines reset
  # by a trickle of WINDOW_UPDATEs, unfixed in any Bandit release) is an
  # HTTP/2 bug. Off, it is not reachable at all, whatever the proxy becomes.
  test "the endpoint does not speak HTTP/2" do
    http = Application.fetch_env!(:portal, PortalWeb.Endpoint)[:http]
    assert http[:http_2_options][:enabled] == false
  end
end
