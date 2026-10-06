defmodule Portal.Catalog.FindingTriage do
  @moduledoc """
  An admin's verdict on one argus finding, across every run that reports it.

  Keyed on `fingerprint/2`, which leaves the line number out so a finding that
  moves in a newer version is still the same row and keeps its status.
  Ingestion records each sighting through `:sighting`; admins set `:triage`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_finding_triage")
    repo(Portal.Repo)

    custom_indexes do
      index([:status])
      index([:package_name])
    end
  end

  actions do
    defaults([:read])

    # Upserts never touch what an admin decided: status, note, updated_by and
    # the version the finding was first seen in.
    create :sighting do
      accept([
        :fingerprint,
        :package_name,
        :analysis,
        :severity,
        :title,
        :file,
        :line,
        :finding,
        :first_seen_version,
        :last_seen_version,
        :last_seen_run_id
      ])

      upsert?(true)
      upsert_identity(:unique_fingerprint)
      upsert_fields([:severity, :line, :finding, :last_seen_version, :last_seen_run_id])
    end

    update :triage do
      accept([:status, :note, :updated_by])
    end
  end

  identities do
    identity(:unique_fingerprint, [:fingerprint])
  end

  attributes do
    uuid_primary_key(:id)

    attribute(:fingerprint, :string, allow_nil?: false, public?: true)
    attribute(:package_name, :string, allow_nil?: false, public?: true)
    attribute(:analysis, :string, allow_nil?: false, public?: true)
    attribute(:severity, :string, allow_nil?: false, public?: true)
    attribute(:title, :string, allow_nil?: false, public?: true)
    attribute(:file, :string, public?: true)
    attribute(:line, :integer, public?: true)
    attribute(:finding, :map, public?: true)

    attribute :status, :atom do
      allow_nil?(false)
      default(:new)
      public?(true)
      constraints(one_of: [:new, :confirmed, :false_positive, :reported, :ignored])
    end

    attribute(:note, :string, public?: true)
    attribute(:first_seen_version, :string, public?: true)
    attribute(:last_seen_version, :string, public?: true)
    attribute(:last_seen_run_id, :uuid, public?: true)
    attribute(:updated_by, :string, public?: true)

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  @doc "The identity of `finding` in `package_name`, independent of its line."
  @spec fingerprint(String.t(), map()) :: String.t()
  def fingerprint(package_name, finding) do
    [
      package_name,
      text(finding["analysis"]),
      text(finding["title"]),
      text(finding["file"]),
      text(finding["detail"])
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
end
