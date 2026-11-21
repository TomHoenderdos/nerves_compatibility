defmodule Portal.Repo.Migrations.AddRelocateBuildsSetting do
  @moduledoc """
  Relocated builds (S4): the `relocate_builds_enabled` setting, off, under
  which toolchain jobs ask the judge to relocate
  (`Portal.Builder.judge_input/1`), so turning relocation on is a setting,
  not a deploy. It decides no manifest, so `publication_changes` does not
  count it.

  Add-only for the release still running during the deploy window: a
  boolean with a constant default.
  """

  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      add(:relocate_builds_enabled, :boolean, null: false, default: false)
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:settings) do
      remove(:relocate_builds_enabled)
    end
  end
end
