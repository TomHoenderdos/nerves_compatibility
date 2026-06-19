defmodule Portal.ScanRequests.ScanRequestTest do
  use Portal.DataCase, async: false

  alias Portal.ScanRequests.ScanRequest

  test "records verified Hex owner requests" do
    user =
      Portal.Accounts.User
      |> Ash.Changeset.for_create(:create, %{
        username: "owner_scan",
        hex_username: "owner_scan",
        hex_profile: Jason.encode!(%{"username" => "owner_scan"}),
        password_hash: Argon2.hash_pwd_salt("generated-internal-password")
      })
      |> Ash.create!(domain: Portal.Accounts)

    request =
      ScanRequest
      |> Ash.Changeset.for_create(:create, %{
        package_name: "jason",
        source: :hex_owner,
        status: :accepted,
        user_id: user.id,
        subject: "owner",
        verification_provider: "hex_pm_oauth_device"
      })
      |> Ash.create!(domain: Portal.ScanRequests)

    assert request.package_name == "jason"
    assert request.source == :hex_owner
    assert request.status == :accepted
    assert request.user_id == user.id
    assert request.subject == "owner"
  end

  test "promotes an open pending anonymous request instead of duplicating it" do
    {:ok, pending} =
      Portal.ScanRequests.create_once(%{
        package_name: "dedupe_pkg",
        source: :anonymous_manual,
        status: :pending,
        subject: "anonymous",
        verification_provider: "manual_review"
      })

    {:ok, accepted} =
      Portal.ScanRequests.create_once(%{
        package_name: "dedupe_pkg",
        source: :github_repo,
        status: :accepted,
        subject: "owner:repo/dedupe_pkg",
        verification_provider: "github_oauth_device"
      })

    assert accepted.id == pending.id
    assert accepted.status == :accepted
    assert accepted.source == :github_repo

    matches =
      ScanRequest
      |> Ash.read!(domain: Portal.ScanRequests)
      |> Enum.filter(&(&1.package_name == "dedupe_pkg"))

    assert length(matches) == 1
  end
end
