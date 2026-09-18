defmodule Portal.Accounts.WebAuthnTest do
  use ExUnit.Case, async: true

  alias Portal.Accounts.WebAuthn

  test "sets security-relevant defaults for WebAuthn challenge options" do
    opts = WebAuthn.opts()

    assert opts[:origin] == "http://localhost:4001"
    assert opts[:timeout] == 300
    assert opts[:user_verification] == "required"
    assert opts[:attestation] == "none"
  end

  test "includes allow_credentials as empty list in base options" do
    opts = WebAuthn.opts()

    assert Keyword.has_key?(opts, :allow_credentials)
  end

  test "merges caller-supplied options over defaults" do
    opts = WebAuthn.opts(allow_credentials: 60)

    assert opts[:allow_credentials] == 60
    assert opts[:timeout] == 300
    assert opts[:rp_id] == "localhost"
  end
end
