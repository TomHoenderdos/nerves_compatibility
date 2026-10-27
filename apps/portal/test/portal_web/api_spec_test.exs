defmodule PortalWeb.ApiSpecTest do
  use PortalWeb.ConnCase, async: true

  import PortalWeb.ApiSpecAssertions

  alias OpenApiSpex.Operation
  alias PortalWeb.ApiSpec

  describe "the spec" do
    test "documents every /api route, so a new endpoint without a spec fails here" do
      routes = ApiSpec.documented_routes()
      spec = api_spec()

      assert length(routes) >= 11

      for route <- routes do
        assert function_exported?(route.plug, :open_api_operation, 1),
               "#{inspect(route.plug)} serves #{route.path} but defines no operation specs"

        assert %Operation{} = route.plug.open_api_operation(route.plug_opts),
               "#{inspect(route.plug)}.#{route.plug_opts} (#{route.path}) has no operation spec"

        item = Map.fetch!(spec.paths, ApiSpec.open_api_path(route.path))
        assert %Operation{} = Map.fetch!(item, route.verb)
      end
    end

    test "every /api route is documented except the spec and its docs page" do
      api_paths =
        PortalWeb.Router.__routes__()
        |> Enum.map(& &1.path)
        |> Enum.filter(&String.starts_with?(&1, "/api/"))
        |> MapSet.new()

      documented = ApiSpec.documented_routes() |> MapSet.new(& &1.path)

      left_out = MapSet.difference(api_paths, documented)

      assert left_out == MapSet.new(["/api/docs", "/api/openapi.json"]),
             "left out of the spec: #{inspect(MapSet.to_list(left_out))}"
    end

    test "leaves out everything outside /api" do
      for path <- Map.keys(api_spec().paths) do
        assert String.starts_with?(path, "/api/")
        refute String.starts_with?(path, "/api/docs")
      end
    end

    test "has unique operation ids and a tag on every operation" do
      operations =
        for {_path, item} <- api_spec().paths,
            {_verb, %Operation{} = op} <- Map.from_struct(item),
            do: op

      ids = Enum.map(operations, & &1.operationId)
      assert length(ids) == length(Enum.uniq(ids))

      tags = MapSet.new(api_spec().tags, & &1.name)

      for op <- operations do
        assert [_ | _] = op.tags
        assert Enum.all?(op.tags, &MapSet.member?(tags, &1)), "#{op.operationId}: unknown tag"
      end
    end

    test "encodes to JSON with no dangling $ref" do
      map = api_spec() |> Jason.encode!() |> Jason.decode!()
      schemas = Map.keys(map["components"]["schemas"])

      refs = collect_refs(map)
      assert refs != []

      for ref <- refs do
        assert "#/components/schemas/" <> name = ref
        assert name in schemas, "dangling #{ref}"
      end
    end

    test "examples conform to their schemas" do
      for {title, schema} <- api_spec().components.schemas, schema.example != nil do
        assert_api_schema(schema.example, title)
      end
    end

    test "names no host, address or internal detail in its text" do
      text = Jason.encode!(api_spec())

      for word <- ["catalog_", "Portal.", "localhost", "127.0.0.1", "builder", "Oban"] do
        refute text =~ word, "spec text mentions #{inspect(word)}"
      end
    end
  end

  describe "GET /api/openapi.json" do
    test "serves the spec as JSON", %{conn: conn} do
      conn = get(conn, "/api/openapi.json")
      body = json_response(conn, 200)

      assert "3." <> _ = body["openapi"]
      assert body["info"]["title"] == "Nerves Compatibility API"
      assert Map.has_key?(body["paths"], "/api/packages/{name}")
      assert Map.has_key?(body["paths"], "/api/precompiled/manifests/{package}.json")
      assert body["externalDocs"]["url"] =~ "PRECOMPILED_API.md"
    end
  end

  defp collect_refs(%{"$ref" => ref} = map),
    do: [ref | map |> Map.delete("$ref") |> collect_refs()]

  defp collect_refs(map) when is_map(map),
    do: map |> Map.values() |> Enum.flat_map(&collect_refs/1)

  defp collect_refs(list) when is_list(list), do: Enum.flat_map(list, &collect_refs/1)
  defp collect_refs(_value), do: []
end
