defmodule Mix.Tasks.Portal.ImportOverrides do
  @moduledoc """
  Imports the legacy package_metadata.json file into Portal.Catalog.PackageOverride rows.

      mix portal.import_overrides [path]

  Defaults to the umbrella/root `package_metadata.json`.
  """

  use Mix.Task

  @shortdoc "Imports package_metadata.json into Catalog PackageOverride rows"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    path =
      args
      |> List.first()
      |> case do
        nil -> Path.expand("../../../../../package_metadata.json", __DIR__)
        path -> Path.expand(path)
      end

    case Portal.Catalog.ImportOverrides.import_file(path) do
      {:ok, %{package_overrides: package_overrides, global_overrides: global_overrides}} ->
        Mix.shell().info(
          "Imported #{package_overrides} package override(s) and #{global_overrides} global override row(s) from #{path}"
        )

      {:error, reason} ->
        Mix.raise("Failed to import overrides from #{path}: #{inspect(reason)}")
    end
  end
end
