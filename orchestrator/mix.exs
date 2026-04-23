defmodule Orchestrator.MixProject do
  use Mix.Project

  def project() do
    [
      app: :orchestrator,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      escript: escript()
    ]
  end

  def application() do
    [
      # :eex is required at runtime because Processor.regenerate_site/0 calls
      # into Site.Generator, which uses EEx.eval_file/2 to render HTML
      # templates. Without it the escript loads but every site regen raises
      # UndefinedFunctionError on EEx.eval_file/2.
      extra_applications: [:logger, :crypto, :eex],
      mod: {Orchestrator.Application, []}
    ]
  end

  defp deps() do
    [
      {:req, "~> 0.5"},
      {:req_hex, "~> 0.2"},
      {:ncc_runner, path: "../runner"},
      {:site, path: "../site"}
    ]
  end

  defp escript() do
    [
      main_module: Orchestrator.CLI,
      name: "ncc_orchestrator"
    ]
  end
end
