defmodule NervesCompatibility.MixProject do
  use Mix.Project

  def project do
    [
      apps_path: "apps",
      version: "0.1.0",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: releases()
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
      ]
    ]
  end

  # Dependencies listed here are available only for this umbrella root project
  # and cannot be accessed from applications inside the apps/ folder.
  #
  # `mix_audit` belongs here rather than in a child app: it reads the shared
  # umbrella `mix.lock`, so one copy at the root audits every app at once.
  defp deps do
    [
      {:mix_audit, "~> 2.1", only: [:dev, :test], runtime: false}
    ]
  end
end
