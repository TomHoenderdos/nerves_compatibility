defmodule PortalWeb.PackageArgusTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  defp finding(severity, title, extra \\ %{}) do
    Map.merge(
      %{
        "analysis" => "blocking",
        "severity" => severity,
        "file" => "lib/a.ex",
        "line" => 7,
        "title" => title,
        "detail" => "detail of #{title}",
        "help" => ["help for #{title}"],
        "related" => []
      },
      extra
    )
  end

  defp seed(argus) do
    n = System.unique_integer([:positive])
    files = Path.join(System.tmp_dir!(), "pa-f-#{n}")
    out = Path.join(System.tmp_dir!(), "pa-o-#{n}")
    File.mkdir_p!(files)
    File.mkdir_p!(Path.join(out, "logs"))

    on_exit(fn ->
      File.rm_rf(files)
      File.rm_rf(out)
    end)

    # Each seed finishes later than the last, so the page always reads the
    # run seeded most recently.
    finished_at = DateTime.utc_now() |> DateTime.add(n, :second) |> DateTime.to_iso8601()

    result =
      %{
        "package" => %{"name" => "argpkg", "version" => "1.0.0"},
        "finished_at" => finished_at,
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      }
      |> then(fn r -> if argus == :absent, do: r, else: Map.put(r, "argus", argus) end)

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "argpkg-#{n}",
        image_digest: "sha256:x",
        files_dir: files,
        output_dir: out,
        log: "runner"
      })

    :ok
  end

  defp ok(findings, extra \\ %{}) do
    Map.merge(
      %{
        "status" => "ok",
        "version" => "0.20.1",
        "analyses" => ["default", "exposure"],
        "findings" => findings,
        "truncated" => false,
        "error" => nil
      },
      extra
    )
  end

  test "shows findings at or above the floor, hides the rest", %{conn: conn} do
    seed(
      ok([
        finding("error", "Deadlock"),
        finding("warning", "Leaked task"),
        finding("info", "Minor thing")
      ])
    )

    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(view, "#argus", "advisory")
    assert has_element?(view, "#argus", "argus_beam 0.20.1")
    assert has_element?(view, "#argus", "Deadlock")
    assert has_element?(view, "#argus", "Leaked task")
    assert has_element?(view, "#argus", "lib/a.ex:7")
    refute has_element?(view, "#argus", "Minor thing")
  end

  test "the floor follows the admin setting", %{conn: conn} do
    {:ok, _} = Portal.Settings.save(%{argus_min_severity: "error"})
    seed(ok([finding("error", "Deadlock"), finding("warning", "Leaked task")]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(view, "#argus", "Deadlock")
    refute has_element?(view, "#argus", "Leaked task")
  end

  test "no visible findings says so", %{conn: conn} do
    seed(ok([finding("info", "Minor thing")]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(
             view,
             "#argus",
             "No findings at warning or above for: default, exposure"
           )
  end

  test "truncation is stated", %{conn: conn} do
    seed(ok([finding("error", "Deadlock")], %{"truncated" => true}))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "first 200 findings")
  end

  test "a finding with no file or line still renders", %{conn: conn} do
    seed(ok([finding("error", "Floating", %{"file" => nil, "line" => nil})]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "Floating")
  end

  test "an error says it could not run and hides the reason from visitors", %{conn: conn} do
    seed(%{
      "status" => "error",
      "version" => "0.20.1",
      "findings" => [],
      "error" => "timeout after 300s"
    })

    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "Analysis could not run for this version.")
    refute has_element?(view, "#argus", "timeout after 300s")
  end

  test "skipped, absent and malformed argus render no section", %{conn: conn} do
    # `catalog_runs.argus` is a map column, so a non-map never gets past
    # ingestion; the malformed cases are maps missing or mistyping `findings`.
    malformed = [%{"status" => "ok"}, %{"status" => "ok", "findings" => "x"}]

    for argus <- [%{"status" => "skipped"}, :absent | malformed] do
      seed(argus)
      {:ok, view, _} = live(conn, ~p"/packages/argpkg")
      refute has_element?(view, "#argus")
    end
  end
end
