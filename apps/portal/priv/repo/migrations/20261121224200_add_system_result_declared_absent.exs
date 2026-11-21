defmodule Portal.Repo.Migrations.AddSystemResultDeclaredAbsent do
  @moduledoc """
  A `pure_elixir` system result's declared-absent probe record (otp-probe
  round 6, R5-6), from its run's `host_portability` trace, so the module
  index can re-check it as it does toolchain builds. A new nullable column,
  which the release running during the deploy window never names.
  """

  use Ecto.Migration

  def change do
    alter table(:catalog_system_results) do
      add :declared_absent, :map
    end
  end
end
