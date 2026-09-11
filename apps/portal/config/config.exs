import Config

config :ash, :validate_domain_resource_inclusion?, false

# Required from ash 3.33: the unit `min_length`/`max_length` and `string_length`
# count in. `:mixed` keeps the pre-3.33 behaviour, where Elixir counted
# graphemes and the SQL data layer counted codepoints -- a grapheme can be an
# unbounded number of codepoints, so `max_length` bounded nothing, which is the
# DoS the advisory is about. `:codepoints` is the fix and matches Postgres.
#
# No resource here sets a length constraint today, so this is inert for us; it
# is set to the correct value so it stays inert when one is added.
config :ash, :default_string_length_count, :codepoints

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
    # builds land in minutes and a cold cache costs tens.
    #
    # Two hours was wrong: it is exactly `Portal.Builder.total_timeout_ms/0`, so
    # a build running right up against its own wall clock could be rescued while
    # still executing — a second container and a second multi-gigabyte scratch
    # tree for work already in flight. Three hours clears the wall clock and
    # matches `Portal.Workers.Sweep`'s scratch retention, so the two agree on
    # when a build is definitely over.
    {Oban.Plugins.Lifeline, rescue_after: :timer.hours(3)},
    # Hourly, off the :00 mark. The plugin inserts only on the Oban leader, but
    # the row it inserts carries `Sweep`'s own `:ingest` queue — which only the
    # build host runs — so it executes on the machine that actually has the
    # disks, whichever node holds leadership.
    {Oban.Plugins.Cron,
     crontab: [
       {"23 * * * *", Portal.Workers.Sweep},
       # Daily, well off the hour and off the sweep. Retention deletes rows
       # rather than files, so it carries `:maintenance` — the web host's queue
       # — while `Sweep` carries `:ingest` to land on the machine with the
       # disks. Once a day is often enough: the budget is sized with a day of
       # slack in it, and the deletes take an exclusive lock on rows a page may
       # be reading.
       {"41 3 * * *", Portal.Workers.LogRetention}
     ]}
  ]

# How many bytes of stored per-system build logs the database may hold.
# Runtime-overridable in config/runtime.exs (NCC_LOG_BUDGET_MB).
#
# Nothing caps this database — it is a self-hosted container on a 244 GB disk
# with 155 GB free, not the 1 GB managed instance an earlier comment here
# claimed (see `Portal.Workers.LogRetention`). The budget exists because a bad
# week of failing builds across ~2500 packages could store tens of gigabytes of
# logs without anyone deciding to, which is a real risk at any disk size.
config :portal, Portal.Workers.LogRetention, budget_bytes: 2 * 1024 * 1024 * 1024

# The dashboard, stats and cluster pages fold every package, run and system
# result in Elixir -- 655ms warm on production, paid twice per page view because
# a LiveView mounts once for the static render and again on socket connect.
# 60s of staleness on a build-results page costs nothing; see
# `Portal.Catalog.Cache` for why this is a TTL and not invalidation on ingest.
config :portal, Portal.Catalog.Cache, ttl_ms: :timer.seconds(60)

# Host-side Docker invocation for worker builds.
# Runtime-overridable in config/runtime.exs.
config :portal, Portal.Builder,
  docker_image: "ncc-worker:local",
  scratch_root: Path.expand("~/.ncc-scratch"),
  nerves_cache: Path.expand("~/.ncc-nerves-cache"),
  hex_cache: Path.expand("~/.ncc-hex-cache"),
  # Refuse to start a build with less than this free on the scratch filesystem.
  # One scratch tree is ~3.5G and the build host runs `builds:3`, so 25G is
  # roughly two builds of headroom above the worst case. This is a refusal, not
  # a reservation — `Portal.Workers.Sweep` is what maintains the headroom.
  min_free_disk_gb: 25,
  # How long a scratch dir may sit before `Sweep` treats it as orphaned: the 2h
  # docker wall clock plus an hour for the ingest handoff.
  scratch_max_age_ms: :timer.hours(3)

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
