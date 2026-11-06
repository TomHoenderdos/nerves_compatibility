defmodule PortalWeb.PackageArchTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  defp ingest!(name, run_id, arch) do
    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0"},
          "finished_at" => "2026-11-01T10:00:00Z",
          "systems" => %{"host" => %{"status" => "pass"}}
        },
        %{
          package: name,
          version: "1.0.0",
          run_id: run_id,
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!(),
          arch: arch
        }
      )
  end

  # A version is built once, on whichever architecture got it first: the
  # page says which.
  test "each result names the architecture its run built on", %{conn: conn} do
    ingest!("archpage", "ap-1", "aarch64")
    {:ok, view, _html} = live(conn, ~p"/packages/archpage")
    assert view |> element("#system-host") |> render() =~ "aarch64"
  end

  test "a run from before architectures were recorded shows none", %{conn: conn} do
    ingest!("archpage-old", "ap-2", nil)
    {:ok, view, _html} = live(conn, ~p"/packages/archpage-old")
    html = view |> element("#system-host") |> render()
    refute html =~ "x86_64"
    refute html =~ "aarch64"
  end
end
