defmodule Mix.Tasks.Portal.BuilderCa.Init do
  @shortdoc "Create the remote-builder CA key and certificate"
  @moduledoc """
      mix portal.builder_ca.init --key PATH

  `PATH` is wherever the operator wants the CA key to live (the same path
  `NCC_BUILDER_CA_KEY` points at in prod). Writes the key (mode 600) and
  `ca.pem` beside it; refuses to overwrite.
  On a release: `bin/portal eval 'Portal.Builders.CA.init("PATH")'`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(args, strict: [key: :string])
    key = opts[:key] || Mix.raise("--key PATH is required")

    case Portal.Builders.CA.init(key) do
      {:ok, %{cert_path: cert}} -> Mix.shell().info("wrote #{key} and #{cert}")
      {:error, :exists} -> Mix.raise("#{key} exists; refusing to overwrite")
    end
  end
end
