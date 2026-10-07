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

      summary = "#check-#{key}-item [data-check-summary]"
      assert has_element?(view, summary, "2 new · 3 findings · 2 packages")
      assert has_element?(view, "#check-#{key} [data-check-packages]", "alpha, beta")
      assert has_element?(view, "#view-findings[href='/admin/argus/findings?view=findings']")
      refute has_element?(view, "#findings")

      # Collapsed, a check is one quiet line: no form controls.
      refute has_element?(view, "#check-form-#{key}")
      refute has_element?(view, "#check-#{key} select")
    end

    test "a check with nothing new shows its status breakdown instead", %{conn: conn} do
      ingest("1.0.0", ok([finding(), finding(%{"detail" => "two"})]), 1)

      for t <- rows(),
          do: Catalog.triage!(t.id, %{status: "confirmed"}, %{username: "tom"})

      key = ArgusFindingsLive.check_key(@check)
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      summary = "#check-#{key}-item [data-check-summary]"
      assert has_element?(view, summary, "2 confirmed")
      refute has_element?(view, summary, "findings")
      refute has_element?(view, summary, "new")
    end

    test "honours the filters", %{conn: conn} do
      two_packages()
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?package=alph")
      summary = "#check-#{ArgusFindingsLive.check_key(@check)}-item [data-check-summary]"

      # Every finding new and in one package: the counts would repeat "2 new".
      assert has_element?(view, summary, "2 new")
      refute has_element?(view, summary, "findings")
      refute has_element?(view, summary, "1 package")
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
      view |> element("#check-#{key}-toggle") |> render_click()
      assert has_element?(view, "#check-#{key}-findings #check-form-#{key}")

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
      view |> element("#check-#{key}-toggle") |> render_click()

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
      view |> element("#check-#{key}-toggle") |> render_click()

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
      view |> element("#check-#{key}-toggle") |> render_click()
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

      # The bulk bar waits for a selection.
      refute has_element?(view, "#bulk-form")
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
    test "each check row is a keyboard item carrying its identity and new count",
         %{conn: conn} do
      two_packages()
      Catalog.triage!(row("beta", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      item = "#check-#{key}-item[data-triage-row][tabindex='-1'][data-check-key='#{key}']"
      assert has_element?(view, "#{item}[data-analysis='failure'][data-severity='warning']")
      assert has_element?(view, "#{item}[data-title='#{@title}'][data-new='2']")

      # New filtered out: the status keys have nothing to set.
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?#{%{status: ~w(confirmed)}}")
      assert has_element?(view, "#check-#{key}-item[data-new='0']")
    end

    test "the hook's toggle_check and triage_check params expand and set only new findings",
         %{conn: conn} do
      two_packages()
      Catalog.triage!(row("beta", @title).id, %{status: "confirmed"}, %{username: "tom"})
      key = ArgusFindingsLive.check_key(@check)
      ident = %{"analysis" => "failure", "title" => @title, "severity" => "warning"}

      {:ok, view, _} =
        live(conn, ~p"/admin/argus/findings?#{%{status: ~w(new confirmed reported)}}")

      render_hook(view, "toggle_check", ident)
      assert has_element?(view, "#check-#{key}-findings [data-triage-row][data-id]")

      render_hook(view, "toggle_check", ident)
      refute has_element?(view, "#check-#{key}-findings")

      render_hook(
        view,
        "triage_check",
        %{"check" => Map.merge(ident, %{"status" => "reported", "scope" => "new"})}
      )

      assert [{"alpha", :reported, "triage_admin"}, {"alpha", :reported, "triage_admin"}] =
               rows()
               |> Enum.filter(&(&1.title == @title and &1.package_name == "alpha"))
               |> Enum.map(&{&1.package_name, &1.status, &1.updated_by})

      assert %{status: :confirmed, updated_by: "tom"} = row("beta", @title)
      assert %{status: :new} = row("beta", "Other")
      assert has_element?(view, "#check-#{key}-item[data-new='0']")
    end

    test "the shortcut panel describes the check-row keys", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      assert has_element?(view, "#triage-shortcuts", "expand or collapse a check")
      assert has_element?(view, "#triage-shortcuts", "new findings")
    end

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

  describe "by type" do
    setup do
      ingest(
        "1.0.0",
        ok([
          finding(%{"analysis" => "shutdown", "title" => "S"}),
          finding(%{"analysis" => "failure", "title" => "F"}),
          finding(%{"analysis" => "failure", "title" => "E", "severity" => "error"})
        ]),
        1
      )

      :ok
    end

    test "both views offer a sort labelled Type", %{conn: conn} do
      for path <- [~p"/admin/argus/findings", ~p"/admin/argus/findings?view=findings"] do
        {:ok, view, _} = live(conn, path)
        assert has_element?(view, "#triage-sort-select option[value='analysis']", "Type")
      end
    end

    test "the check view groups checks under a header per type", %{conn: conn} do
      key = &ArgusFindingsLive.check_key(%{analysis: &1, title: &2, severity: &3})

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?sort=analysis")

      assert dom_order(view, "#checks > [data-check], #checks > [data-type-header]") == [
               "type-failure",
               "check-" <> key.("failure", "E", "error"),
               "check-" <> key.("failure", "F", "warning"),
               "type-shutdown",
               "check-" <> key.("shutdown", "S", "warning")
             ]

      assert has_element?(view, "#type-failure", "failure")
      refute has_element?(view, "#type-failure[data-triage-row]")

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      refute has_element?(view, "[data-type-header]")
    end
  end

  describe "by package" do
    setup do
      ingest("1.0.0", ok([finding(%{"title" => "One"})]), 1, "few")

      ingest(
        "2.1.0",
        ok([
          finding(%{"title" => "W", "analysis" => "shutdown"}),
          finding(%{"title" => "E", "severity" => "error", "analysis" => "zeta"}),
          finding(%{"title" => "A", "analysis" => "alpha"})
        ]),
        1,
        "many"
      )

      :ok
    end

    defp package_order(view),
      do: dom_order(view, "#findings > [data-package-header], #findings > [data-triage-row]")

    test "groups findings under a header per package, most new first", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages")
      assert has_element?(view, "#view-packages.btn-active")

      ids = Map.new(rows(), &{&1.title, "finding-#{&1.id}"})

      assert package_order(view) == [
               "package-many",
               ids["E"],
               ids["A"],
               ids["W"],
               "package-few",
               ids["One"]
             ]

      header = "#package-many"
      assert has_element?(view, "#{header} a[href='/packages/many']", "many")
      assert has_element?(view, header, "3 findings · 3 new")
      assert has_element?(view, header, "2.1.0")
      refute has_element?(view, "#{header}[data-triage-row]")
      assert has_element?(view, "##{ids["A"]}[data-triage-row][data-id]")
      assert has_element?(view, "#select-#{row("many", "A").id}")
    end

    test "sorts by most new, package name or type", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages")

      assert view |> element("#triage-sort-select") |> render() =~ "Most new"
      assert has_element?(view, "#triage-sort-select option[value='package']", "Package name")
      assert has_element?(view, "#triage-sort-select option[value='analysis']", "Type")

      ids = Map.new(rows(), &{&1.title, "finding-#{&1.id}"})

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages&sort=package")
      assert ["package-few", _, "package-many" | _] = package_order(view)

      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages&sort=analysis")

      assert package_order(view) == [
               "package-many",
               ids["A"],
               ids["W"],
               ids["E"],
               "package-few",
               ids["One"]
             ]
    end

    test "bulk selection and keyboard status work, and the header counts follow",
         %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages")
      a = row("many", "A")
      e = row("many", "E")

      view |> element("#select-#{a.id}") |> render_click()
      view |> form("#bulk-form", bulk: %{status: "confirmed", note: ""}) |> render_submit()
      assert %{status: :confirmed} = row("many", "A")
      assert has_element?(view, "#package-many", "3 findings · 2 new")

      render_hook(view, "set_status", %{"id" => e.id, "status" => "reported"})
      assert %{status: :reported} = row("many", "E")
      assert has_element?(view, "#package-many", "1 new")
      assert has_element?(view, "#triage-counts", "1 reported")
    end

    test "each package header sets the status of its findings", %{conn: conn} do
      Catalog.triage!(row("many", "A").id, %{status: "confirmed"}, %{username: "tom"})
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages")

      assert has_element?(
               view,
               "#package-apply-new-many[data-confirm='Set the status of 2 new findings in many?']"
             )

      assert has_element?(
               view,
               "#package-apply-all-many[data-confirm='Set the status of all 3 findings in many?']"
             )

      view
      |> form("#package-form-many", package: %{status: "false_positive", note: "by design"})
      |> put_submitter("#package-apply-new-many")
      |> render_submit()

      assert %{status: :false_positive, note: "by design", updated_by: "triage_admin"} =
               row("many", "E")

      assert %{status: :false_positive} = row("many", "W")
      assert %{status: :confirmed, updated_by: "tom"} = row("many", "A")
      assert %{status: :new} = row("few", "One")
      assert has_element?(view, "#triage-counts", "2 false positive")

      # Nothing new left: only "all" is offered, and it counts what the
      # filters still show (the false positives have left them).
      refute has_element?(view, "#package-apply-new-many")
      assert has_element?(view, "#package-apply-all-many", "Apply to all 1")

      view
      |> form("#package-form-many", package: %{status: "reported", note: ""})
      |> put_submitter("#package-apply-all-many")
      |> render_submit()

      assert %{status: :reported} = row("many", "A")
      assert %{status: :false_positive, note: "by design"} = row("many", "E")
    end

    test "a package action uses the current filters", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=packages&severity[]=error")
      assert has_element?(view, "#package-apply-all-many", "Apply to all 1")

      view
      |> form("#package-form-many", package: %{status: "ignored", note: ""})
      |> put_submitter("#package-apply-all-many")
      |> render_submit()

      assert %{status: :ignored} = row("many", "E")
      assert %{status: :new} = row("many", "A")
    end
  end

  describe "layout" do
    test "filters sit behind a toggle under a one-line summary", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      assert has_element?(view, "#triage-filter-summary", "new, confirmed")
      assert has_element?(view, "#triage-filter-summary", "all severities")
      assert has_element?(view, "#triage-filters-toggle")
      assert has_element?(view, "#triage-filters-panel.hidden #triage-filters")

      {:ok, view, _} =
        live(
          conn,
          ~p"/admin/argus/findings?#{%{severity: ~w(error), package: "circ", stale: "true"}}"
        )

      assert has_element?(view, "#triage-filter-summary", "error")
      assert has_element?(view, "#triage-filter-summary", "package: circ")
      assert has_element?(view, "#triage-filter-summary", "including no longer seen")
    end

    test "status counts are one line of links and export sits at the bottom", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
      assert has_element?(view, "#triage-counts a#triage-count-new", "0 new")
      refute has_element?(view, "#triage-counts .badge")
      assert has_element?(view, "#triage-export a[href='/admin/argus/export.ndjson']")
      assert has_element?(view, "#triage-export a[href='/admin/argus/export.ndjson?scope=all']")
    end

    test "a finding row keeps its note, source and details behind Details", %{conn: conn} do
      ingest("1.0.0", ok([finding(%{"confidence" => 0.8})]), 1)
      [a] = rows()
      {:ok, view, _} = live(conn, ~p"/admin/argus/findings?view=findings")

      assert has_element?(view, "#finding-#{a.id} select#triage-status-#{a.id}")
      assert has_element?(view, "#finding-#{a.id} details #triage-note-#{a.id}")
      assert has_element?(view, "#finding-#{a.id} details #source-#{a.id}")
      assert has_element?(view, "#finding-#{a.id} details", "0.8")
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
