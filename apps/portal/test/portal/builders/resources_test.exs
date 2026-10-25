defmodule Portal.Builders.ResourcesTest do
  use Portal.DataCase, async: false

  alias Portal.Builders.{Builder, BuilderCertificate, EnrolmentToken, Lease}
  alias Portal.Catalog.Run

  defp builder!(attrs \\ %{}) do
    Builder
    |> Ash.Changeset.for_create(
      :enrol,
      Map.merge(
        %{
          name: "box-#{System.unique_integer([:positive])}",
          fingerprint: "fp#{System.unique_integer([:positive])}",
          cert_pem: "pem",
          cert_expires_at: DateTime.add(DateTime.utc_now(), 365, :day),
          slots: 2,
          last_version: "1.a",
          enrolled_at: DateTime.utc_now()
        },
        attrs
      )
    )
    |> Ash.create!(domain: Portal.Builders)
  end

  defp enrol(attrs) do
    Builder
    |> Ash.Changeset.for_create(
      :enrol,
      Map.merge(
        %{cert_pem: "p", cert_expires_at: DateTime.utc_now(), enrolled_at: DateTime.utc_now()},
        attrs
      )
    )
    |> Ash.create(domain: Portal.Builders)
  end

  test "a builder enrols unpublished and can be revoked" do
    builder = builder!()
    assert builder.publishing == false
    assert builder.status == :enrolled

    revoked =
      builder |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Portal.Builders)

    assert revoked.status == :revoked
    assert %DateTime{} = revoked.revoked_at
  end

  test "names and fingerprints are unique" do
    builder = builder!(%{name: "dup", fingerprint: "f1"})
    assert {:error, _} = enrol(%{name: "dup", fingerprint: "f2"})
    assert {:error, _} = enrol(%{name: "other", fingerprint: builder.fingerprint})
  end

  test "certificates, tokens and leases hang off a builder" do
    builder = builder!()

    cert =
      BuilderCertificate
      |> Ash.Changeset.for_create(:create, %{
        builder_id: builder.id,
        fingerprint: "old",
        issued_at: DateTime.utc_now(),
        expires_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    superseded =
      cert |> Ash.Changeset.for_update(:supersede, %{}) |> Ash.update!(domain: Portal.Builders)

    assert %DateTime{} = superseded.superseded_at

    token =
      EnrolmentToken
      |> Ash.Changeset.for_create(:create, %{
        token_hash: "h",
        name: "n",
        created_by: "admin",
        expires_at: DateTime.utc_now()
      })
      |> Ash.create!(domain: Portal.Builders)

    used =
      token
      |> Ash.Changeset.for_update(:use, %{builder_id: builder.id})
      |> Ash.update!(domain: Portal.Builders)

    assert used.builder_id == builder.id
    assert %DateTime{} = used.used_at

    expired =
      used |> Ash.Changeset.for_update(:expire_now, %{}) |> Ash.update!(domain: Portal.Builders)

    assert DateTime.compare(expired.expires_at, DateTime.utc_now()) == :lt

    older =
      superseded
      |> Ash.Changeset.for_update(:update_superseded_at, %{
        superseded_at: DateTime.add(DateTime.utc_now(), -3600, :second)
      })
      |> Ash.update!(domain: Portal.Builders)

    assert DateTime.compare(older.superseded_at, superseded.superseded_at) == :lt

    lease =
      Lease
      |> Ash.Changeset.for_create(:create, %{
        package: "jason",
        version: "1.4.4",
        image_name: "ghcr.io/x/ncc-worker",
        image_digest: "sha256:abc",
        args: %{"package" => "jason"},
        priority: 3
      })
      |> Ash.create!(domain: Portal.Builders)

    assert lease.state == :queued
    assert lease.attempt == 0
    assert lease.max_attempts == 3
    assert lease.bytes_uploaded == 0

    leased =
      lease
      |> Ash.Changeset.for_update(:update, %{
        state: :leased,
        builder_id: builder.id,
        leased_at: DateTime.utc_now(),
        heartbeat_at: DateTime.utc_now(),
        phase: "build",
        log_tail: "x",
        attempt: 1,
        run_id: "r",
        bytes_uploaded: 5,
        error: nil
      })
      |> Ash.update!(domain: Portal.Builders)

    assert leased.state == :leased
    assert leased.builder_id == builder.id
  end

  test "a run may name its builder" do
    builder = builder!()

    {:ok, package} =
      Portal.Catalog.Package
      |> Ash.Changeset.for_create(:upsert, %{name: "jason", description: "d"})
      |> Ash.create(domain: Portal.Catalog)

    run =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "r1",
        package_id: package.id,
        version_tested: "1.4.4",
        image_digest: "sha256:x",
        builder_id: builder.id
      })
      |> Ash.create!(domain: Portal.Catalog)

    assert run.builder_id == builder.id
  end

  test "settings carry the remote routing policy" do
    settings = Portal.Settings.get()
    assert settings.remote_mode == :auto
    assert settings.remote_backlog_threshold == 10
    assert settings.remote_auto_on == false
    {:ok, saved} = Portal.Settings.save(%{remote_mode: :on, remote_backlog_threshold: 3})
    assert saved.remote_mode == :on
    assert saved.remote_backlog_threshold == 3
    assert Portal.Settings.get().argus_enabled == true
  end
end
