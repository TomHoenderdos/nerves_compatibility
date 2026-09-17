defmodule Portal.Catalog.ArtifactMembership do
  @moduledoc """
  Records that one system result's file manifest includes one stored blob.

  `Portal.Catalog.Artifact` is a *registry*: one row per distinct sha256, saying
  "these bytes are on disk". This table is the *membership*: one row per
  (system result, sha256) pair, saying "this system's build produced that file".
  The two are separate because the relationship is many-to-many, and collapsing
  them into one table is what broke the precompiled manifest API.

  ## Why this table exists

  `catalog_artifacts` carried `system_result_id` as a plain column under a
  `UNIQUE(sha256)` index, and its upsert listed only `[:byte_size, :disk_path]`
  in `upsert_fields` — so on conflict the first writer kept ownership forever.
  A `.beam` file is very often byte-identical across targets (same source, same
  compiler, no target-specific codegen), so the second system to build it found
  the sha already claimed and recorded nothing at all.

  `Portal.Catalog.file_manifest/2` then filtered each system's published
  manifest down to the shas holding a row *for that system result*, so the
  second system's manifest came back empty. Measured on production 2026-09-16:
  of 303,882 (system result, sha) pairs in stored ebin manifests, only 85,806
  (28%) had their own row — the other 218,076 had the blob safely on disk,
  attributed to a different system. `circuits_gpio` 2.1.2 published nine ebin
  files for mangopi and zero for both rpi4 and x86_64, despite all three
  building the identical nine files.

  No bytes were ever lost, only the relation, which is why the backfill in
  `20260916*_add_artifact_memberships.exs` can reconstruct it from the manifests
  already stored in `catalog_system_results.beam_scan`.

  ## Scope

  A row here means the sha appears in that system result's own
  `beam_scan.footprint.file_manifest` — the package's files, which is what the
  precompiled API publishes. Ingestion also stores blobs for the package's
  *dependencies*, and those stay in the registry without a membership row: their
  per-file manifests are deliberately stripped before persisting (see
  `Portal.Catalog.Ingestion.drop_file_manifests/1`), so there is nothing to
  publish them against and no way to reconstruct them for historical rows.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_artifact_memberships")
    repo(Portal.Repo)

    custom_indexes do
      # Manifest reads come in by system result; the blob-side lookup answers
      # "who else references this sha", which is what any future orphan sweep
      # of the artifact store needs before it can delete a file.
      index([:system_result_id])
      index([:sha256])
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      accept([:sha256, :system_result_id])
    end

    create :upsert do
      accept([:sha256, :system_result_id])
      upsert?(true)
      upsert_identity(:unique_system_result_sha256)
      # Nothing to update on conflict: the pair *is* the whole row. Re-ingesting
      # a run must be a no-op here rather than an error.
      upsert_fields([:sha256])
    end
  end

  identities do
    identity(:unique_system_result_sha256, [:system_result_id, :sha256])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :sha256, :string do
      allow_nil?(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
  end

  relationships do
    belongs_to :system_result, Portal.Catalog.SystemResult do
      allow_nil?(false)
      public?(true)
    end
  end
end
