.PHONY: build dev test test-integration format clean help all

WORKER_IMAGE := ncc-worker:local

all: help

help:
	@echo "Nerves Compatibility Tracker"
	@echo ""
	@echo "Targets:"
	@echo "  build            Build the worker Docker image ($(WORKER_IMAGE))"
	@echo "  dev              Start the Phoenix portal server"
	@echo "  test             Run the umbrella test suite"
	@echo "  test-integration Run the Docker-backed portal build integration test"
	@echo "  format           Format the umbrella projects"
	@echo "  clean            Remove generated umbrella build artifacts"

build: apps/ncc_worker/Dockerfile
	@echo "Building worker Docker image..."
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
