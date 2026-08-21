.PHONY: build build-clean dev test test-integration format clean help all

WORKER_IMAGE := ncc-worker:local

all: help

help:
	@echo "Nerves Compatibility Tracker"
	@echo ""
	@echo "Targets:"
	@echo "  build            Build the worker Docker image ($(WORKER_IMAGE))"
	@echo "  build-clean      Same, but with --no-cache"
	@echo "  dev              Start the Phoenix portal server"
	@echo "  test             Run the umbrella test suite"
	@echo "  test-integration Run the Docker-backed portal build integration test"
	@echo "  format           Format the umbrella projects"
	@echo "  clean            Remove generated umbrella build artifacts"

# Layer caching is on. The Dockerfile COPYs apps/ncc_worker and
# apps/compatibility, so a source change invalidates from that layer down on its
# own; --no-cache only threw away the apt, Elixir and hex-archive layers above
# it and turned every rebuild into a ~1.67GB from-scratch build. Use
# `make build-clean` when you actually want those refetched.
build: apps/ncc_worker/Dockerfile
	@echo "Building worker Docker image..."
	docker build -f apps/ncc_worker/Dockerfile -t $(WORKER_IMAGE) .
	@echo "Build complete: $(WORKER_IMAGE)"

build-clean: apps/ncc_worker/Dockerfile
	@echo "Building worker Docker image from scratch..."
	docker build --no-cache -f apps/ncc_worker/Dockerfile -t $(WORKER_IMAGE) .
	@echo "Build complete: $(WORKER_IMAGE)"

dev:
	mix phx.server

test:
	mix test

test-integration:
	mix test apps/portal/test/portal/workers/build_integration_test.exs --only integration

format:
	mix format
	@echo "Formatted umbrella code."

clean:
	@echo "Cleaning generated umbrella build artifacts..."
	rm -rf _build deps apps/*/_build apps/*/deps
	@echo "Clean complete"
