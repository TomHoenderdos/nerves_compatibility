defmodule PortalWeb.ApiSpecAssertions do
  @moduledoc """
  Checks a JSON API response against `PortalWeb.ApiSpec`: the status code
  must be one the operation documents, the content type one that response
  documents, and the body must conform to its schema.

  `OpenApiSpex.TestAssertions.assert_operation_response/2` does the same but
  reads the spec from `conn.private`, which only `PutApiSpec` sets, and the
  `:api` pipeline has no reason to run it.
  """

  import ExUnit.Assertions

  alias OpenApiSpex.{Operation, TestAssertions}

  @doc "The spec, built once per test run."
  def api_spec do
    case :persistent_term.get({__MODULE__, :spec}, nil) do
      nil ->
        spec = PortalWeb.ApiSpec.spec()
        :persistent_term.put({__MODULE__, :spec}, spec)
        spec

      spec ->
        spec
    end
  end

  @doc """
  Asserts `conn`'s response is documented by the operation `operation_id`.
  Returns the decoded body (the raw body for a non-JSON response).
  """
  def assert_documented_response(%Plug.Conn{} = conn, operation_id) do
    spec = api_spec()
    operation = find_operation(spec, operation_id)

    response =
      Map.get(operation.responses, conn.status) ||
        flunk(
          "#{operation_id} answered #{conn.status}, which it does not document " <>
            "(documented: #{inspect(Map.keys(operation.responses))})"
        )

    content_type = conn |> Plug.Conn.get_resp_header("content-type") |> media_type()

    if response.content in [nil, %{}] do
      # A response documented without content: nothing to check the body against.
      conn.resp_body
    else
      assert_documented_body(conn, spec, operation_id, response, content_type)
    end
  end

  defp assert_documented_body(conn, spec, operation_id, response, content_type) do
    media =
      Map.get(response.content || %{}, content_type) ||
        flunk(
          "#{operation_id} #{conn.status} answered #{content_type}, documented: " <>
            "#{inspect(Map.keys(response.content || %{}))}"
        )

    body =
      if content_type == "application/json",
        do: Jason.decode!(conn.resp_body),
        else: conn.resp_body

    TestAssertions.assert_raw_schema(body, media.schema, spec)
    body
  end

  @doc "Asserts `value` conforms to the component schema titled `title`."
  def assert_api_schema(value, title) do
    TestAssertions.assert_schema(value, title, api_spec())
  end

  defp find_operation(spec, operation_id) do
    operations =
      for {_path, item} <- spec.paths,
          {_verb, %Operation{} = op} <- Map.from_struct(item),
          do: op

    Enum.find(operations, &(&1.operationId == operation_id)) ||
      flunk("No operation #{operation_id} in the spec")
  end

  defp media_type([value | _]), do: value |> String.split(";") |> hd() |> String.trim()
  defp media_type([]), do: nil
end
