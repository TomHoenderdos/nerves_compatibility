defmodule Mix.Tasks.Portal.BuilderCa.ServerCert do
  @shortdoc "Issue or renew the mTLS listener's server certificate"
  @moduledoc """
      mix portal.builder_ca.server_cert --host compatibility.nerves-project.org

  Uses `NCC_BUILDER_CA_KEY` (or `--key`). Issues when missing or within 30
  days of expiry. On a release: `bin/portal eval 'Portal.Builders.CA.ensure_server_cert("HOST")'`.
  """
  use Mix.Task

  @impl true
  def run(args) do
    Mix.Task.run("app.config")
    {opts, _, _} = OptionParser.parse(args, strict: [host: :string, key: :string])
    host = opts[:host] || Mix.raise("--host HOST is required")
    if key = opts[:key], do: Application.put_env(:portal, Portal.Builders.CA, key_path: key)

    case Portal.Builders.CA.ensure_server_cert(host) do
      {:ok, %{certfile: certfile}} -> Mix.shell().info("server certificate at #{certfile}")
      {:error, reason} -> Mix.raise("could not issue the server certificate: #{inspect(reason)}")
    end
  end
end
