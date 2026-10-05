defmodule PortalWeb.PackageArgusTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  # The section is internal for now: only an admin signed in with a passkey,
  # the same gate as /admin, sees it. Every rendering test below runs as one.
  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("argus_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  defp visitor(_conn), do: build_conn()

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

  test "mistyped finding fields render what they can instead of crashing", %{conn: conn} do
    seed(
      ok([
        finding("error", "Kept", %{"detail" => %{"x" => 1}, "related" => ["x", %{"label" => 3}]}),
        finding("warning", "Retitled", %{
          "title" => %{"not" => "a title"},
          "help" => [%{"x" => 1}, "real hint"]
        }),
        finding(["error"], "Bad severity")
      ])
    )

    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(view, "#argus", "Kept")
    assert has_element?(view, "#argus", "real hint")
    refute has_element?(view, "#argus", "Bad severity")
  end

  test "an error says it could not run, with the reason", %{conn: conn} do
    seed(%{
      "status" => "error",
      "version" => "0.20.1",
      "findings" => [],
      "error" => "timeout after 300s"
    })

    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "Analysis could not run for this version.")
    assert has_element?(view, "#argus", "timeout after 300s")
  end

  test "visitors never see the section", %{conn: conn} do
    seed(ok([finding("error", "Deadlock")]))
    {:ok, view, _} = live(visitor(conn), ~p"/packages/argpkg")
    refute has_element?(view, "#argus")
  end

  test "an admin who did not sign in with a passkey does not see it", %{conn: conn, admin: admin} do
    seed(ok([finding("error", "Deadlock")]))
    conn = conn |> visitor() |> init_test_session(user_id: admin.id, login_method: :password)
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    refute has_element?(view, "#argus")
  end

  test "a signed-in non-admin does not see it", %{conn: conn} do
    {:ok, user} = Portal.Accounts.register_user("argus_viewer", "correct horse battery staple")
    seed(ok([finding("error", "Deadlock")]))
    conn = conn |> visitor() |> init_test_session(user_id: user.id, login_method: :password)
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    refute has_element?(view, "#argus")
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
