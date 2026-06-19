.PHONY: build run shell clean realclean help collect site test-all test-integration deploy-site all

# Default target - build and generate site
all: site
	@echo ""
	@echo "✓ Site ready at public/site/index.html"
	@echo "  Open with: open public/site/index.html"

# Default help message
help:
	@echo "Nerves Compatibility Check - Makefile"
	@echo ""
	@echo "Targets:"
	@echo "  all       - Collect results and generate site (default)"
	@echo "  build     - Build the worker Docker image"
	@echo "  run       - Run the runner to test a package"
	@echo "  test-all  - Run tests for all packages"
	@echo "  test-integration - Run runner end-to-end integration test (needs docker + built image)"
	@echo "  collect   - Collect test results into compat_test_results/"
	@echo "  site      - Generate the static website"
	@echo "  deploy-site - Build the site and push it to Cloudflare Pages (requires wrangler CLI + auth)"
	@echo "  shell     - Start an interactive shell in the worker container"
	@echo "  clean     - Clean up temporary files and containers"
	@echo "  realclean - Clean and also purge caches"
	@echo ""
	@echo "Variables:"
	@echo "  PACKAGE   - Package to test (default: circuits_gpio:2.1.3)"

# Configuration
WORKER_IMAGE := ncc-worker:local
PACKAGE ?= circuits_gpio:2.1.3
PACKAGE_NAME := $(shell echo $(PACKAGE) | cut -d: -f1)
WORK_DIR := runner/tmp/$(PACKAGE_NAME)-work
OUTPUT_DIR := runner/tmp/$(PACKAGE_NAME)-results
JOB_FILE := runner/tmp/job.json
NERVES_CACHE := $(HOME)/.ncc-nerves-cache
HEX_CACHE := $(HOME)/.ncc-hex-cache
RESULTS_DIR := compat_test_results
TEST_PACKAGES := crc32cer:1.1.1 circuits_gpio:2.1.3 phoenix:1.8.3

# Build the worker Docker image
# Run this whenever changing the Dockerfile or worker code
build: apps/ncc_worker/Dockerfile
	@echo "Building worker Docker image..."
	docker build --no-cache -f apps/ncc_worker/Dockerfile -t $(WORKER_IMAGE) .
	@echo "Build complete: $(WORKER_IMAGE)"

# Run the runner with a job
run:
	@echo "Creating job file for package: $(PACKAGE)"
	@mkdir -p runner/tmp $(NERVES_CACHE) $(HEX_CACHE)
	@echo '{\n  "run_id": "test-'$$(date +%s)'",\n  "image_name": "$(WORKER_IMAGE)",\n  "image_digest": "'$$(docker inspect --format='{{index .RepoDigests 0}}' $(WORKER_IMAGE) 2>/dev/null | cut -d@ -f2 || echo "sha256:local")'",\n  "package": {\n    "name": "'$$(echo $(PACKAGE) | cut -d: -f1)'",\n    "version": "'$$(echo $(PACKAGE) | cut -d: -f2)'"\n  },\n  "cache_dir": "$(abspath $(HEX_CACHE))"\n}' > $(JOB_FILE)
	@echo "Building runner escript..."
	cd runner && mix deps.get && mix escript.build
	@echo "Running job: $(JOB_FILE)"
	@echo "Using Nerves cache: $(NERVES_CACHE)"
	@echo "Using Hex cache: $(HEX_CACHE)"
	@rm -rf $(WORK_DIR) $(OUTPUT_DIR)
	@mkdir -p $(WORK_DIR) $(OUTPUT_DIR)
	cd runner && NCC_NERVES_CACHE=$(abspath $(NERVES_CACHE)) ./ncc_runner run --input ../$(JOB_FILE) --output-dir ../$(OUTPUT_DIR) --work-dir ../$(WORK_DIR)
	@echo "Results written to: $(OUTPUT_DIR)"
	@echo ""
	@echo "View result:"
	@echo "  cat $(OUTPUT_DIR)/result.json | jq ."
	@echo ""
	@echo "View logs:"
	@echo "  ls $(OUTPUT_DIR)/logs/"

# Start an interactive shell in the worker container
# Optionally specify PACKAGE to set up the project for that package
shell:
ifdef PACKAGE
	@echo "Setting up environment for package: $(PACKAGE)"
	@mkdir -p $(WORK_DIR) $(OUTPUT_DIR) $(NERVES_CACHE) $(HEX_CACHE)
	@echo '{\n  "run_id": "shell-'$$(date +%s)'",\n  "image_name": "$(WORKER_IMAGE)",\n  "image_digest": "'$$(docker inspect --format='{{index .RepoDigests 0}}' $(WORKER_IMAGE) 2>/dev/null | cut -d@ -f2 || echo "sha256:local")'",\n  "package": {\n    "name": "'$$(echo $(PACKAGE) | cut -d: -f1)'",\n    "version": "'$$(echo $(PACKAGE) | cut -d: -f2)'"\n  },\n  "paths": {\n    "work_dir": "/work",\n    "output_dir": "/out"\n  },\n  "cache_dir": "$(abspath $(HEX_CACHE))"\n}' > $(OUTPUT_DIR)/input.json
	@echo ""
	@echo "Starting interactive shell..."
	@echo "Run: /app/apps/ncc_worker/ncc_worker setup"
	@echo "Then: cd proj && MIX_TARGET=<target> mix firmware"
	@echo ""
	@docker run --rm -it \
		--user $$(id -u):$$(id -g) \
		--mount type=bind,source=$(abspath $(WORK_DIR)),target=/work \
		--mount type=bind,source=$(abspath $(OUTPUT_DIR)),target=/out \
		--mount type=bind,source=$(NERVES_CACHE),target=/home/nerves/.nerves \
		--mount type=bind,source=$(HEX_CACHE),target=/hex-cache \
		-e HEX_HOME=/hex-cache \
		-e HOME=/home/nerves \
		-e NCC_INPUT=/out/input.json \
		-w /work \
		--entrypoint sh \
		$(WORKER_IMAGE)
else
	@echo "Starting interactive shell in worker container..."
	@mkdir -p runner/tmp/debug-work runner/tmp/debug-output $(NERVES_CACHE) $(HEX_CACHE)
	@docker run --rm -it \
		--user $$(id -u):$$(id -g) \
		--mount type=bind,source=$(PWD)/runner/tmp/debug-work,target=/work \
		--mount type=bind,source=$(PWD)/runner/tmp/debug-output,target=/out \
		--mount type=bind,source=$(NERVES_CACHE),target=/home/nerves/.nerves \
		--mount type=bind,source=$(HEX_CACHE),target=/hex-cache \
		-e HEX_HOME=/hex-cache \
		-e HOME=/home/nerves \
		-w /work \
		--entrypoint sh \
		$(WORKER_IMAGE)
endif

# Clean up temporary files
clean:
	@echo "Cleaning up temporary files..."
	rm -rf runner/tmp/*-work runner/tmp/*-results runner/tmp/debug-work runner/tmp/debug-output runner/tmp/job.json
	rm -rf runner/tmp/*
	rm -rf $(RESULTS_DIR)
	rm -rf public/data public/site
	rm -f runner/ncc_runner
	@echo "Clean complete"

realclean: clean
	@echo "Purging caches..."
	rm -rf $(NERVES_CACHE) $(HEX_CACHE)
	@echo "Real clean complete"

# Collect test results from runner output directories.
#
# Two workflows feed into $(RESULTS_DIR):
#   1. Manual: `make test-all` → results land in runner/tmp/*-results/ →
#      this target copies them over.
#   2. Orchestrator: writes straight to $(RESULTS_DIR) and cleans up
#      runner/tmp after each package — nothing to copy.
#
# Fail only when both sources are empty; otherwise fall through so
# `make site` works with whatever results already exist.
collect:
	@echo "Collecting test results..."
	@mkdir -p $(RESULTS_DIR) public/data/logs
	@count=0; \
	for result in runner/tmp/*-results/result.json; do \
		if [ -f "$$result" ]; then \
			pkg_name=$$(basename $$(dirname "$$result") | sed 's/-results$$//'); \
			cp "$$result" "$(RESULTS_DIR)/$${pkg_name}.json"; \
			logs_src=$$(dirname "$$result")/logs; \
			if [ -d "$$logs_src" ]; then \
				dest_dir=public/data/logs/$${pkg_name}; \
				rm -rf "$$dest_dir"; \
				mkdir -p "$$dest_dir"; \
				cp "$$logs_src"/*.log "$$dest_dir"/; \
				echo "  ✓ Copied logs for $${pkg_name}"; \
			fi; \
			echo "  ✓ Collected $${pkg_name}"; \
			count=$$((count + 1)); \
		fi; \
	done; \
	existing=$$(ls "$(RESULTS_DIR)"/*.json 2>/dev/null | wc -l | tr -d ' '); \
	if [ "$$count" -gt 0 ]; then \
		echo "Collected $$count new result(s); $(RESULTS_DIR) now has $$existing total"; \
	elif [ "$$existing" -gt 0 ]; then \
		echo "No new results in runner/tmp — using $$existing already in $(RESULTS_DIR)"; \
	else \
		echo "  ✗ No results found. Run 'make test-all' or start the orchestrator first."; \
		exit 1; \
	fi

# Generate the static website
site: collect
	@echo "Generating website..."
	cd site && mix convert_results --input ../$(RESULTS_DIR) --output ../public/data
	cd site && mix site.gen --in ../public/data --out ../public
	@echo "✓ Website generated at public/site/index.html"

# Build the site with production URLs baked in and push it to Cloudflare
# Pages via wrangler.  Override SITE_BASE_URL / PRECOMPILED_FILES_BASE /
# PRECOMPILED_MANIFESTS_BASE on the command line to target staging or
# preview builds.  Pre-reqs:
#   1. `npm install -g wrangler` (or `brew install cloudflare-wrangler`)
#   2. `wrangler login`
#   3. `wrangler pages project create compatibility-embedded-elixir`  (once)
# Then every subsequent deploy is just `make deploy-site`.
SITE_BASE_URL ?= https://compatibility.embedded-elixir.com
deploy-site:
	@command -v npx >/dev/null || { echo "npx not found — install Node.js first"; exit 1; }
	$(MAKE) site
	SITE_BASE_URL=$(SITE_BASE_URL) \
	  cd site && mix site.gen --in ../public/data --out ../public
	# Stage to a deploy-only tree that excludes the precompiled-binary
	# blob store. Individual artifacts can exceed CF Pages' 25 MiB
	# per-file ceiling (toolchains are hundreds of MiB), and the whole
	# directory is destined for R2 anyway when the binaries API goes
	# live on its own host. `wrangler pages deploy` has no native
	# exclude flag, so we stage with rsync and deploy the staging dir.
	@rm -rf public/.deploy
	@mkdir -p public/.deploy/data
	rsync -a --exclude='files/' public/site/ public/.deploy/
	# Package-page log links are relative (../../data/logs/<pkg>/<sys>.log),
	# so the logs need to land at /data/logs/ under the deploy root.
	# Logs live outside public/site/ locally (public/data/logs/), so
	# copy them in explicitly.
	rsync -a public/data/logs public/.deploy/data/
	npx wrangler pages deploy public/.deploy --project-name=compatibility-embedded-elixir

# Run the end-to-end integration test against the real worker container.
# Rebuilds the runner escript first so the test exercises current code.
test-integration:
	cd runner && mix deps.get && mix escript.build
	cd runner && mix test --only integration

# Run tests for all packages
test-all:
	@echo "Running tests for all packages..."
	@for pkg in $(TEST_PACKAGES); do \
		echo ""; \
		echo "========================================"; \
		echo "Testing: $$pkg"; \
		echo "========================================"; \
		$(MAKE) run PACKAGE=$$pkg || echo "⚠ Test failed for $$pkg"; \
	done
	@echo ""
	@echo "All tests complete! Run 'make collect' and 'make site' to generate the website."

format:
	@cd apps/compatibility && mix format
	@cd apps/ncc_worker && mix format
	@cd runner && mix format
	@cd site && mix format
	@echo "Formatted all code."
