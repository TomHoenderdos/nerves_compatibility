defmodule PortalWeb.CatalogLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  @fixture Path.join([__DIR__, "..", "support", "fixtures", "result.json"])

  defp ingest_fixture do
    dir = Path.join(System.tmp_dir!(), "catalog-live-files-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = @fixture |> File.read!() |> Jason.decode!()

    {:ok, _run} =
      Ingestion.ingest(result, %{
        run_id: "catalog-live-jason-1.4.1",
        image_digest: "sha256:live",
        files_dir: dir,
        scan_request_id: nil,
        log: "live log"
      })

    :ok
  end

  test "index live lists packages from the catalog and filters by search", %{conn: conn} do
    ingest_fixture()

    {:ok, view, html} = live(conn, "/packages")

    assert html =~ "Nerves Compatibility"
    assert html =~ "jason"
    assert has_element?(view, "#package-jason")

    filtered = render_change(view, :search, %{"q" => "zzz"})
    refute filtered =~ "package-jason"
  end

  test "package live renders latest run and system results", %{conn: conn} do
    ingest_fixture()

    {:ok, view, html} = live(conn, "/packages/jason")

    assert html =~ "jason"
    assert html =~ "1.4.1"
    assert has_element?(view, "#system-nerves-system-rpi4")
    assert html =~ "nerves_system_rpi4"
    assert html =~ "pass"
    assert html =~ "45678901"
  end
end
