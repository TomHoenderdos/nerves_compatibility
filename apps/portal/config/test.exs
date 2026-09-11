import Config

config :portal, Portal.Repo,
  username: System.get_env("PORTAL_PG_USER", "postgres"),
  password: System.get_env("PORTAL_PG_PASSWORD", "postgres"),
  hostname: System.get_env("PORTAL_PG_HOST", "localhost"),
  database: "portal_test#{System.get_env("MIX_TEST_PARTITION")}",
  port: String.to_integer(System.get_env("PORTAL_PG_PORT", "5432")),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: System.schedulers_online() * 2

# Disable Oban queues + plugins during tests; jobs run inline via `Oban.Testing`.
config :portal, Oban, testing: :manual

# Tests must see their own writes, and a shared ETS table would leak derived
# aggregates between them. 0 bypasses the cache entirely.
config :portal, Portal.Catalog.Cache, ttl_ms: 0

# Isolate Builder scratch + artifact store under tmp during tests.
config :portal, Portal.Builder,
  docker_image: "ncc-worker:local",
  scratch_root: Path.join(System.tmp_dir!(), "ncc-test-scratch"),
  nerves_cache: Path.join(System.tmp_dir!(), "ncc-test-nerves-cache"),
  hex_cache: Path.join(System.tmp_dir!(), "ncc-test-hex-cache")

config :portal, :artifact_store, path: Path.join(System.tmp_dir!(), "ncc-test-artifacts")

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :portal, PortalWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "5xw4EhV2dY7qQuovEyJb+WxGCvtoQr0x+8LmUawav5Xmv0o8LJFp5FVM0WYBNoy7",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
