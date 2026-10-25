defmodule Compatibility.MixProject do
  use Mix.Project

  def project do
    [
      app: :compatibility,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      test_ignore_filters: [&String.starts_with?(&1, "test/fixtures/")]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    []
  end
end
