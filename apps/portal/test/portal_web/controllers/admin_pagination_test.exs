defmodule PortalWeb.AdminPaginationTest do
  use PortalWeb.ConnCase, async: false

  import Portal.PackageListingFixtures
  import Portal.Test.AccountsFixtures, only: [add_test_passkey: 1]

  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("paging_admin", "correct horse battery staple")
    conn = init_test_session(conn, user_id: add_test_passkey(admin).id, login_method: :passkey)
    %{conn: conn}
  end

  describe "admin pagination" do
    test "bounds database reads and renders separate pages with total counts", %{conn: conn} do
      for i <- 1..51, do: request_fixture("queued_#{i}")
      for i <- 1..51, do: request_fixture("pending_#{i}", %{status: :pending})

      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:portal, :repo, :query],
        &__MODULE__.capture_request_read/4,
        self()
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      first = document(get(conn, ~p"/admin"))
      assert length(rows(first, "queue")) == 50
      assert length(rows(first, "approvals")) == 50
      assert text(first, "#queue-pagination") =~ "1–50 of 51"
      assert text(first, "#approvals-pagination") =~ "1–50 of 51"
      assert_receive {:request_read, _, _}
      refute_received {:request_read, _, true}

      second = document(get(conn, ~p"/admin?queue_page=2&review_page=2"))
      assert length(rows(second, "queue")) == 1
      assert length(rows(second, "approvals")) == 1
      assert text(second, "#queue tbody") =~ "queued_51"
      assert text(second, "#approvals tbody") =~ "pending_51"
      assert text(second, "#queue-pagination") =~ "51–51 of 51"
      assert second |> LazyHTML.query("#queue-pagination a[rel=next]") |> Enum.empty?()

      assert [href] =
               second
               |> LazyHTML.query("#queue-pagination a[rel=prev]")
               |> LazyHTML.attribute("href")

      assert URI.decode_query(URI.parse(href).query) == %{
               "queue_page" => "1",
               "review_page" => "2"
             }
    end

    test "malformed pages default to the first page and excessive pages clamp", %{conn: conn} do
      for i <- 1..51, do: request_fixture("queued_#{i}")

      for value <- ["0", "-1", "oops", "2oops", ["2"], %{"page" => "2"}] do
        doc = document(get(conn, ~p"/admin", %{"queue_page" => value}))
        assert length(rows(doc, "queue")) == 50
      end

      last = document(get(conn, ~p"/admin?queue_page=99999999999999999999"))
      assert length(rows(last, "queue")) == 1
      assert text(last, "#queue tbody") =~ "queued_51"
    end

    test "rejecting the last approval on a page clamps back and preserves the queue page", %{
      conn: conn
    } do
      for i <- 1..51, do: request_fixture("queued_#{i}")
      pending = for i <- 1..51, do: request_fixture("pending_#{i}", %{status: :pending})
      last = List.last(pending)

      doc =
        conn
        |> post(~p"/admin/requests/#{last.id}/reject", %{
          "queue_page" => "2",
          "review_page" => "2"
        })
        |> document()

      assert length(rows(doc, "queue")) == 1
      assert length(rows(doc, "approvals")) == 50
      assert text(doc, "#approvals-pagination") =~ "1–50 of 50"

      assert ["2"] =
               doc
               |> LazyHTML.query("#approvals form:first-child input[name=queue_page]")
               |> LazyHTML.attribute("value")
               |> Enum.uniq()
    end
  end

  def capture_request_read(_event, _measurements, metadata, test_pid) do
    if String.contains?(metadata.query, "portal_scan_requests") do
      case metadata.result do
        {:ok, %{num_rows: rows}} -> send(test_pid, {:request_read, rows, rows > 50})
        _ -> :ok
      end
    end
  end

  defp document(conn), do: conn |> html_response(200) |> LazyHTML.from_document()
  defp rows(doc, id), do: doc |> LazyHTML.query("##{id} tbody tr") |> Enum.to_list()
  defp text(doc, selector), do: doc |> LazyHTML.query(selector) |> LazyHTML.text()
end
