defmodule Portal.Settings.Setting do
  @moduledoc """
  Admin-editable runtime settings. One row, keyed `"global"`; read through
  `Portal.Settings.get/0`, which falls back to the defaults when no row exists
  yet so a fresh database never fails a build.
  """

  use Ash.Resource,
    domain: Portal.Settings,
    data_layer: AshPostgres.DataLayer

  # argus_beam 0.20.1's named sets, then its analyses. Tied to the argus
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
        :argus_timeout_seconds
      ])

      upsert?(true)
      upsert_identity(:unique_key)
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

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
