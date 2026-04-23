import Config

# Development configuration - shorter poll intervals for testing

config :orchestrator, :poll_interval_ms, :timer.minutes(5)

# More verbose logging in development
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module, :function],
  level: :debug
