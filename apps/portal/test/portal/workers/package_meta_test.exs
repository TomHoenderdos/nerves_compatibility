defmodule Portal.Workers.PackageMetaTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog.Package
  alias Portal.Workers.PackageMeta

  # Stands in for `Portal.HexPm` so no test here reaches hex.pm. The worker
  # resolves its client through `Application.get_env/3` for exactly this.
  defmodule StubHexPm do
    def package_metadata(name) do
      case Process.get({:hex_meta, name}) || Process.get(:hex_meta_default) do
        nil -> {:error, :unknown_package}
        response -> response
      end
    end
  end

  setup do
    previous = Application.get_env(:portal, :hex_pm)
    Application.put_env(:portal, :hex_pm, StubHexPm)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:portal, :hex_pm, previous),
        else: Application.delete_env(:portal, :hex_pm)
    end)

    :ok
  end

  defp seed(name) do
    {:ok, package} =
      Package
      |> Ash.Changeset.for_create(:create, %{name: name})
      |> Ash.create(domain: Portal.Catalog)

    package
  end

  defp reload(name) do
    Package
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Portal.Catalog)
  end

  defp perform(name), do: PackageMeta.perform(%Oban.Job{args: %{"package" => name}, attempt: 1})

  test "hex.pm links and owners land on the package row" do
    seed("jason")

    Process.put(
      {:hex_meta, "jason"},
      {:ok,
       %{
         links: %{"GitHub" => "https://github.com/michalmuskala/jason"},
         owners: ["michalmuskala", "ericmj"]
       }}
    )

    assert :ok = perform("jason")

    package = reload("jason")

    assert package.hex_links == %{"GitHub" => "https://github.com/michalmuskala/jason"}
    assert package.hex_owners == ["michalmuskala", "ericmj"]
  end

  # Nil is how the backfill finds work and how the page tells "never fetched"
  # apart from "declares no links". A successful fetch has to clear it even when
  # hex.pm had nothing to say about the package.
  test "a fetch that returned nothing still stamps the row as fetched" do
    seed("jason")
    Process.put({:hex_meta, "jason"}, {:ok, %{links: %{}, owners: []}})

    assert :ok = perform("jason")

    package = reload("jason")

    assert package.hex_links == %{}
    assert package.hex_owners == []
    assert %DateTime{} = package.hex_meta_fetched_at
  end

  # `:update_hex_meta` exists precisely so a metadata fetch cannot clobber what
  # a build wrote. If the two actions were merged, this is the test that would
  # catch it.
  test "a metadata refresh leaves the ingested fields alone" do
    {:ok, package} =
      Package
      |> Ash.Changeset.for_create(:create, %{
        name: "jason",
        description: "A blazing fast JSON parser",
        latest_version: "1.4.1"
      })
      |> Ash.create(domain: Portal.Catalog)

    Process.put({:hex_meta, "jason"}, {:ok, %{links: %{"Docs" => "https://x.test"}, owners: []}})

    assert :ok = perform("jason")

    refreshed = reload("jason")

    assert refreshed.id == package.id
    assert refreshed.description == "A blazing fast JSON parser"
    assert refreshed.latest_version == "1.4.1"
  end

  # Both of these are permanent: a package we never ingested has no row to
  # update, and one hex.pm does not know will not appear on the next attempt
  # either. Retrying would burn five attempts on a certainty.
  test "a package with no row is cancelled, not retried" do
    assert {:cancel, :no_such_package} = perform("never-ingested")
  end

  test "a package hex.pm does not know is cancelled, not retried" do
    seed("retired")
    Process.put({:hex_meta, "retired"}, {:error, :unknown_package})

    assert {:cancel, :unknown_package} = perform("retired")
  end

  # A hex.pm outage is the one failure a retry actually fixes, so it must stay
  # an error rather than joining the cancel branch above.
  test "hex.pm being down is retried" do
    seed("jason")
    Process.put({:hex_meta, "jason"}, {:error, :hex_api_unavailable})

    assert {:error, :hex_api_unavailable} = perform("jason")
    assert reload("jason").hex_meta_fetched_at == nil
  end

  # A package rebuilt against six systems enqueues six of these. Without the
  # uniqueness window that is six hex.pm requests for data that changes on the
  # order of years.
  test "repeat enqueues for one package collapse into a single job" do
    assert {:ok, _} = Oban.insert(PackageMeta.new(%{package: "jason"}))
    assert {:ok, _} = Oban.insert(PackageMeta.new(%{package: "jason"}))
    assert {:ok, _} = Oban.insert(PackageMeta.new(%{package: "plug"}))

    assert length(all_enqueued(worker: PackageMeta)) == 2
  end
end
