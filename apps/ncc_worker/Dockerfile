# The base determines the OTP version the *target* runs. Official Nerves systems
# moved to OTP 29, and nerves refuses to build when host and target majors differ,
# so this tag and the Elixir build below must stay on the same major.
# nerves_system_br 1.34.1 ships Erlang 29.0.4.
FROM ghcr.io/nerves-project/nerves_system_br:latest

# Install Elixir from GitHub releases
RUN wget https://repo.hex.pm/builds/elixir/v1.20.3-otp-29.zip && \
    unzip v1.20.3-otp-29.zip -d /home/nerves/.elixir && \
    rm v1.20.3-otp-29.zip

ENV PATH="/home/nerves/.elixir/bin:${PATH}"

# Install Hex, Rebar, Nerves Bootstrap, and Igniter archives. nerves_bootstrap
# is pinned: its `mix nerves.new` template is the project every package is
# built in, and 1.17.3 is the first with `--prerelease` (NccWorker.Project).
ARG NERVES_BOOTSTRAP_VERSION=1.17.3
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix archive.install hex nerves_bootstrap ${NERVES_BOOTSTRAP_VERSION} --force && \
    mix archive.install hex igniter_new --force

# mksquashfs sets ownership on the rootfs entries while assembling a firmware
# image. The build container runs with --cap-drop=ALL, so those chowns fail and
# the image build dies. fakeroot fakes the bookkeeping in userspace, which lets
# the firmware step succeed without the container ever holding CAP_CHOWN.
RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends fakeroot && \
    sudo rm -rf /var/lib/apt/lists/*

# argus_beam's escript, pinned. The worker calls it by absolute path, so PATH
# under an arbitrary --user uid does not matter.
#
# Since 0.22 argus solves its rules in FlowLog engines, not Souffle. A release
# ships them prebuilt (a static musl bundle, about 120 MB) and argus downloads
# it on first use. That download happens here, once, by running argus over a
# throwaway project with its cache pointed at /opt/argus-flowlog, so builds
# never reach GitHub: the worker copies this seed into each run's project
# (argus runs an engine only from a cache its own uid owns) and runs argus
# with ARGUS_OFFLINE=1. See NccWorker.Argus. The run fails the image build
# when the bundle cannot be fetched or does not run here.
ARG ARGUS_VERSION=0.24.0
RUN set -eux; \
    mix escript.install hex argus_beam ${ARGUS_VERSION} --force; \
    /home/nerves/.mix/escripts/argus version; \
    sudo install -d -o nerves -g nerves -m 700 /opt/argus-flowlog; \
    cd /tmp; \
    mix new argus_warm; \
    cd argus_warm; \
    mix compile; \
    status=0; \
    ARGUS_FLOWLOG_DIR=/opt/argus-flowlog ARGUS_CACHE_DIR=/tmp/argus-warm-cache \
      /home/nerves/.mix/escripts/argus --project beams \
        --ebin _build/dev/lib/argus_warm/ebin --analyses default,exposure \
        --format json --color never --state-dir /tmp/argus-warm-state \
        > /tmp/argus-warm.json || status=$?; \
    [ "$status" -le 1 ]; \
    ls /opt/argus-flowlog/prebuilt/*/bundle.json; \
    sudo chmod -R a+rX /opt/argus-flowlog; \
    cd /; \
    rm -rf /tmp/argus_warm /tmp/argus-warm-*

# Create mount points
RUN sudo mkdir -p /work /out /hex-cache /home/nerves/.nerves

# Create app directory
WORKDIR /app

# Copy umbrella manifest + config and ONLY the apps the worker needs.
# apps/portal is intentionally NOT copied, so Phoenix/Ash never enter the image.
COPY mix.exs mix.lock ./
COPY config ./config
COPY apps/compatibility ./apps/compatibility
COPY apps/ncc_worker        ./apps/ncc_worker

# Ensure nerves user owns the directories
RUN sudo chown -R nerves:nerves /app /work /out /hex-cache /home/nerves/.nerves

# Build the worker escript. Mix only discovers compatibility + ncc_worker under
# apps/, so dep resolution never pulls Phoenix/Ash/Oban into the image even
# though the umbrella's mix.lock includes those entries.
WORKDIR /app/apps/ncc_worker
# Build the worker escript as a standalone Mix project. Copy the umbrella's
# shared mix.lock so dep versions match the rest of the repo, then let the
# child app resolve its own (tiny) dep closure: compatibility + req + jason.
RUN cp /app/mix.lock mix.lock && mix deps.get && mix escript.build

# Set environment defaults
ENV NCC_INPUT=/work/input.json

# Create bogus ssh keys so that default config works
RUN ssh-keygen -t rsa -N "" -f $HOME/.ssh/id_rsa

# Make the nerves home and app dir usable by any runtime uid. The runner passes
# --user $(id -u):$(id -g) so the container process matches the host user for
# bind-mount ownership, which means it won't be the nerves user baked into the
# image and needs read/write access to the Mix archives, Elixir install, etc.
RUN sudo chmod -R a+rwX /home/nerves /app

# Set entrypoint
ENTRYPOINT ["/app/apps/ncc_worker/ncc_worker"]
