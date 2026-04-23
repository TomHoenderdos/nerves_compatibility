defmodule Mix.Tasks.Site.Gen do
  @moduledoc """
  Generates the static site from JSON index files.

  ## Usage

      mix site.gen --in ./example_data --out ./public

  ## Options

    * `--in` - Input directory containing JSON index files (required)
    * `--out` - Output directory for generated site (required)

  The task will:
    1. Read JSON indexes from the input directory
    2. Generate HTML pages in <out>/site/
    3. Copy JSON data files to <out>/data/
  """

  use Mix.Task

  @shortdoc "Generates the static site"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [in: :string, out: :string],
        aliases: []
      )

    input_dir = opts[:in] || raise "Missing required --in option"
    output_dir = opts[:out] || raise "Missing required --out option"

    Mix.shell().info("Generating site...")
    Mix.shell().info("  Input:  #{input_dir}")
    Mix.shell().info("  Output: #{output_dir}")

    case Site.Generator.generate(input_dir: input_dir, output_dir: output_dir) do
      :ok ->
        Mix.shell().info("✓ Site generated successfully!")
        Mix.shell().info("  Index: #{Path.join([output_dir, "site", "index.html"])}")

      {:error, {:file_not_found, path}} ->
        Mix.shell().error("✗ Required file not found: #{path}")
        exit({:shutdown, 1})

      {:error, reason} ->
        Mix.shell().error("✗ Failed to generate site: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
