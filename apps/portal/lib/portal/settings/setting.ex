defmodule Portal.Settings.Setting do
  @moduledoc """
  Admin-editable runtime settings. One row, keyed `"global"`; read through
  `Portal.Settings.get/0`, which falls back to the defaults when no row exists
  yet so a fresh database never fails a build.

  The table's `publication_changes` column is no attribute here: a trigger
  alone writes it, counting each change to `host_native_enabled` or
  `deterministic_builds_enabled`, for
  `Portal.Catalog.precompiled_fingerprints/0` (see the migration that adds it).
  """

  use Ash.Resource,
    domain: Portal.Settings,
    data_layer: AshPostgres.DataLayer

  # argus_beam 0.25.0's named sets, then its analyses. Tied to the argus
  # version pinned in apps/ncc_worker/Dockerfile: an unknown name makes argus
  # exit 2 on every build, so this list is updated together with that pin.
  @analysis_names [
    :default,
    :otp,
    :security,
    :all,
    :startup,
    :shutdown,
    :blocking,
    :coupling,
    :mailbox,
    :failure,
    :structure,
    :races,
    :state_machine,
    :ets,
    :effects,
    :unsafe_input,
    :exposure,
    :coverage
  ]

  @doc "Every analysis and named set the admin form offers, in display order."
  def analysis_names, do: @analysis_names

  postgres do
    table("settings")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :upsert do
      accept([
        :key,
        :argus_enabled,
        :argus_analyses,
        :argus_scope,
        :argus_min_severity,
        :argus_timeout_seconds,
        :remote_mode,
        :remote_backlog_threshold,
        :remote_auto_on,
        :world_variants_enabled,
        :firmware_world_enabled,
        :host_native_enabled,
        :deterministic_builds_enabled
      ])

      upsert?(true)
      upsert_identity(:unique_key)
    end

    # Routing's automatic flag, written alone: a read-merge-write `upsert` from
    # the enqueue path could undo an admin save that landed in between.
    update :set_remote_auto_on do
      accept([:remote_auto_on])
    end
  end

  identities do
    identity(:unique_key, [:key])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      default("global")
      public?(true)
    end

    attribute :argus_enabled, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :argus_analyses, {:array, :atom} do
      allow_nil?(false)
      default([:default, :exposure])
      public?(true)
      constraints(min_length: 1, items: [one_of: @analysis_names])
    end

    attribute :argus_scope, :atom do
      allow_nil?(false)
      default(:firmware)
      public?(true)
      constraints(one_of: [:firmware, :all])
    end

    attribute :argus_min_severity, :atom do
      allow_nil?(false)
      default(:warning)
      public?(true)
      constraints(one_of: [:info, :warning, :error])
    end

    attribute :argus_timeout_seconds, :integer do
      allow_nil?(false)
      default(300)
      public?(true)
      constraints(min: 30, max: 1800)
    end

    attribute :remote_mode, :atom do
      allow_nil?(false)
      default(:auto)
      public?(true)
      constraints(one_of: [:auto, :on, :off])
    end

    attribute :remote_backlog_threshold, :integer do
      allow_nil?(false)
      default(10)
      public?(true)
      constraints(min: 0)
    end

    attribute :remote_auto_on, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Whether the toolchain backlog proposes world builds
    # (`Portal.Toolchains.worlds/0`). Off by default: turn it on only once
    # every node that runs portal code has a release that knows the world
    # variants, since an older one cannot read their rows.
    attribute :world_variants_enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Whether a firmware build asks the worker for the firmware world build
    # per passing target (`Portal.Settings.worker_firmware_world/1`,
    # `NCC_INPUT.firmware_world`). Off by default: turn it on only once the
    # web host runs a release that ingests world variants and every firmware
    # builder runs a worker image that builds them.
    attribute :firmware_world_enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Whether host-native builds (board #85, `Portal.HostNative`) are queued
    # and published: their manifest list, `builds_host_native`, and their
    # files. Off by default; stored rows stay when it is turned off, unserved.
    attribute :host_native_enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    # Whether toolchain and firmware builds are asked for their deterministic
    # siblings (`ERL_COMPILER_OPTIONS=deterministic`, `Portal.Deterministic`)
    # and siblings are published: a version's `deterministic` key and their
    # files. Off by default; stored rows stay when it is turned off, unserved.
    attribute :deterministic_builds_enabled, :boolean do
      allow_nil?(false)
      default(false)
      public?(true)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
