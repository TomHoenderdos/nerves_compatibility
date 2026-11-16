defmodule Portal.Catalog.HostNativeBuild do
  @moduledoc """
  One host-native build (board #85): a NIF package version built on one
  toolchain image (`"1.20/29"`) for one glibc Linux triple
  (`Compatibility.HostTriple`), whose beams and priv native files a client
  on that triple installs only when it opted in (`config :precompiled,
  host_native: true`), and which the portal publishes only while the
  `host_native_enabled` setting is on (`Portal.HostNative`).

  Its own table, never `Portal.Catalog.ToolchainBuild`'s: every reader of
  portable toolchain builds serves them to any OS and architecture, and none
  of them can ever serve one of these. Its files are stored blobs like any build's,
  owned through `Portal.Catalog.ArtifactMembership.host_native_build_id`.

  The identity is `(package_id, version, toolchain, triple, builder_version)`:
  a rebuild of the same inputs replaces the row. `elf_needs` is the portal's
  own reading of the published ELF files (`Portal.Precompiled.ElfFacts`),
  never the worker's; `native_files` and `origins` are the worker's facts,
  `origins` re-verified at ingest (`Portal.HostNative.Ingest`).
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  @mutable [
    :status,
    :reason,
    :elixir,
    :otp,
    :otp_full,
    :nif_version,
    :libc,
    :glibc,
    :image_digest,
    :run_id,
    :deps_lock,
    :package_checksum,
    :declared,
    :compile_env,
    :compile_env_rule,
    :compile_inputs,
    :file_manifest,
    :native_files,
    :origins,
    :elf_needs,
    :optional_deps,
    :judge_revision,
    :manager,
    :compile_observations,
    :finished_at
  ]

  postgres do
    table("catalog_host_native_builds")
    repo(Portal.Repo)

    custom_indexes do
      index([:package_id, :version])
    end
  end

  actions do
    defaults([:read])

    create :upsert do
      accept([:package_id, :version, :toolchain, :triple, :builder_version | @mutable])
      upsert?(true)
      upsert_identity(:unique_identity)
      # A rebuild fully replaces the outcome; `revoked_at` is not in it, so a
      # rebuild never un-revokes.
      upsert_fields(@mutable)
    end

    update :revoke do
      change(set_attribute(:revoked_at, &DateTime.utc_now/0))
    end
  end

  identities do
    identity(:unique_identity, [:package_id, :version, :toolchain, :triple, :builder_version])
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:version, :string, allow_nil?: false, public?: true)
    attribute(:toolchain, :string, allow_nil?: false, public?: true)
    attribute(:triple, :string, allow_nil?: false, public?: true)
    attribute(:builder_version, :integer, allow_nil?: false, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      constraints(one_of: [:pass, :skipped, :error, :fail])
      public?(true)
    end

    attribute(:reason, :string, public?: true)
    attribute(:elixir, :string, public?: true)
    attribute(:otp, :string, public?: true)
    attribute(:otp_full, :string, public?: true)
    attribute(:nif_version, :string, public?: true)
    attribute(:libc, :string, public?: true)
    attribute(:glibc, :string, public?: true)
    attribute(:image_digest, :string, public?: true)
    attribute(:run_id, :string, public?: true)
    attribute(:deps_lock, :map, public?: true)
    attribute(:package_checksum, :string, public?: true)
    attribute(:declared, {:array, :map}, public?: true)
    attribute(:compile_env, {:array, :map}, public?: true)
    attribute(:compile_env_rule, :integer, public?: true)
    attribute(:compile_inputs, {:array, :map}, public?: true)
    attribute(:file_manifest, :map, public?: true)
    attribute(:native_files, {:array, :map}, public?: true)
    attribute(:origins, {:array, :map}, public?: true)
    attribute(:elf_needs, :map, public?: true)
    attribute(:optional_deps, :map, public?: true)
    attribute(:judge_revision, :integer, public?: true)
    attribute(:manager, :string, public?: true)
    attribute(:compile_observations, :map, public?: true)
    attribute(:finished_at, :utc_datetime_usec, public?: true)
    attribute(:revoked_at, :utc_datetime_usec, public?: true)

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
