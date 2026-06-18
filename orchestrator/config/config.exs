import Config

# Configuration for the Nerves Compatibility Orchestrator

# Polling interval (in milliseconds)
# Default: 1 hour for production
# For development/testing, use shorter intervals:
# config :orchestrator, :poll_interval_ms, :timer.minutes(5)
config :orchestrator, :poll_interval_ms, :timer.hours(1)

# Hex users whose owned packages get prepended to the processing queue on
# each poll. First poll of a clean run is where this matters most — these
# packages get scanned before the general "most recently updated" feed
# chews through everything else. Subsequent polls re-enqueue them (no-ops
# if they're already checked/queued, thanks to Queue.enqueue's dedup).
config :orchestrator, :priority_users, ["nerves", "fhunleth"]

# Optional HTTP ingest API for Cloudflare Pages Functions. Enable only when
# `:scan_request_shared_secret` is configured and the endpoint is reachable
# from Cloudflare.
config :orchestrator, :scan_request_server, false
config :orchestrator, :scan_request_port, 4080
config :orchestrator, :scan_request_shared_secret, System.get_env("NCC_SCAN_REQUEST_SECRET")

# Path to the runner executable
config :orchestrator, :runner_path, Path.expand("../../runner/ncc_runner", __DIR__)

# Docker image for the worker
config :orchestrator, :docker_image, "ncc-worker:local"

# Temporary directory for runner files
config :orchestrator, :runner_tmp_dir, Path.expand("../../runner/tmp", __DIR__)

# Directory for storing compatibility test results
config :orchestrator, :results_dir, Path.expand("../../compat_test_results", __DIR__)

# Directory for public site output
config :orchestrator, :public_dir, Path.expand("../../public", __DIR__)

# Directory for example data
config :orchestrator, :example_data_dir, Path.expand("../../example_data", __DIR__)

# DETS database files (in the orchestrator directory)
config :orchestrator, :queue_file, Path.expand("../queue.dets", __DIR__)
config :orchestrator, :checked_file, Path.expand("../checked.dets", __DIR__)

# Site templates live in site/priv/templates/ on the filesystem. The escript
# bundles priv/ inside its zip archive, but EEx.eval_file uses File.read
# under the hood which can't read from zip paths — so point Site.Generator
# at the real source-tree path. Resolved at compile time.
config :site, :template_dir, Path.expand("../../site/priv/templates", __DIR__)

# Logger configuration
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:module, :function]
