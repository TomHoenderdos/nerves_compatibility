defmodule Portal.Workers.PackageMeta do
  @moduledoc """
  Refreshes one package's hex.pm metadata: the author's declared links, and the
  package's owners.

  Neither is derivable from anything we already hold. A package name says
  nothing about where its source lives, and the owners list exists only on
  hex.pm. Both are therefore fetched and stored, rather than looked up when a
  page renders -- `/packages/<name>` is ~2,500 URLs, and putting an external
  request in the render path would make every one of them as slow and as
  available as hex.pm is.

  Runs in `intake` for the same reason `Portal.Workers.Backfill` does: it is a
  hex.pm lookup, not a compile, so it belongs on the web host and must never
  compete with the builds it sits alongside.
  """

  use Oban.Worker,
    queue: :intake,
    max_attempts: 5,
    # A package's links and owners change on the order of years. Deduplicating
    # for a day means the sweep, a re-ingestion, and a manual re-run inside the
    # same day collapse into one hex.pm request per package.
    unique: [keys: [:package], period: 86_400]

  require Ash.Query
  require Logger

  alias Portal.Catalog.Package

  @domain Portal.Catalog

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"package" => name}}) do
    with {:ok, package} <- fetch_package(name),
         {:ok, meta} <- hex_pm().package_metadata(name) do
      package
      |> Ash.Changeset.for_update(:update_hex_meta, %{
        hex_links: meta.links,
        hex_owners: meta.owners
      })
      |> Ash.update(domain: @domain)
      |> case do
        {:ok, _package} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      # Nothing a retry can fix. A package we have never ingested has no row to
      # update, and one hex.pm does not have (renamed, retired) will not appear
      # on the next attempt either.
      {:error, reason} when reason in [:no_such_package, :unknown_package] ->
        Logger.info("PackageMeta skipping #{name}: #{inspect(reason)}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_package(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one(domain: @domain)
    |> case do
      {:ok, nil} -> {:error, :no_such_package}
      {:ok, package} -> {:ok, package}
      {:error, reason} -> {:error, reason}
    end
  end

  # Injectable so tests never reach hex.pm.
  defp hex_pm, do: Application.get_env(:portal, :hex_pm, Portal.HexPm)
end
