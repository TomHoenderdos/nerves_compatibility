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
  # Deliberately empty: `config/runtime.exs` owns the queue list so a deploy can
  # give each host its own set. Config deep-merges keyword lists, so anything
  # named here would survive the runtime override and run on every node.
  queues: [],
  plugins: [
    # The 60s default deletes a completed job before anyone can look at it. That
    # made the one measurement this pipeline actually needs impossible: how long
    # a build took. `catalog_runs` records only when a run landed, and
    # `started_at` is never written, so `attempted_at`/`completed_at` on the job
    # row is the sole source of per-build duration. At roughly ten builds an
    # hour, six hours of history is a few hundred rows.
    {Oban.Plugins.Pruner, max_age: :timer.hours(6)},
    # Without this, a build node that dies mid-job leaves the job `executing`
    # and its scan request `queued` forever, with no error anywhere. That was a
    # remote possibility while everything ran on one host; with `builds` on a
    # separate box reached over a WAN link it is a question of when.
    #
    # Rescuing is purely time-based, so `rescue_after` has to sit well above the
    # slowest honest build or it would restart one that is still working. Warm
    # builds land in minutes and a cold cache costs tens; two hours leaves room
    # for a first-of-its-kind Nerves system and still catches a dead node the
    # same morning.
    {Oban.Plugins.Lifeline, rescue_after: :timer.hours(2)}
  ]

# Host-side Docker invocation for worker builds.
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
    # deps_path/0, not "../deps": in an umbrella the deps are fetched to the
    # umbrella root, and apps/portal/deps only exists on machines that still
    # have a stale pre-umbrella copy of it.
    env: %{"NODE_PATH" => [Mix.Project.deps_path(), Mix.Project.build_path()]}
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
