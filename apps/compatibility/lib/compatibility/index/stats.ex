defmodule Compatibility.Index.Stats do
  @moduledoc """
  Loader and validator for stats.json index.

  Schema:
    {
      schema: 2,
      generated_at: iso8601,
      counts: %{
        total: integer,
        pass: integer,
        fail: integer,
        error: integer,
        skipped: integer,
        unknown: integer
      },
      by_system: %{
        "<system_pkg>@<system_version>" => %{
          pass: integer,
          fail: integer,
          error: integer,
          skipped: integer,
          unknown: integer
        }
      },
      last_run_finished_at: iso8601,
      beam_stats: {
        packages_with_beam_scan: integer,
        languages: %{language => integer},
        packages_with_nif: integer,
        packages_with_protocols: integer,
        packages_with_start_callback: integer,
        packages_with_shell: integer,
        packages_with_halt: integer,
        avg_beam_count_per_pkg: float | nil
      }
    }
  """

  defmodule Counts do
    @moduledoc false
    @type t :: %__MODULE__{
            total: integer(),
            total_versions: integer(),
            pass: integer(),
            fail: integer(),
            error: integer(),
            skipped: integer(),
            unknown: integer()
          }

    @enforce_keys [:total, :total_versions, :pass, :fail, :error, :skipped, :unknown]
    defstruct [:total, :total_versions, :pass, :fail, :error, :skipped, :unknown]
  end

  defmodule SystemCounts do
    @moduledoc false
    @type t :: %__MODULE__{
            pass: integer(),
            fail: integer(),
            error: integer(),
            skipped: integer(),
            unknown: integer()
          }

    @enforce_keys [:pass, :fail, :error, :skipped, :unknown]
    defstruct [:pass, :fail, :error, :skipped, :unknown]
  end

  @type t :: %__MODULE__{
          schema: integer(),
          generated_at: String.t(),
          counts: Counts.t(),
          by_system: %{String.t() => SystemCounts.t()},
          last_run_finished_at: String.t(),
          beam_stats: map()
        }

  @enforce_keys [:schema, :generated_at, :counts, :by_system, :last_run_finished_at]
  defstruct [:schema, :generated_at, :counts, :by_system, :last_run_finished_at, beam_stats: %{}]

  @doc """
  Loads and validates a stats.json file.
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
  def parse(
        %{
          "schema" => schema,
          "generated_at" => generated_at,
          "counts" => counts,
          "by_system" => by_system,
          "last_run_finished_at" => last_run
        } = data
      )
      when is_integer(schema) and is_binary(generated_at) and is_map(counts) and
             is_map(by_system) and is_binary(last_run) do
    with {:ok, parsed_counts} <- parse_counts(counts),
         {:ok, parsed_by_system} <- parse_by_system(by_system) do
      beam_stats = Map.get(data, "beam_stats", %{})

      {:ok,
       %__MODULE__{
         schema: schema,
         generated_at: generated_at,
         counts: parsed_counts,
         by_system: parsed_by_system,
         last_run_finished_at: last_run,
         beam_stats: beam_stats
       }}
    end
  end

  def parse(_), do: {:error, :invalid_schema}

  defp parse_counts(%{
         "total" => total,
         "total_versions" => total_versions,
         "pass" => pass,
         "fail" => fail,
         "error" => error,
         "skipped" => skipped,
         "unknown" => unknown
       })
       when is_integer(total) and is_integer(total_versions) and is_integer(pass) and
              is_integer(fail) and is_integer(error) and is_integer(skipped) and
              is_integer(unknown) do
    {:ok,
     %Counts{
       total: total,
       total_versions: total_versions,
       pass: pass,
       fail: fail,
       error: error,
       skipped: skipped,
       unknown: unknown
     }}
  end

  defp parse_counts(_), do: {:error, :invalid_counts}

  defp parse_by_system(by_system) do
    by_system
    |> Enum.reduce_while({:ok, %{}}, fn {sys_key, sys_counts}, {:ok, acc} ->
      case parse_system_counts(sys_counts) do
        {:ok, counts} -> {:cont, {:ok, Map.put(acc, sys_key, counts)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_system_counts(%{
         "pass" => pass,
         "fail" => fail,
         "error" => error,
         "skipped" => skipped,
         "unknown" => unknown
       })
       when is_integer(pass) and is_integer(fail) and is_integer(error) and is_integer(skipped) and
              is_integer(unknown) do
    {:ok,
     %SystemCounts{
       pass: pass,
       fail: fail,
       error: error,
       skipped: skipped,
       unknown: unknown
     }}
  end

  defp parse_system_counts(_), do: {:error, :invalid_system_counts}
end
