defmodule PortalWeb.PackageMemoryTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.RunMemoryFixtures

  alias Portal.Catalog.Ingestion

  @gib 1024 * 1024 * 1024
  @mib 1024 * 1024

  defp ingest!(name) do
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
          run_id: "#{name}-1",
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!()
        }
      )
  end

  test "the page names the last firmware and toolchain peaks", %{conn: conn} do
    ingest!("mempage")

    insert_run_memory!(%{
      package: "mempage",
      peak_used_bytes: round(2.9 * @gib),
      memory_limit_bytes: 3 * @gib
    })

    insert_run_memory!(%{
      package: "mempage",
      kind: :toolchain,
      peak_used_bytes: 650 * @mib,
      memory_limit_bytes: 2 * @gib
    })

    {:ok, view, _html} = live(conn, ~p"/packages/mempage")

    assert view |> element("#package-memory") |> render() =~
             "Memory: last firmware build peaked at 2.9 GiB of 3 GiB, toolchain 650 MiB of 2 GiB"
  end

  test "a firmware-only package has no toolchain part", %{conn: conn} do
    ingest!("mempage-fw")
    insert_run_memory!(%{package: "mempage-fw", peak_used_bytes: 650 * @mib})

    {:ok, view, _html} = live(conn, ~p"/packages/mempage-fw")
    line = view |> element("#package-memory") |> render()
    assert line =~ "Memory: last firmware build peaked at 650 MiB of 3 GiB"
    refute line =~ "toolchain"
  end

  test "no memory row, no line", %{conn: conn} do
    ingest!("mempage-none")
    {:ok, view, _html} = live(conn, ~p"/packages/mempage-none")
    refute has_element?(view, "#package-memory")
  end
end
