defmodule Portal.Catalog.ImportOverrides do
  @moduledoc """
  Imports the legacy root `package_metadata.json` file into Catalog overrides.
  """

  alias Portal.Catalog.PackageOverride

  @global_package_name "__global__"

  @doc """
  Import overrides from a package metadata JSON file.
  """
  def import_file(path) when is_binary(path) do
    with {:ok, raw} <- File.read(path),
         {:ok, data} <- Jason.decode(raw) do
      import_data(data)
    end
  end

  def import_data(data) when is_map(data) do
    packages = Map.get(data, "packages", %{})
    skip_if_depends_on = Map.get(data, "skip_if_depends_on", [])

    package_count =
      packages
      |> Enum.map(fn {package_name, attrs} -> upsert_package_override(package_name, attrs) end)
      |> count_ok!()

    global_count =
      if skip_if_depends_on == [] do
        0
      else
        :ok =
          upsert(%{
            package_name: @global_package_name,
            skip_if_depends_on: skip_if_depends_on,
            notes: "Global dependency skip rules imported from package_metadata.json"
          })

        1
      end

    {:ok, %{package_overrides: package_count, global_overrides: global_count}}
  end

  defp upsert_package_override(package_name, attrs) do
    upsert(%{
      package_name: package_name,
      forced_status: parse_status(attrs["forced_status"]),
      allow_systems: attrs["allowed_systems"] || attrs["allow_systems"] || [],
      deny_systems: attrs["denied_systems"] || attrs["deny_systems"] || [],
      notes: attrs["notes"]
    })
  end

  defp upsert(attrs) do
    PackageOverride
    |> Ash.Changeset.for_create(:upsert, attrs)
    |> Ash.create(domain: Portal.Catalog)
    |> case do
      {:ok, _override} -> :ok
      {:error, reason} -> raise "failed to import package override: #{inspect(reason)}"
    end
  end

  defp count_ok!(results) do
    Enum.reduce(results, 0, fn
      :ok, acc -> acc + 1
      other, _acc -> raise "unexpected import result: #{inspect(other)}"
    end)
  end

  defp parse_status(nil), do: nil
  defp parse_status("skip"), do: :skipped
  defp parse_status("skipped"), do: :skipped
  defp parse_status(status) when is_binary(status), do: String.to_existing_atom(status)
end
