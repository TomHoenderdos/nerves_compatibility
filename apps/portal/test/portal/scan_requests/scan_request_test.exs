defmodule Portal.ScanRequests.ScanRequestTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.ScanRequests.ScanRequest

  defmodule StubVersions do
    def latest_version(_package), do: {:ok, "9.9.9"}
  end

  defmodule MissingVersions do
    def latest_version(_package), do: {:error, :unknown_package}
  end

  setup do
    Application.put_env(:portal, :package_version_resolver, StubVersions)
    on_exit(fn -> Application.delete_env(:portal, :package_version_resolver) end)
    :ok
  end

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

    {:ok, request} =
      Portal.ScanRequests.create_once(%{
        package_name: "jason",
        source: :hex_owner,
        status: :accepted,
        user_id: user.id,
        subject: "owner",
        verification_provider: "hex_pm_oauth_device"
      })

    assert request.package_name == "jason"
    assert request.source == :hex_owner
    assert request.status == :queued
    assert request.user_id == user.id
    assert request.subject == "owner"

    assert_enqueued(
      worker: Portal.Workers.Build,
      args: %{"package" => "jason", "version" => "9.9.9", "scan_request_id" => request.id}
    )
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
    assert accepted.status == :queued
    assert accepted.source == :github_repo

    assert_enqueued(
      worker: Portal.Workers.Build,
      args: %{
        "package" => "dedupe_pkg",
        "version" => "9.9.9",
        "scan_request_id" => accepted.id
      }
    )

    matches =
      ScanRequest
      |> Ash.read!(domain: Portal.ScanRequests)
      |> Enum.filter(&(&1.package_name == "dedupe_pkg"))

    assert length(matches) == 1
  end

  test "approved anonymous requests enqueue local builds instead of forwarding externally" do
    {:ok, admin} =
      Portal.Accounts.seed_admin_user("approve_enqueue", "correct horse battery staple")

    {:ok, pending} =
      Portal.ScanRequests.create_once(%{
        package_name: "manual_pkg",
        source: :anonymous_manual,
        status: :pending,
        subject: "anonymous",
        verification_provider: "manual_review"
      })

    assert {:ok, request} = Portal.ScanRequests.approve_anonymous_request(pending.id, admin)
    assert request.status == :queued

    assert_enqueued(
      worker: Portal.Workers.Build,
      args: %{
        "package" => "manual_pkg",
        "version" => "9.9.9",
        "scan_request_id" => request.id
      }
    )
  end

  test "closes the request when hex has never heard of the package" do
    Application.put_env(:portal, :package_version_resolver, MissingVersions)

    assert {:error, :unknown_package} =
             Portal.ScanRequests.create_once(%{
               package_name: "no_such_package_at_all",
               source: :backfill
             })

    # The row is committed before the version lookup runs, so the failure has to
    # close it. An `:accepted` leftover is matched by `open_request_for_package/1`
    # forever after, which would stop the package being scanned if it ever ships.
    assert [%ScanRequest{status: :rejected}] =
             ScanRequest
             |> Ash.Query.filter(package_name == "no_such_package_at_all")
             |> Ash.read!(domain: Portal.ScanRequests)

    assert Portal.ScanRequests.open_request_for_package("no_such_package_at_all") == nil
  end
end
