defmodule NccWorker.MixProject do
  use Mix.Project

  def project() do
    [
      app: :ncc_worker,
      version: "0.1.0",
      elixir: "~> 1.14",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
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
      {:beam_scanner, path: "../beam_scanner"},
      {:compat, path: "../compat"},
      {:req, "~> 0.5.0"}
    ]
  end

  defp escript() do
    [
      main_module: NccWorker.CLI,
      name: "ncc_worker"
    ]
  end
end
