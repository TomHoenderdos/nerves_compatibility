defmodule Portal.HexPmRecentTest do
  @moduledoc """
  The paging walk in `Portal.HexPm.recently_updated/1`.

  Every page this fetches is a request to somebody else's service, so how many
  it fetches -- and when it stops -- is the behaviour worth pinning down.
  """
  use ExUnit.Case, async: true

  alias Portal.HexPm

  # Minutes before `@now`, so fixtures read as "this one is inside a two-hour
  # window and that one is not" without arithmetic at every call site.
  @now ~U[2026-09-14 12:00:00Z]

  defp ago(minutes), do: DateTime.add(@now, -minutes, :minute) |> DateTime.to_iso8601()

  defp row(name, version, minutes_ago) do
    %{"name" => name, "latest_version" => version, "updated_at" => ago(minutes_ago)}
  end

  # A stub `Req`. Pages come from the test process, which is also the caller, so
  # the recorded request log needs no synchronisation.
  defmodule StubClient do
    def get(_url, opts) do
      page = get_in(opts, [:params, :page])
      Process.put(:pages_fetched, Process.get(:pages_fetched, []) ++ [page])

      case Process.get({:page, page}) do
        nil -> {:ok, %{status: 200, body: []}}
        response -> response
      end
    end
  end

  defp stub_page(page, rows), do: Process.put({:page, page}, {:ok, %{status: 200, body: rows}})

  defp stub_raw(page, response), do: Process.put({:page, page}, response)

  defp fetched, do: Process.get(:pages_fetched, [])

  defp recently_updated(minutes_back, opts \\ []) do
    opts
    |> Keyword.merge(since: DateTime.add(@now, -minutes_back, :minute), client: StubClient)
    |> HexPm.recently_updated()
  end

  describe "recently_updated/1" do
    test "returns the packages updated inside the window" do
      stub_page(1, [row("alpha", "1.2.0", 10), row("beta", "0.4.1", 30)])

      assert {:ok, [alpha, beta]} = recently_updated(60)
      assert %{name: "alpha", latest_version: "1.2.0"} = alpha
      assert %{name: "beta", latest_version: "0.4.1"} = beta
      assert alpha.updated_at == DateTime.add(@now, -10, :minute)
    end

    test "drops rows at or before the cutoff" do
      stub_page(1, [row("fresh", "1.0.0", 10), row("stale", "1.0.0", 600)])

      assert {:ok, [%{name: "fresh"}]} = recently_updated(60)
    end

    # Rows arrive newest first, so a page holding anything older than the cutoff
    # is the last page that can hold anything newer. Walking on from there costs
    # a request per page for guaranteed nothing.
    test "stops at the first page that reaches past the cutoff" do
      stub_page(1, [row("a", "1.0.0", 10), row("b", "1.0.0", 600)])
      stub_page(2, [row("c", "1.0.0", 700)])

      assert {:ok, [%{name: "a"}]} = recently_updated(60)
      assert fetched() == [1]
    end

    test "keeps paging while every row on a page is inside the window" do
      stub_page(1, [row("a", "1.0.0", 10)])
      stub_page(2, [row("b", "1.0.0", 20)])
      stub_page(3, [row("c", "1.0.0", 600)])

      assert {:ok, [%{name: "a"}, %{name: "b"}]} = recently_updated(60)
      assert fetched() == [1, 2, 3]
    end

    test "an empty page ends the walk" do
      stub_page(1, [row("a", "1.0.0", 10)])
      stub_page(2, [])

      assert {:ok, [%{name: "a"}]} = recently_updated(60)
      assert fetched() == [1, 2]
    end

    # The cap is the guard against a wrong cutoff walking the entire registry --
    # ~180 pages of it. It returns what it has rather than failing, because the
    # next run picks up whatever was missed.
    test "max_pages caps the walk and still returns what it collected" do
      for page <- 1..10, do: stub_page(page, [row("p#{page}", "1.0.0", 10)])

      assert {:ok, collected} = recently_updated(60, max_pages: 3)
      assert length(collected) == 3
      assert fetched() == [1, 2, 3]
    end

    test "results keep hex's newest-first order across pages" do
      stub_page(1, [row("newest", "1.0.0", 5)])
      stub_page(2, [row("older", "1.0.0", 20)])
      stub_page(3, [])

      assert {:ok, [%{name: "newest"}, %{name: "older"}]} = recently_updated(60)
    end

    test "a row without a usable version is skipped rather than paging early" do
      stub_page(1, [row("good", "1.0.0", 10), %{"name" => "no_version", "updated_at" => ago(11)}])
      stub_page(2, [])

      assert {:ok, [%{name: "good"}]} = recently_updated(60)
      # Both rows were inside the window, so the walk had no reason to stop at
      # page 1 -- skipping an unusable row must not look like reaching the cutoff.
      assert fetched() == [1, 2]
    end

    test "falls back to meta.latest_version" do
      stub_page(1, [
        %{"name" => "meta_only", "meta" => %{"latest_version" => "2.0.0"}, "updated_at" => ago(5)}
      ])

      stub_page(2, [])

      assert {:ok, [%{name: "meta_only", latest_version: "2.0.0"}]} = recently_updated(60)
    end

    # An unparseable timestamp means we cannot say whether the row is newer than
    # the cutoff. Ending the walk is the safe reading: the next run sees it again.
    test "an unparseable timestamp ends the walk instead of being treated as fresh" do
      stub_page(1, [row("good", "1.0.0", 10), %{"name" => "broken", "updated_at" => "not a date"}])

      stub_page(2, [row("unreached", "1.0.0", 1)])

      assert {:ok, [%{name: "good"}]} = recently_updated(60)
      assert fetched() == [1]
    end

    test "an HTTP error is reported rather than returning a partial walk" do
      stub_raw(1, {:ok, %{status: 500, body: "boom"}})

      assert {:error, :hex_api_unavailable} = recently_updated(60)
    end

    test "a transport error is reported" do
      stub_raw(1, {:error, %RuntimeError{message: "econnrefused"}})

      assert {:error, :hex_api_unavailable} = recently_updated(60)
    end

    test "asks hex to sort by update time" do
      defmodule ParamSpy do
        def get(url, opts) do
          send(self(), {:requested, url, opts[:params]})
          {:ok, %{status: 200, body: []}}
        end
      end

      assert {:ok, []} =
               HexPm.recently_updated(since: DateTime.add(@now, -60, :minute), client: ParamSpy)

      assert_received {:requested, url, params}
      assert url =~ "/packages"
      assert params[:sort] == "updated_at"
      assert params[:page] == 1
    end
  end
end
