defmodule Portal.Repo do
  use AshPostgres.Repo, otp_app: :portal

  def installed_extensions do
    ["ash-functions"]
  end

  def min_pg_version do
    %Version{major: 14, minor: 0, patch: 0}
  end
end
