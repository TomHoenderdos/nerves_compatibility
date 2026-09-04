defmodule Portal.HexPmTest do
  use ExUnit.Case, async: true

  alias Portal.HexPm

  describe "scope/0" do
    test "requests read-only access" do
      assert HexPm.scope() == "api:read"
    end

    test "never requests write access" do
      # Hex.pm expands the bare "api" scope into api:read + api:write on its
      # consent screen. Portal only reads (GET /api/users/me), so widening this
      # would show users a write permission we never use and force 2FA on them.
      refute HexPm.scope() =~ "write"
      refute HexPm.scope() == "api"
    end
  end
end
