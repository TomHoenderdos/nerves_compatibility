defmodule PortalWeb.Admin.ArgusTriageWorkflowLiveTest do
  @moduledoc "The by-check view, sorting, bulk selection and keyboard events of the triage page."
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Portal.Test.ArgusFixtures

  alias Portal.Catalog
  alias PortalWeb.Admin.ArgusFindingsLive

  @every_status [:new, :confirmed, :false_positive, :reported, :ignored]
  @title "Catch-all rescue swallows exceptions"
  @check %{analysis: "failure", title: @title, severity: "warning"}

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("triage_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey)}
  end

  defp rows, do: Catalog.triage_list(%{status: @every_status}) |> Enum.map(& &1.triage)

  defp row(package, title),
    do: Enum.find(rows(), &(&1.package_name == package and &1.title == title))

  defp dom_order(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("id")
  end

  defp two_packages do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "two"})]), 1, "alpha")

    ingest(
      "1.0.0",
      ok([finding(), finding(%{"title" => "Other", "severity" => "error"})]),
      1,
      "beta"
    )
  end

  describe "by check" do
    test "is the default and shows counts and a status breakdown", %{conn: conn} do
      two_packages()
      Catalog.triage!(row("beta", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

      assert has_element?(view, "#check-#{key}", "3 findings")
      assert has_element?(view, "#check-#{key}", "2 packages")
      assert has_element?(view, "#check-#{key} [data-check-packages]", "alpha, beta")
      assert has_element?(view, "#check-#{key}", "2 new · 1 confirmed")
      assert has_element?(view, "#view-findings[href='/admin/argus/findings?view=findings']")
      refute has_element?(view, "#findings")
    end

    test "honours the filters", %{conn: conn} do
      two_packages()
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?package=alph")
      assert has_element?(view, "#check-#{ArgusFindingsLive.check_key(@check)}", "2 findings")
      refute has_element?(view, "#checks", "Other")
    end

    test "expands to its findings grouped by package", %{conn: conn} do
      two_packages()
      key = ArgusFindingsLive.check_key(@check)
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      refute has_element?(view, "#check-#{key}-findings")

      view |> element("#check-#{key}-toggle") |> render_click()

      assert has_element?(view, "#check-#{key}-package-alpha [id^='triage-form-']")
      assert has_element?(view, "#check-#{key}-package-beta [id^='triage-form-']")
      assert length(dom_order(view, "#check-#{key}-package-alpha [data-triage-row]")) == 2
    end

    test "the group action sets only new findings of the check within the filters",
         %{conn: conn} do
      two_packages()
      ingest("1.0.0", ok([finding()]), 1, "alphabet")
      Catalog.triage!(row("alphabet", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?package=alph")

      # alpha's two are new; alphabet's one is confirmed.
      assert has_element?(
               view,
               "#check-apply-new-#{key}[data-confirm='Set the status of 2 new findings of this check?']"
             )

      assert has_element?(
               view,
               "#check-apply-all-#{key}[data-confirm='Set the status of all 3 findings of this check?']"
             )

      view
      |> form("#check-form-#{key}", check: %{status: "false_positive", note: ""})
      |> put_submitter("#check-apply-new-#{key}")
      |> render_submit()

      assert %{status: :false_positive, updated_by: "triage_admin"} = row("alpha", @title)
      assert %{status: :confirmed, updated_by: "tom"} = row("alphabet", @title)
      assert %{status: :new} = row("beta", @title)
      assert %{status: :new} = row("beta", "Other")
      assert has_element?(view, "#triage-counts", "2 false positive")
    end

    test "the group action with \"all\" includes triaged findings", %{conn: conn} do
      two_packages()
      Catalog.triage!(row("beta", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

      view
      |> form("#check-form-#{key}", check: %{status: "reported", note: "upstream #3"})
      |> put_submitter("#check-apply-all-#{key}")
      |> render_submit()

      assert rows() |> Enum.filter(&(&1.title == @title)) |> Enum.map(&{&1.status, &1.note}) ==
               List.duplicate({:reported, "upstream #3"}, 3)
    end

    test "offers only \"all\" when new findings are filtered out", %{conn: conn} do
      two_packages()
      Catalog.triage!(row("beta", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?#{%{status: ~w(confirmed)}}")

      refute has_element?(view, "#check-apply-new-#{key}")

      assert has_element?(
               view,
               "#check-apply-all-#{key}[data-confirm='Set the status of all 1 finding of this check?']"
             )

      view
      |> form("#check-form-#{key}", check: %{status: "reported", note: ""})
      |> put_submitter("#check-apply-all-#{key}")
      |> render_submit()

      assert %{status: :reported} = row("beta", @title)
    end

    test "offers only \"all\" when the check has no new findings", %{conn: conn} do
      ingest("1.0.0", ok([finding()]), 1)
      Catalog.triage!(row("tripkg", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      refute has_element?(view, "#check-apply-new-#{key}")
      assert has_element?(view, "#check-apply-all-#{key}")
    end
  end

  describe "sorting" do
    setup do
      ingest("1.0.0", ok([finding(%{"severity" => "info", "title" => "I"})]), 1, "aaa")
      ingest("1.0.0", ok([finding(%{"severity" => "error", "title" => "E"})]), 1, "zzz")
      :ok
    end

    test "the findings view sorts by severity unless asked", %{conn: conn} do
      e = row("zzz", "E")
      i = row("aaa", "I")

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")

      assert dom_order(view, "#findings > [data-triage-row]") == [
               "finding-#{e.id}",
               "finding-#{i.id}"
             ]

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings&sort=package")

      assert dom_order(view, "#findings > [data-triage-row]") == [
               "finding-#{i.id}",
               "finding-#{e.id}"
             ]

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings&sort=drop%20table")

      assert dom_order(view, "#findings > [data-triage-row]") == [
               "finding-#{e.id}",
               "finding-#{i.id}"
             ]
    end

    test "the check view sorts and keeps the sort across filter changes", %{conn: conn} do
      ingest("1.0.0", ok([finding(%{"severity" => "info", "title" => "I"})]), 1, "bbb")
      i = "check-" <> ArgusFindingsLive.check_key(%{@check | title: "I", severity: "info"})
      e = "check-" <> ArgusFindingsLive.check_key(%{@check | title: "E", severity: "error"})

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      assert dom_order(view, "#checks > [data-check]") == [i, e]

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?sort=severity")
      assert dom_order(view, "#checks > [data-check]") == [e, i]

      view |> form("#triage-filters", f: %{package: "a"}) |> render_change()
      assert_patch(view, ~p"/admin/argus/findings?#{%{package: "a", sort: "severity"}}")
    end
  end

  describe "bulk selection" do
    setup do
      ingest(
        "1.0.0",
        ok([finding(), finding(%{"detail" => "two"}), finding(%{"title" => "Other"})]),
        1
      )

      :ok
    end

    test "sets only the selected findings and ignores unknown ids", %{conn: conn} do
      [a, b, c] = Enum.sort_by(rows(), & &1.title)
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")

      view |> element("#select-#{a.id}") |> render_click()
      view |> element("#select-#{c.id}") |> render_click()
      render_hook(view, "toggle_select", %{"id" => Ecto.UUID.generate()})
      assert has_element?(view, "#bulk-form", "2 selected")

      view |> form("#bulk-form", bulk: %{status: "ignored", note: "noise"}) |> render_submit()

      after_ = Map.new(rows(), &{&1.id, &1})
      assert %{status: :ignored, note: "noise", updated_by: "triage_admin"} = after_[a.id]
      assert %{status: :ignored} = after_[c.id]
      assert %{status: :new, note: nil} = after_[b.id]
      assert has_element?(view, "#triage-counts", "2 ignored")
    end

    test "select all shown, and the selection survives a row update", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")
      view |> element("#select-all") |> render_click()
      assert has_element?(view, "#bulk-form", "3 selected")

      [a | _] = rows()
      render_hook(view, "set_status", %{"id" => a.id, "status" => "confirmed"})
      assert has_element?(view, "#select-#{a.id}[checked]")
    end
  end

  describe "keyboard events" do
    test "set_status updates the row and the counts, keeping the note", %{conn: conn} do
      ingest("1.0.0", ok([finding()]), 1)
      [a] = rows()
      Catalog.triage!(a.id, %{status: "new", note: "look"}, %{username: "tom"})
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")

      render_hook(view, "set_status", %{"id" => a.id, "status" => "false_positive"})

      assert [%{status: :false_positive, note: "look", updated_by: "triage_admin"}] = rows()
      assert has_element?(view, "#triage-counts", "1 false positive")
      assert has_element?(view, "#triage-status-#{a.id} option[selected][value='false_positive']")
    end

    test "set_status works inside an expanded check and ignores junk", %{conn: conn} do
      ingest("1.0.0", ok([finding()]), 1)
      [a] = rows()
      key = ArgusFindingsLive.check_key(@check)
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?#{%{status: ~w(new reported)}}")
      view |> element("#check-#{key}-toggle") |> render_click()

      render_hook(view, "set_status", %{"id" => a.id, "status" => "bogus"})
      render_hook(view, "set_status", %{"id" => "nope", "status" => "confirmed"})
      assert [%{status: :new}] = rows()

      render_hook(view, "set_status", %{"id" => a.id, "status" => "reported"})
      assert [%{status: :reported}] = rows()
      assert has_element?(view, "#check-#{key}", "1 reported")
      assert has_element?(view, "#triage-counts", "1 reported")

      # A finding triaged out of the filters leaves its check, as from an inbox.
      render_hook(view, "set_status", %{"id" => a.id, "status" => "ignored"})
      refute has_element?(view, "#check-#{key}")
    end

    test "the list carries the keyboard hook and a shortcut panel", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      assert has_element?(view, "#triage-list[phx-hook]")
      assert has_element?(view, "#triage-shortcuts")
    end
  end

  describe "details" do
    test "source link, confidence, provenance and related locations", %{conn: conn} do
      ingest(
        "1.2.0",
        ok([
          finding(%{
            "file" => "lib/p/a b.ex",
            "line" => 7,
            "confidence" => 0.8,
            "provenance" => "structural",
            "related" => [%{"label" => "<b>caller</b>", "file" => "lib/p/c.ex", "line" => 3}]
          }),
          finding(%{"title" => "No file", "file" => nil, "detail" => "x"})
        ]),
        1
      )

      a = row("tripkg", @title)
      nofile = row("tripkg", "No file")
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")

      assert has_element?(
               view,
               "#source-#{a.id}[href='https://hex.pm/packages/tripkg/1.2.0/files/lib/p/a%20b.ex#L7']"
             )

      refute has_element?(view, "#source-#{nofile.id}")
      assert has_element?(view, "#finding-#{a.id}", "0.8")
      assert has_element?(view, "#finding-#{a.id}", "structural")
      assert has_element?(view, "#finding-#{a.id} li", "<b>caller</b>")
      assert has_element?(view, "#finding-#{a.id} li", "lib/p/c.ex:3")
    end

    test "status counts link to that status", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings&sort=package")

      link = "#triage-count-false_positive"
      assert has_element?(view, "#{link}[href*='=false_positive'][href*='sort=package']")
      assert has_element?(view, "#{link}[href*='view=findings']")

      # The badge counts every current finding, so its link drops the narrowing.
      {:ok, view, _} =
        live(
          conn,
          ~p"/admin/argus/findings?#{%{package: "x", analysis: "y", severity: ~w(info), stale: "true", view: "findings"}}"
        )

      for narrowing <- ~w(package= analysis= severity stale=) do
        refute has_element?(view, "#{link}[href*='#{narrowing}']")
      end

      assert has_element?(view, "#{link}[href*='view=findings']")

      view |> element(link) |> render_click()
      assert has_element?(view, "#filter-status-false_positive[checked]")
      refute has_element?(view, "#filter-status-new[checked]")
    end
  end
end
