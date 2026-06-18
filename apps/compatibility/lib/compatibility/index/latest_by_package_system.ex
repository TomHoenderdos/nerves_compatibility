defmodule Compatibility.Index.LatestByPackageSystem do
  @moduledoc """
  Loader and validator for latest_by_pkg_system.json index.

  Schema:
    {
      schema: 2,
      generated_at: iso8601,
      entries: %{
        "<hex_pkg>@<hex_version>|<system_pkg>@<system_version>" => %{
          hex_pkg: string,
          hex_version: string,
          system_pkg: string,
          system_version: string,
          status: "pass" | "fail" | "error" | "skipped" | "unknown",
          run_id: string,
          log_path: string,
          finished_at: iso8601
        }
      }
    }
  """

  alias Compatibility.Types

  defmodule Entry do
    @moduledoc false
    @type t :: %__MODULE__{
            hex_pkg: String.t(),
            hex_version: String.t(),
            system_pkg: String.t(),
            system_version: String.t(),
            status: Types.status(),
            run_id: String.t(),
            log_path: String.t(),
            finished_at: String.t()
          }

    @enforce_keys [
      :hex_pkg,
      :hex_version,
      :system_pkg,
      :system_version,
      :status,
      :run_id,
      :log_path,
      :finished_at
    ]
    defstruct [
      :hex_pkg,
      :hex_version,
      :system_pkg,
      :system_version,
      :status,
      :run_id,
      :log_path,
      :finished_at
    ]
  end

  @type t :: %__MODULE__{
          schema: integer(),
          generated_at: String.t(),
          entries: %{String.t() => Entry.t()}
        }

  @enforce_keys [:schema, :generated_at, :entries]
  defstruct [:schema, :generated_at, :entries]

  @doc """
  Loads and validates a latest_by_pkg_system.json file.
  """
  @spec load(Path.t()) :: {:ok, t()} | {:error, term()}
  def load(path) do
    with {:ok, content} <- File.read(path),
         {:ok, data} <- JSON.decode(content),
         {:ok, index} <- parse(data) do
      {:ok, index}
    end
  end

  @doc """
  Parses a decoded JSON map into the struct.
  """
  @spec parse(map()) :: {:ok, t()} | {:error, term()}
  def parse(%{"schema" => schema, "generated_at" => generated_at, "entries" => entries})
      when is_integer(schema) and is_binary(generated_at) and is_map(entries) do
    case parse_entries(entries) do
      {:ok, parsed_entries} ->
        {:ok,
         %__MODULE__{
           schema: schema,
           generated_at: generated_at,
           entries: parsed_entries
         }}

      error ->
        error
    end
  end

  def parse(_), do: {:error, :invalid_schema}

  defp parse_entries(entries) do
    entries
    |> Enum.reduce_while({:ok, %{}}, fn {key, entry_data}, {:ok, acc} ->
      case parse_entry(entry_data) do
        {:ok, entry} -> {:cont, {:ok, Map.put(acc, key, entry)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_entry(%{
         "hex_pkg" => hex_pkg,
         "hex_version" => hex_version,
         "system_pkg" => system_pkg,
         "system_version" => system_version,
         "status" => status,
         "run_id" => run_id,
         "log_path" => log_path,
         "finished_at" => finished_at
       })
       when is_binary(hex_pkg) and is_binary(hex_version) and is_binary(system_pkg) and
              is_binary(system_version) and is_binary(status) and is_binary(run_id) and
              is_binary(log_path) and is_binary(finished_at) do
    {:ok,
     %Entry{
       hex_pkg: hex_pkg,
       hex_version: hex_version,
       system_pkg: system_pkg,
       system_version: system_version,
       status: Types.parse_status(status),
       run_id: run_id,
       log_path: log_path,
       finished_at: finished_at
     }}
  end

  defp parse_entry(_), do: {:error, :invalid_entry}
end
