Application.load(:portal)

repo_config = Application.fetch_env!(:portal, Portal.Repo)
database = repo_config[:database]

Enum.each([database, database <> "-shm", database <> "-wal"], &File.rm/1)
File.mkdir_p!(Path.dirname(repo_config[:database]))

case Portal.Repo.__adapter__().storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _, _} = Ecto.Migrator.with_repo(Portal.Repo, &Ecto.Migrator.run(&1, :up, all: true))

ExUnit.start()
