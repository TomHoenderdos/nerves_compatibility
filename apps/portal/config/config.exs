import Config

config :ash, :validate_domain_resource_inclusion?, false

# The Build ingestion creates Catalog rows inside one Ecto transaction, so Ash
# can't dispatch after-action notifications until commit. That's expected here;
# silence the otherwise-noisy "missed notifications" warnings.
config :ash, :missed_notifications, :ignore

config :portal,
  ash_domains: [Portal.Accounts, Portal.ScanRequests, Portal.Catalog],
  ecto_repos: [Portal.Repo],
  generators: [timestamp_type: :utc_datetime]

config :portal, Oban,
  repo: Portal.Repo,
  queues: [builds: 1, intake: 5, maintenance: 1],
  plugins: [Oban.Plugins.Pruner]

# Host-side Docker invocation (ported from the standalone runner/orchestrator).
# Runtime-overridable in config/runtime.exs.
config :portal, Portal.Builder,
  docker_image: "ncc-worker:local",
  scratch_root: Path.expand("~/.ncc-scratch"),
  nerves_cache: Path.expand("~/.ncc-nerves-cache"),
  hex_cache: Path.expand("~/.ncc-hex-cache")

# Content-addressed artifact blob store (firmware, precompiled BEAM, etc).
# The Build worker moves the worker's files_dir outputs here.
config :portal, :artifact_store, path: Path.expand("~/.ncc-artifacts")

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
