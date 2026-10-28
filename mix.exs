defmodule NervesCompatibility.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases(),
      listeners: [Phoenix.CodeReloader]
    ]
  end

  # Umbrella projects will not build a release unless one is named explicitly.
  #
  # ncc_worker is deliberately absent: it is the escript that runs *inside* the
  # worker image, and the portal shells out to `docker` rather than calling it.
  defp releases do
    [
      portal: [
        applications: [compatibility: :permanent, portal: :permanent],
        include_executables_for: [:unix]
      ],
      # The remote builder agent: ships its own ERTS so a builder host needs
      # only Docker, not an Erlang install.
      ncc_agent: [
        # hex_core is code only for the agent (`NccAgent.HexRegistry`):
        # loaded, never started, so neither is the `:ssh` its `.app` lists.
        applications: [compatibility: :permanent, ncc_agent: :permanent, hex_core: :load],
        include_executables_for: [:unix],
        include_erts: true,
        # env.sh.eex, plus overlays/ (the systemd unit, the env example)
        # copied into the release root.
        rel_templates_path: "apps/ncc_agent/rel"
      ]
    ]
  end

  # Dependencies listed here are available only for this umbrella root project
  # and cannot be accessed from applications inside the apps/ folder.
  #
  # Analysis tools belong here so they can run from the umbrella root without
  # adding runtime dependencies to either the portal or worker release.
  defp deps do
    [
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:sobelow, "~> 0.15.0", only: [:dev, :test], runtime: false}
    ]
  end
end
