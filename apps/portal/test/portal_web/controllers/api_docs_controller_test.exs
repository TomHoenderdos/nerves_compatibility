defmodule PortalWeb.ApiDocsControllerTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.ApiSpec

  test "GET /api/docs lists every documented operation", %{conn: conn} do
    conn = get(conn, "/api/docs")
    html = html_response(conn, 200)
    doc = LazyHTML.from_document(html)

    spec = PortalWeb.ApiSpecAssertions.api_spec()

    for {path, item} <- spec.paths,
        {_verb, %OpenApiSpex.Operation{} = op} <- Map.from_struct(item) do
      id = "op-" <> (op.operationId |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-"))
      article = LazyHTML.query(doc, "article##{id}")
      assert LazyHTML.text(article) =~ path, "#{op.operationId} is not rendered under #{id}"
    end
  end

  test "groups operations by tag and links the JSON spec and format docs", %{conn: conn} do
    doc = conn |> get("/api/docs") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "section#tag-catalog article#op-listpackages") |> Enum.count() == 1
    assert LazyHTML.query(doc, "section#tag-precompiled article#op-getfile") |> Enum.count() == 1

    assert LazyHTML.query(doc, ~s(a#openapi-json-link[href="/api/openapi.json"])) |> Enum.count() ==
             1

    assert LazyHTML.query(doc, ~s(a[href="#{ApiSpec.precompiled_docs_url()}"])) |> Enum.count() >=
             1
  end

  test "renders response schemas as field rows with refs resolved", %{conn: conn} do
    doc = conn |> get("/api/docs") |> html_response(200) |> LazyHTML.from_document()

    # PackagesResponse -> packages{key} -> Package -> systems{key} -> SystemResult.status
    rows = LazyHTML.query(doc, "table#op-listpackages-200-fields tbody tr")
    text = LazyHTML.text(rows)

    assert text =~ "packages"
    assert text =~ "map of Package"
    assert text =~ "systems"
    assert text =~ "map of SystemResult"
    assert text =~ "hex_version_tested"
    assert text =~ "pass | fail | error | skipped | unknown"

    params = LazyHTML.query(doc, "table#op-listfailing-params") |> LazyHTML.text()
    assert params =~ "sort"
    assert params =~ "recent | all"
    assert params =~ "limit"
    assert params =~ "system"

    assert LazyHTML.query(doc, "article#schema-batchpayload table tbody tr") |> Enum.count() > 0
  end

  test "the page carries no script of its own", %{conn: conn} do
    doc = conn |> get("/api/docs") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, "main script") |> Enum.count() == 0
  end

  test "the site nav links the API docs", %{conn: conn} do
    doc = conn |> get("/packages") |> html_response(200) |> LazyHTML.from_document()

    assert LazyHTML.query(doc, ~s(nav.site-nav a[href="/api/docs"])) |> Enum.count() == 1
  end
end
