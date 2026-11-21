defmodule Portal.Test.RelocationFixtures do
  @moduledoc """
  A relocation record (`Compatibility.Relocation`) as the worker writes one,
  at the worker's own three roots, so the portal's pins
  (`Compatibility.Relocation.pinned_problem/1`) hold it, and an `ebin` the
  ingest's source check (`Compatibility.Relocation.compiled_in_problem/3`)
  takes: a real beam compiled from the package's dir under the first
  root's deps path, and its `.app` file.
  """

  @doc "The record of `beam` (an `ebin/<beam>` path) with one `LitT` occurrence."
  @spec record(String.t()) :: map()
  def record(beam) do
    Map.put(Compatibility.Relocation.pinned_record(1), "files", [
      %{
        "path" => "ebin/#{beam}.beam",
        "occurrences" => [
          %{
            "chunk" => "LitT",
            "index" => 0,
            "term" => [],
            "kind" => "binary",
            "parts" => ["", "deps", "/#{beam}/c_include"]
          }
        ]
      }
    ])
  end

  @doc """
  The record of a dependent that passed because a dependency was held: the
  three roots and no file to rewrite (the umbrella re-review's Q1).
  """
  @spec dependent_record() :: map()
  def dependent_record, do: Map.put(Compatibility.Relocation.pinned_record(1), "files", [])

  @doc """
  A beam of a module unique to this call, compiled as if from
  `<deps>/<app>/lib/<app>.ex` (default deps: the worker's first root). The
  source file need not exist: only its name goes into `CInf`.
  """
  @spec beam(String.t(), String.t()) :: binary()
  def beam(app, deps \\ Compatibility.Relocation.first_root()["deps"]) do
    module = Module.concat(["RelocFixture#{System.unique_integer([:positive])}"])
    file = Path.join([deps, app, "lib", "#{app}.ex"])
    source = "defmodule #{inspect(module)} do\n  def app, do: #{inspect(app)}\nend\n"
    [{^module, bytes}] = Code.compile_string(source, file)
    :code.delete(module)
    :code.purge(module)
    bytes
  end

  @doc "An `.app` file's bytes for `app`."
  @spec app(String.t()) :: binary()
  def app(app), do: "{application, '#{app}', [{modules, []}]}.\n"
end
