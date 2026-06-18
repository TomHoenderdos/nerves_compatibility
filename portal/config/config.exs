import Config

config :ash, :validate_domain_resource_inclusion?, false

config :portal,
  ash_domains: [Portal.Accounts, Portal.ScanRequests],
  ecto_repos: [Portal.Repo],
  generators: [timestamp_type: :utc_datetime]

config :portal, PortalWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: PortalWeb.ErrorHTML, json: PortalWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Portal.PubSub,
  live_view: [signing_salt: "h07XGKsu"]

config :esbuild,
  version: "0.25.4",
  portal: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/*),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

config :tailwind,
  version: "4.1.7",
  portal: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

config :logger, :default_formatter, format: "$time $metadata[$level] $message\n"

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
