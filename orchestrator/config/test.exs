import Config

# Test configuration - very short intervals and in-memory testing

config :orchestrator, :poll_interval_ms, :timer.seconds(1)

config :logger, level: :warning
