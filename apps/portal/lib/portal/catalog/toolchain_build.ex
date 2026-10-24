defmodule Portal.Catalog.ToolchainBuild do
  @moduledoc """
  One build of a pure-BEAM package version for one toolchain (Elixir minor /
  OTP major, e.g. `"1.19/28"`), for `Mix.install` users rather than Nerves
  targets.

  ## Why not a `Portal.Catalog.Run`

  Everything that shows a package's state reads its newest `Run`: package
  pages, stats, badges, and ingestion's carry of systems a partial run left
  out. A toolchain build is not a compatibility verdict for a Nerves target, so
  storing it as a run would let it become a package's "latest run" and replace
  real per-system results with a host-only build. Its own table keeps those
  readers unchanged.

  Its files are stored blobs like any run's (`Portal.Catalog.Artifact`), and
  `Portal.Catalog.ArtifactMembership` rows owned by this build record which
  blobs it produced.

  The identity is `(package_id, version, toolchain, builder_version)`: a new
  build of the same inputs replaces the row (`:upsert`), and bumping
  `builder_version` keeps older builds side by side.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  @mutable [
    :status,
    :reason,
    :elixir,
    :otp,
    :image_digest,
    :run_id,
    :deps_lock,
    :package_checksum,
    :compile_env,
    :file_manifest,
    :finished_at
  ]

  postgres do
    table("catalog_toolchain_builds")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id, :version])
      index([:toolchain, :status])
    end
  end

  actions do
    defaults([:read])

    create :create do
      accept([:package_id, :version, :toolchain, :builder_version | @mutable])
    end

    create :upsert do
      accept([:package_id, :version, :toolchain, :builder_version | @mutable])
      upsert?(true)
      upsert_identity(:unique_identity)
      # Every mutable field, so a rebuild fully replaces the previous outcome:
      # a field the new build leaves nil (a cleared `reason`) must not survive.
      # `revoked_at` is deliberately absent: a rebuild does not un-revoke.
      upsert_fields(@mutable)
    end

    update :revoke do
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_identity, [:package_id, :version, :toolchain, :builder_version])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :version, :string do
      allow_nil?(false)
      public?(true)
    end

    # `"<elixir minor>/<otp major>"`, e.g. `"1.19/28"`.
    attribute :toolchain, :string do
      allow_nil?(false)
      public?(true)
    end

    # Version of the build procedure. Bumped when the way builds are made
    # changes, so new builds do not overwrite ones made the old way.
    attribute :builder_version, :integer do
      allow_nil?(false)
      public?(true)
    end

    attribute :status, :atom do
      allow_nil?(false)
      public?(true)
      constraints(one_of: [:pass, :skipped, :error, :fail])
    end

    attribute :reason, :string do
      public?(true)
    end

    # Exact Elixir and OTP versions the build ran under.
    attribute :elixir, :string do
      public?(true)
    end

    attribute :otp, :string do
      public?(true)
    end

    attribute :image_digest, :string do
      public?(true)
    end

    # The worker's run id, linking the row to its build output.
    attribute :run_id, :string do
      public?(true)
    end

    # Same shape as `Portal.Catalog.Run.deps_lock`.
    attribute :deps_lock, :map do
      public?(true)
    end

    attribute :package_checksum, :string do
      public?(true)
    end

    attribute :compile_env, {:array, :map} do
      public?(true)
    end

    attribute :file_manifest, :map do
      public?(true)
    end

    attribute :finished_at, :utc_datetime_usec do
      public?(true)
    end

    # Set by an admin to pull the build's files from publication, as
    # `Portal.Catalog.Run.revoked_at`.
    attribute :revoked_at, :utc_datetime_usec do
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  relationships do
    belongs_to :package, Portal.Catalog.Package do
      allow_nil?(false)
      public?(true)
    end

    has_many :artifact_memberships, Portal.Catalog.ArtifactMembership do
      public?(true)
    end
  end
end
