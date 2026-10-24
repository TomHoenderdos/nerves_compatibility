.PHONY: build build-clean build-toolchains toolchain-tags dev test test-integration format clean help all

WORKER_IMAGE := ncc-worker:local

# Toolchain images, as space-separated `tag=base` pairs: the worker on a plain
# Elixir/OTP pair (apps/ncc_worker/Dockerfile.toolchain). Each tag must also be
# in Portal.Toolchains' images. Bases are pinned: Elixir 1.19.3 on the newest
# OTP 28 patch, bookworm, slim. A deploy passes TOOLCHAIN_SUFFIX=-deploy to
# build candidate tags beside the live ones.
TOOLCHAIN_IMAGES := ncc-worker:elixir-1.19-otp-28=hexpm/elixir:1.19.3-erlang-28.5.0.2-debian-bookworm-20260610-slim
TOOLCHAIN_SUFFIX :=

all: help

help:
	@echo "Nerves Compatibility Tracker"
	@echo ""
	@echo "Targets:"
	@echo "  build            Build the worker Docker image ($(WORKER_IMAGE))"
	@echo "  build-clean      Same, but with --no-cache"
	@echo "  build-toolchains Build the toolchain worker images (TOOLCHAIN_IMAGES)"
	@echo "  dev              Start the Phoenix portal server"
	@echo "  test             Run the umbrella test suite"
	@echo "  test-integration Run the Docker-backed portal build and toolchain integration tests"
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

build-toolchains: apps/ncc_worker/Dockerfile.toolchain
	@set -e; for pair in $(TOOLCHAIN_IMAGES); do \
	  tag=$${pair%%=*}; base=$${pair#*=}; \
	  echo "Building toolchain image $$tag$(TOOLCHAIN_SUFFIX) from $$base..."; \
	  docker build -f apps/ncc_worker/Dockerfile.toolchain --build-arg BASE=$$base -t $$tag$(TOOLCHAIN_SUFFIX) .; \
	done
	@echo "Toolchain images built."

# The toolchain tags alone, one per line, for ops/builder-deploy.sh.
toolchain-tags:
	@for pair in $(TOOLCHAIN_IMAGES); do echo "$${pair%%=*}"; done

dev:
	mix phx.server

test:
	mix test

test-integration:
	mix test apps/portal/test/portal/workers/build_integration_test.exs apps/portal/test/portal/workers/toolchain_integration_test.exs --only integration

format:
	mix format
	@echo "Formatted umbrella code."

clean:
	@echo "Cleaning generated umbrella build artifacts..."
	rm -rf _build deps apps/*/_build apps/*/deps
	@echo "Clean complete"
