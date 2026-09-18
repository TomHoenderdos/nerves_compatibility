defmodule Portal.Accounts.WebAuthnTest do
  use ExUnit.Case, async: true

  alias Portal.Accounts.WebAuthn

  test "base options come from config and pin the security-relevant values" do
    opts = WebAuthn.opts()

    assert opts[:rp_id] == "localhost"
    assert opts[:origin] == "http://localhost:4001"
    assert opts[:user_verification] == "required"
    assert opts[:attestation] == "none"
    assert opts[:timeout] == 300
  end

  test "never supplies its own challenge bytes" do
    # wax_'s security notes call a caller-supplied challenge a replay window.
    refute Keyword.has_key?(WebAuthn.opts(), :bytes)
    refute Keyword.has_key?(WebAuthn.opts(allow_credentials: []), :bytes)
  end

  test "extra options merge over the defaults" do
    opts = WebAuthn.opts(allow_credentials: [], timeout: 60)

    assert opts[:allow_credentials] == []
    assert opts[:timeout] == 60
    assert opts[:rp_id] == "localhost"
  end
end
