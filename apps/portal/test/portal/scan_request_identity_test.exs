defmodule Portal.ScanRequestIdentityTest do
  @moduledoc """
  Regression coverage for the account step the Hex.pm and GitHub scan flows
  now share: an identity only ever attaches to an account through a stored
  link, never through a name that happens to match.

  `Portal.HexPm.complete_owner_requests/3` and `Portal.GitHub.complete_repo_requests/3`
  cannot be driven end to end here without stubbing HTTP (device-flow polling,
  `users/me`, `/user`), which is deliberately out of scope. Instead this
  exercises the exact pieces those functions chain together --
  `identity_from_profile/1,2` (pure) and `Portal.Accounts.Identities.for_scan_request/2`
  (the account rule, already covered on its own in
  `Portal.Accounts.IdentitiesTest`) -- proving the old
  "same-named local account" takeover the fallback allowed is gone from the
  scan-request path too.
  """

  use Portal.DataCase, async: true

  import Portal.Test.AccountsFixtures

  alias Portal.Accounts.Identities

  describe "the Hex scan flow's account step" do
    test "a Hex.pm identity named like a local account does not attach to it" do
      local = user_fixture(%{username: "tom"})

      {:ok, identity} = Portal.HexPm.identity_from_profile(%{"username" => "tom"})

      assert {:ok, nil} = Identities.for_scan_request(identity, nil)

      {:ok, reloaded} = Portal.Accounts.get_user(local.id)
      refute reloaded.hex_username
    end

    test "a Hex.pm identity already linked signs the request in as its own account" do
      {:ok, owner} = Identities.link(user_fixture(), hex_identity("frank"))

      {:ok, identity} = Portal.HexPm.identity_from_profile(%{"username" => "frank"})

      assert {:ok, user} = Identities.for_scan_request(identity, nil)
      assert user.id == owner.id
    end
  end

  describe "the GitHub scan flow's account step" do
    test "a GitHub identity named like a local account does not attach to it" do
      local = user_fixture(%{username: "tom"})

      {:ok, identity} = Portal.GitHub.identity_from_profile(%{"id" => 7, "login" => "tom"}, "t")

      assert {:ok, nil} = Identities.for_scan_request(identity, nil)

      {:ok, reloaded} = Portal.Accounts.get_user(local.id)
      refute reloaded.github_id
    end
  end

  defp hex_identity(name),
    do: %Portal.Accounts.Identity{
      provider: :hex,
      uid: name,
      username: name,
      profile: %{"username" => name}
    }
end
