defmodule Portal.Repo.Migrations.AddArtifactMemberships do
  @moduledoc """
  Splits artifact ownership out of the content-addressed artifact registry, and
  reconstructs the ownership the old model threw away.

  `catalog_artifacts` carried `system_result_id` under a `UNIQUE(sha256)` index,
  so a blob could only ever belong to the first system result that produced it.
  Because a `.beam` is routinely byte-identical across targets, every later
  system recorded nothing and published an empty manifest. See
  `Portal.Catalog.ArtifactMembership`.

  Unusually for this repo, the data backfill runs inside the migration rather
  than as an on-demand module like `Portal.Catalog.ManifestBackfill`. Two
  reasons: it is purely additive, unlike that one, which deletes; and the drop
  below is only safe once it has run, so separating them would leave a window
  where ownership exists in neither place. Measured against production on
  2026-09-16 the recovery query plans at 5.7s over 11,636 system results.

  The reconstruction is possible at all because the per-file manifests are still
  stored in `catalog_system_results.beam_scan`, and the blobs themselves were
  never lost — only the relation between them.
  """

  use Ecto.Migration

  # Manifest entries for one system result, as (system_result_id, sha256) pairs.
  #
  # `jsonb_array_elements` raises on a non-array, and `beam_scan` is worker
  # output: a failed scan stores `%{"__errors__" => [...]}` where a manifest
  # would be. Every level is therefore type-checked rather than assumed.
  @manifest_pairs """
  SELECT DISTINCT sr.id AS system_result_id, e.value->>'sha256' AS sha256
  FROM catalog_system_results sr
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(sr.beam_scan->'footprint'->'file_manifest'->'ebin') = 'array'
      THEN sr.beam_scan->'footprint'->'file_manifest'->'ebin'
      ELSE '[]'::jsonb
    END
    ||
    CASE
      WHEN jsonb_typeof(sr.beam_scan->'footprint'->'file_manifest'->'priv') = 'array'
      THEN sr.beam_scan->'footprint'->'file_manifest'->'priv'
      ELSE '[]'::jsonb
    END
  ) e
  WHERE sr.system_pkg <> 'host'
    AND jsonb_typeof(e.value) = 'object'
    AND e.value->>'sha256' IS NOT NULL
  """

  def up do
    create table(:catalog_artifact_memberships, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sha256, :text, null: false)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(
        :system_result_id,
        references(:catalog_system_results,
          column: :id,
          name: "catalog_artifact_memberships_system_result_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end

    create(
      unique_index(:catalog_artifact_memberships, [:system_result_id, :sha256],
        name: "catalog_artifact_memberships_unique_system_result_sha256_index"
      )
    )

    create(index(:catalog_artifact_memberships, [:system_result_id]))

    create(index(:catalog_artifact_memberships, [:sha256]))

    # 1. Carry over the one membership per blob the old column did record.
    execute("""
    INSERT INTO catalog_artifact_memberships (id, sha256, system_result_id, inserted_at)
    SELECT gen_random_uuid(), a.sha256, a.system_result_id, now() AT TIME ZONE 'utc'
    FROM catalog_artifacts a
    ON CONFLICT (system_result_id, sha256) DO NOTHING
    """)

    # 2. Recover every membership `UNIQUE(sha256)` discarded. Joining against
    #    the registry keeps this honest: a membership is only written for a blob
    #    we actually hold, so a recovered manifest entry is always servable.
    execute("""
    INSERT INTO catalog_artifact_memberships (id, sha256, system_result_id, inserted_at)
    SELECT gen_random_uuid(), p.sha256, p.system_result_id, now() AT TIME ZONE 'utc'
    FROM (#{@manifest_pairs}) p
    JOIN catalog_artifacts a ON a.sha256 = p.sha256
    ON CONFLICT (system_result_id, sha256) DO NOTHING
    """)

    # Step 1 alone guarantees one membership per artifact row, so anything less
    # means the copy did not happen and the column below is still the only
    # record of ownership. Abort rather than drop it.
    execute("""
    DO $$
    DECLARE
      artifacts bigint;
      memberships bigint;
    BEGIN
      SELECT count(*) INTO artifacts FROM catalog_artifacts;
      SELECT count(*) INTO memberships FROM catalog_artifact_memberships;

      IF memberships < artifacts THEN
        RAISE EXCEPTION
          'artifact membership backfill produced % rows for % artifacts; refusing to drop catalog_artifacts.system_result_id',
          memberships, artifacts;
      END IF;
    END $$;
    """)

    alter table(:catalog_artifacts) do
      remove(:system_result_id)
    end

    drop_if_exists(index(:catalog_artifacts, [:system_result_id]))

    alter table(:catalog_runs) do
      add(:toolchain, :map)
    end
  end

  def down do
    alter table(:catalog_runs) do
      remove(:toolchain)
    end

    # Deliberately nullable, where the original column was `NOT NULL`.
    #
    # Going back cannot be faithful: the old shape holds one owner per blob and
    # this one holds many, so the down migration has to pick. It picks the
    # lowest system result id for determinism. Blobs with no membership at all —
    # dependency artifacts, which are stored but never published — would have no
    # owner to restore, and dropping those rows to satisfy `NOT NULL` would
    # destroy registry entries whose files are on disk. Leaving the column
    # nullable loses nothing instead.
    alter table(:catalog_artifacts) do
      add(
        :system_result_id,
        references(:catalog_system_results,
          column: :id,
          name: "catalog_artifacts_system_result_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    execute("""
    UPDATE catalog_artifacts a
    SET system_result_id = m.system_result_id
    FROM (
      SELECT sha256, min(system_result_id::text)::uuid AS system_result_id
      FROM catalog_artifact_memberships
      GROUP BY sha256
    ) m
    WHERE m.sha256 = a.sha256
    """)

    create(index(:catalog_artifacts, [:system_result_id]))

    drop_if_exists(index(:catalog_artifact_memberships, [:sha256]))

    drop_if_exists(index(:catalog_artifact_memberships, [:system_result_id]))

    drop(
      constraint(
        :catalog_artifact_memberships,
        "catalog_artifact_memberships_system_result_id_fkey"
      )
    )

    drop_if_exists(
      unique_index(:catalog_artifact_memberships, [:system_result_id, :sha256],
        name: "catalog_artifact_memberships_unique_system_result_sha256_index"
      )
    )

    drop(table(:catalog_artifact_memberships))
  end
end
