defmodule Portal.Repo.Migrations.CreatePortalStorage do
  use Ecto.Migration

  def change do
    create table(:portal_users, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :username, :text, null: false
      add :hex_username, :text
      add :hex_profile, :text, null: false, default: "{}"
      add :github_username, :text
      add :github_profile, :text, null: false, default: "{}"
      add :password_hash, :text, null: false
      add :last_hex_login_at, :utc_datetime
      add :last_github_login_at, :utc_datetime
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create unique_index(:portal_users, [:username])
    create index(:portal_users, [:hex_username])
    create index(:portal_users, [:github_username])

    create table(:portal_scan_requests, primary_key: false) do
      add :id, :uuid, primary_key: true, null: false
      add :package_name, :text, null: false
      add :version, :text
      add :source, :text, null: false
      add :status, :text, null: false
      add :user_id, :uuid
      add :subject, :text
      add :verification_provider, :text
      add :error_reason, :text
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create index(:portal_scan_requests, [:package_name, :status],
             name: :portal_scan_requests_package_status_index
           )

    create index(:portal_scan_requests, [:status])
    create index(:portal_scan_requests, [:source])
  end
end
