defmodule Mix.Tasks.Site.Serve do
  @moduledoc """
  Serves the static site for local development.

  ## Usage

      mix site.serve --dir ./public --port 4000

  ## Options

    * `--dir` - Directory to serve (default: ./public)
    * `--port` - Port to listen on (default: 4000)

  The server will start and print the URL to access the site.
  Press Ctrl+C to stop the server.
  """

  use Mix.Task

  @shortdoc "Serves the static site locally"

  @impl Mix.Task
  def run(args) do
    {opts, _} =
      OptionParser.parse!(args,
        strict: [dir: :string, port: :integer],
        aliases: []
      )

    dir = opts[:dir] || "./public"
    port = opts[:port] || 4000

    unless File.dir?(dir) do
      Mix.shell().error("Directory not found: #{dir}")
      Mix.shell().info("Run 'mix site.gen' first to generate the site.")
      exit({:shutdown, 1})
    end

    # Ensure :inets is started
    Application.ensure_all_started(:inets)

    doc_root = String.to_charlist(Path.expand(dir))

    httpd_config = [
      server_name: ~c"nerves_compat",
      server_root: doc_root,
      document_root: doc_root,
      port: port,
      bind_address: ~c"localhost"
    ]

    case :inets.start(:httpd, httpd_config) do
      {:ok, _pid} ->
        Mix.shell().info("Static site server started!")
        Mix.shell().info("  URL:  http://localhost:#{port}/site/index.html")
        Mix.shell().info("  Dir:  #{dir}")
        Mix.shell().info("")
        Mix.shell().info("Press Ctrl+C to stop")

        # Keep the task running
        Process.sleep(:infinity)

      {:error, reason} ->
        Mix.shell().error("Failed to start server: #{inspect(reason)}")
        exit({:shutdown, 1})
    end
  end
end
