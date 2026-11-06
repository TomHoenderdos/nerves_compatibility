defmodule NccWorker.MixProject do
  use Mix.Project

  def project() do
    [
      app: :ncc_worker,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      elixirc_paths: elixirc_paths(Mix.env()),
      escript: escript()
    ]
  end

  def application() do
    [
      extra_applications: [:logger, :crypto, :inets, :ssl, :public_key]
    ]
  end

  defp deps() do
    [
      {:compatibility, in_umbrella: true},
      {:req, "~> 0.7"}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_env), do: ["lib"]

  defp escript() do
    [
      main_module: NccWorker.CLI,
      name: "ncc_worker"
    ]
  end
end
