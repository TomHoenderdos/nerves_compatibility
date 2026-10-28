defmodule NccAgent.MixProject do
  use Mix.Project

  def project do
    [
      app: :ncc_agent,
      version: "0.1.0",
      elixir: "~> 1.19",
      build_path: "../../_build",
      config_path: "../../config/config.exs",
      deps_path: "../../deps",
      lockfile: "../../mix.lock",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {NccAgent.Application, []},
      extra_applications: [:logger, :crypto, :ssl, :public_key, :inets],
      # Tests drive `NccAgent.Identity` against a fake portal; they must not
      # boot from (or stop the VM over) the real environment.
      env: [load_config: Mix.env() != :test]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:compatibility, in_umbrella: true},
      {:req, "~> 0.7"},
      # The signed registry's checksums (`NccAgent.HexRegistry`); the portal
      # already uses this version.
      {:hex_core, "~> 0.20.1"},
      {:x509, "~> 0.9"},
      {:jason, "~> 1.2"},
      {:bandit, "~> 1.5", only: :test},
      {:plug, "~> 1.16", only: :test}
    ]
  end
end
