defmodule PortalWeb.ApiDocs do
  @moduledoc """
  Turns the OpenAPI document (`PortalWeb.ApiSpec`) into what `/api/docs`
  renders: operations grouped by tag, and every request and response schema
  flattened into rows of fields with their `$ref`s resolved.

  Pure data, so the page needs no JavaScript and the template stays a loop.
  """

  alias OpenApiSpex.{OpenApi, Reference, Schema}

  # Deeper than any response nests; stops a self-referencing schema.
  @max_depth 8

  @methods [:get, :put, :post, :patch, :delete, :head, :options, :trace]

  @type field :: %{
          name: String.t(),
          type: String.t(),
          required: boolean(),
          description: String.t() | nil,
          depth: non_neg_integer()
        }

  @doc """
  Sections of the page, one per tag in the order the spec declares them,
  each holding its operations sorted by path.
  """
  @spec sections(OpenApi.t()) :: [map()]
  def sections(%OpenApi{} = spec) do
    operations = operations(spec)

    for tag <- spec.tags,
        ops = Enum.filter(operations, &(tag.name in &1.tags)),
        ops != [] do
      %{
        name: tag.name,
        id: "tag-" <> slug(tag.name),
        description: tag.description,
        operations: ops
      }
    end
  end

  @doc "Every operation in the spec, sorted by path then method."
  @spec operations(OpenApi.t()) :: [map()]
  def operations(%OpenApi{} = spec) do
    schemas = component_schemas(spec)

    for {path, item} <- spec.paths,
        method <- @methods,
        %OpenApiSpex.Operation{} = op <- [Map.get(item, method)] do
      %{
        id: "op-" <> slug(op.operationId || "#{method} #{path}"),
        method: method |> Atom.to_string() |> String.upcase(),
        path: path,
        tags: op.tags || [],
        summary: op.summary,
        description: op.description,
        parameters: Enum.map(op.parameters || [], &parameter(&1, schemas)),
        responses: responses(op.responses || %{}, schemas)
      }
    end
    |> Enum.sort_by(&{&1.path, &1.method})
  end

  @doc """
  A named component schema, flattened, for schemas no operation references
  directly (the decoded payloads of the signed documents).
  """
  @spec schema_doc(OpenApi.t(), String.t()) :: map()
  def schema_doc(%OpenApi{} = spec, title) do
    schemas = component_schemas(spec)
    schema = Map.fetch!(schemas, title)

    %{
      title: title,
      id: "schema-" <> slug(title),
      description: schema.description,
      fields: fields(schema, schemas)
    }
  end

  @doc """
  Rows for a schema's fields, nested objects one `depth` deeper than their
  parent. A map keyed by data (package names, versions) is a `{key}` row.
  """
  @spec fields(Schema.t() | Reference.t() | module(), map()) :: [field()]
  def fields(schema, schemas), do: fields(schema, schemas, 0)

  defp fields(_schema, _schemas, depth) when depth > @max_depth, do: []

  defp fields(schema, schemas, depth) do
    schema = resolve(schema, schemas)

    case schema do
      %Schema{type: :array, items: items} when not is_nil(items) ->
        fields(items, schemas, depth)

      %Schema{} ->
        property_fields(schema, schemas, depth) ++ map_fields(schema, schemas, depth)

      _ ->
        []
    end
  end

  defp property_fields(%Schema{properties: props} = schema, schemas, depth) when is_map(props) do
    required = MapSet.new(schema.required || [], &to_string/1)

    props
    |> Enum.sort_by(fn {name, _} -> to_string(name) end)
    |> Enum.flat_map(fn {name, prop} ->
      name = to_string(name)
      field(name, prop, MapSet.member?(required, name), schemas, depth)
    end)
  end

  defp property_fields(_schema, _schemas, _depth), do: []

  defp map_fields(%Schema{additionalProperties: %{} = value}, schemas, depth) do
    field("{key}", value, false, schemas, depth)
  end

  defp map_fields(_schema, _schemas, _depth), do: []

  defp field(name, schema, required, schemas, depth) do
    resolved = resolve(schema, schemas)

    row = %{
      name: name,
      type: type_label(schema, schemas),
      required: required,
      description: resolved && resolved.description,
      depth: depth
    }

    [row | fields(schema, schemas, depth + 1)]
  end

  @doc "A short, readable type for a schema, e.g. `map of SystemResult | null`."
  @spec type_label(Schema.t() | Reference.t() | module() | nil, map()) :: String.t()
  def type_label(schema, schemas) do
    resolved = resolve(schema, schemas)

    case resolved do
      nil -> "any"
      %Schema{} -> base_label(resolved, title(schema, resolved), schemas) <> null_suffix(resolved)
    end
  end

  # A referenced object reads as its name; a referenced enum keeps its values.
  defp base_label(%Schema{type: :object} = schema, title, schemas) when is_binary(title),
    do: if(map_only?(schema), do: map_label(schema, schemas), else: title)

  defp base_label(%Schema{type: :array, items: items}, _title, schemas),
    do: "array of " <> type_label(items, schemas)

  defp base_label(%Schema{type: :object} = schema, _title, schemas) do
    if map_only?(schema), do: map_label(schema, schemas), else: "object"
  end

  defp base_label(%Schema{enum: [_ | _] = values}, _title, _schemas),
    do: Enum.map_join(values, " | ", &inspect_value/1)

  defp base_label(%Schema{type: type, format: format}, _title, _schemas)
       when not is_nil(format),
       do: "#{type} (#{format})"

  defp base_label(%Schema{type: type}, _title, _schemas) when not is_nil(type),
    do: to_string(type)

  defp base_label(_schema, _title, _schemas), do: "any"

  defp map_only?(%Schema{properties: props, additionalProperties: %{}}),
    do: props in [nil, %{}]

  defp map_only?(_schema), do: false

  defp map_label(%Schema{additionalProperties: value}, schemas),
    do: "map of " <> type_label(value, schemas)

  defp null_suffix(%Schema{nullable: true}), do: " | null"
  defp null_suffix(_schema), do: ""

  defp inspect_value(value) when is_binary(value), do: value
  defp inspect_value(value), do: to_string(value)

  # The name a reader knows a schema by: its component title, for a `$ref`.
  defp title(%Reference{}, %Schema{title: title}), do: title
  defp title(module, %Schema{title: title}) when is_atom(module), do: title
  defp title(_schema, _resolved), do: nil

  defp parameter(param, schemas) do
    %{
      name: to_string(param.name),
      in: to_string(param.in),
      type: type_label(param.schema, schemas),
      required: param.required == true,
      description: param.description,
      default: param.schema && resolve(param.schema, schemas).default
    }
  end

  defp responses(responses, schemas) do
    responses
    |> Enum.sort_by(fn {status, _} -> to_string(status) end)
    |> Enum.map(fn {status, response} ->
      {content_type, media} = first_content(response.content)
      schema = media && media.schema
      resolved = schema && resolve(schema, schemas)

      %{
        status: to_string(status),
        description: response.description,
        content_type: content_type,
        headers: response |> Map.get(:headers) |> header_names(),
        type: if(schema, do: type_label(schema, schemas)),
        schema_description: resolved && resolved.description,
        fields: if(schema, do: fields(schema, schemas), else: [])
      }
    end)
  end

  defp first_content(content) when is_map(content) and map_size(content) > 0,
    do: content |> Enum.sort() |> hd()

  defp first_content(_content), do: {nil, nil}

  defp header_names(headers) when is_map(headers), do: headers |> Map.keys() |> Enum.sort()
  defp header_names(_headers), do: []

  defp resolve(%Reference{} = ref, schemas), do: Reference.resolve_schema(ref, schemas)
  defp resolve(%Schema{} = schema, _schemas), do: schema

  defp resolve(module, _schemas) when is_atom(module) and not is_nil(module),
    do: module.schema()

  defp resolve(_schema, _schemas), do: nil

  defp component_schemas(%OpenApi{components: %{schemas: schemas}}) when is_map(schemas),
    do: schemas

  defp component_schemas(_spec), do: %{}

  defp slug(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
