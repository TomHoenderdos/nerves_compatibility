Application.load(:portal)

# Ensure the test database exists & is migrated before suite starts.
Portal.Repo.__adapter__().storage_up(Portal.Repo.config())
|> case do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _, _} = Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))

Ecto.Adapters.SQL.Sandbox.mode(Portal.Repo, :manual)

ExUnit.start()
