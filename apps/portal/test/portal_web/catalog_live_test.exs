defmodule PortalWeb.CatalogLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  require Ash.Query

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

  describe "upstream links" do
    setup do
      ingest_fixture()
      :ok
    end

    test "the page links to the package on Hex and HexDocs", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/packages/jason")

      assert has_element?(view, ~s(a[href="https://hex.pm/packages/jason"]))
      assert has_element?(view, ~s(a[href="https://hexdocs.pm/jason"]))
    end

    # `target="_blank"` without `rel="noopener"` hands the opened tab a live
    # `window.opener` handle back to this one. Both links are external, so this
    # is asserted rather than assumed.
    test "every link that opens a new tab severs the opener handle", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/packages/jason")

      blank_tags = Regex.scan(~r/<a[^>]*target="_blank"[^>]*>/, html) |> List.flatten()

      assert blank_tags != []

      assert Enum.all?(blank_tags, &(&1 =~ "noopener")),
             "missing rel=noopener: #{inspect(blank_tags)}"
    end
  end

  describe "the badge embed" do
    setup do
      ingest_fixture()
      :ok
    end

    # A README on github.com resolves a relative path against github.com, so a
    # snippet is only usable if every URL in it is absolute. This is the whole
    # point of the feature and the easiest thing to regress by switching to a
    # `~p` sigil, which yields a path.
    test "both snippets carry absolute URLs", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/packages/jason")

      base = PortalWeb.Endpoint.url()

      assert html =~
               escaped(
                 "[![Nerves compatibility](#{base}/badge/jason.svg)](#{base}/packages/jason)"
               )

      assert html =~
               escaped(
                 ~S|<a href="| <>
                   "#{base}/packages/jason" <>
                   ~S|"><img src="| <>
                   "#{base}/badge/jason.svg" <> ~S|" alt="Nerves compatibility"></a>|
               )
    end

    test "the badge shown on the page is the one the snippets embed", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/packages/jason")

      src = "#{PortalWeb.Endpoint.url()}/badge/jason.svg"

      assert has_element?(view, ~s(img[src="#{src}"]))
    end

    # Without the hook the button is inert, and the only sign of that in the
    # rendered page is the missing attribute.
    #
    # The template writes `phx-hook=".CopyToClipboard"`. The leading dot means
    # colocated, and the compiler expands it to the defining module's name --
    # which is also the key `phoenix-colocated/portal` registers the hook under
    # on the JS side. Asserting the expanded form is what ties the two halves
    # together: a hook that stops being colocated stops matching here.
    test "each snippet has a wired copy button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/packages/jason")

      hook = "PortalWeb.PackageLive.CopyToClipboard"

      for id <- ~w(copy-markdown copy-html) do
        assert has_element?(view, ~s(button##{id}[phx-hook="#{hook}"]))
      end
    end

    # The clipboard hook needs a secure context and a granted permission. When
    # it cannot run, the snippet still has to be selectable text on the page
    # rather than something only the button could have produced.
    test "a snippet is readable without the button", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/packages/jason")

      assert has_element?(view, ~s(input[readonly][value^="[!["]))
    end
  end

  describe "hex.pm metadata on the package page" do
    setup do
      ingest_fixture()
      :ok
    end

    defp set_hex_meta(name, attrs) do
      package =
        Portal.Catalog.Package
        |> Ash.Query.filter(name == ^name)
        |> Ash.read_one!(domain: Portal.Catalog)

      {:ok, _} =
        package
        |> Ash.Changeset.for_update(:update_hex_meta, attrs)
        |> Ash.update(domain: Portal.Catalog)

      :ok
    end

    test "a github.com link in the package's hex metadata becomes a GitHub link", %{conn: conn} do
      set_hex_meta("jason", %{
        hex_links: %{"GitHub" => "https://github.com/michalmuskala/jason"}
      })

      {:ok, view, _html} = live(conn, "/packages/jason")

      assert has_element?(view, ~s(a[href="https://github.com/michalmuskala/jason"]))
    end

    # The label a package author puts on their repo link is free-form --
    # "GitHub", "Github", "Source", "Repo" and "repository" all occur upstream
    # -- so the host is what decides, not the label.
    test "the link is found by its host, not by its label", %{conn: conn} do
      set_hex_meta("jason", %{hex_links: %{"Source" => "https://github.com/foo/bar"}})

      {:ok, view, _html} = live(conn, "/packages/jason")

      assert has_element?(view, ~s(a[href="https://github.com/foo/bar"]))
    end

    # Packages routinely declare several github.com links -- the repository, a
    # changelog, an issues page -- and the labels give no reliable ordering
    # ("Changelog" sorts before "GitHub"). The repository root is the one a
    # reader wants, and its path is the shallowest.
    test "the repository root wins over deeper github.com links", %{conn: conn} do
      set_hex_meta("jason", %{
        hex_links: %{
          "Changelog" => "https://github.com/foo/bar/blob/main/CHANGELOG.md",
          "GitHub" => "https://github.com/foo/bar",
          "Issues" => "https://github.com/foo/bar/issues"
        }
      })

      {:ok, view, _html} = live(conn, "/packages/jason")

      assert has_element?(view, ~s(a[href="https://github.com/foo/bar"]))
      refute has_element?(view, ~s(a[href*="CHANGELOG"]))
    end

    test "a package whose links point elsewhere gets no GitHub link", %{conn: conn} do
      set_hex_meta("jason", %{hex_links: %{"Source" => "https://gitlab.com/foo/bar"}})

      {:ok, view, _html} = live(conn, "/packages/jason")

      refute has_element?(view, ~s(a[href*="github.com"]))
      assert has_element?(view, ~s(a[href="https://hex.pm/packages/jason"]))
    end

    # Every package in the catalog starts here, before the backfill reaches it.
    # The page has to render without the metadata, not fall over waiting for it.
    test "a package nobody has fetched yet renders without a GitHub link", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/packages/jason")

      refute has_element?(view, ~s(a[href*="github.com"]))
      assert has_element?(view, ~s(a[href="https://hex.pm/packages/jason"]))
    end

    test "owners are listed and link to their hex.pm profiles", %{conn: conn} do
      set_hex_meta("jason", %{hex_owners: ["michalmuskala", "ericmj"]})

      {:ok, view, html} = live(conn, "/packages/jason")

      assert html =~ "Maintained on Hex by"
      assert has_element?(view, ~s(a[href="https://hex.pm/users/michalmuskala"]), "michalmuskala")
      assert has_element?(view, ~s(a[href="https://hex.pm/users/ericmj"]), "ericmj")
    end

    # An empty list means both "not fetched yet" and "hex.pm listed nobody", and
    # neither deserves a line announcing that the package is unmaintained.
    test "no owners means no maintainers line at all", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/packages/jason")

      refute html =~ "Maintained on Hex by"
    end
  end

  # HEEx escapes attribute values, so a snippet containing quotes and angle
  # brackets does not appear verbatim in the response body.
  defp escaped(text), do: text |> Phoenix.HTML.html_escape() |> Phoenix.HTML.safe_to_string()
end
