defmodule PortalWeb.PackageCarriedTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  defp ingest!(scope, systems, finished_at) do
    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "carriedpage", "version" => "1.0.0"},
          "finished_at" => finished_at,
          "scope" => scope,
          "systems" => systems
        },
        %{
          run_id: "cp-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )
  end

  test "a result carried from an earlier run says so", %{conn: conn} do
    ingest!(
      "full",
      %{"host" => %{"status" => "pass"}, "nerves_system_rpi4" => %{"status" => "pass"}},
      "2026-10-10T10:00:00Z"
    )

    ingest!("argus_only", %{"host" => %{"status" => "pass"}}, "2026-10-11T10:00:00Z")

    {:ok, view, _html} = live(conn, ~p"/packages/carriedpage")

    assert view |> element("#system-nerves-system-rpi4") |> render() =~ "from an earlier build"
    refute view |> element("#system-host") |> render() =~ "from an earlier build"
  end
end
