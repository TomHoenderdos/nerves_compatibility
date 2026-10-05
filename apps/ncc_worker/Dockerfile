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

# Install Hex, Rebar, Nerves Bootstrap, and Igniter archives
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix archive.install hex nerves_bootstrap --force && \
    mix archive.install hex igniter_new --force

# mksquashfs sets ownership on the rootfs entries while assembling a firmware
# image. The build container runs with --cap-drop=ALL, so those chowns fail and
# the image build dies. fakeroot fakes the bookkeeping in userspace, which lets
# the firmware step succeed without the container ever holding CAP_CHOWN.
RUN sudo apt-get update && \
    sudo apt-get install -y --no-install-recommends fakeroot && \
    sudo rm -rf /var/lib/apt/lists/*

# Souffle evaluates argus's Datalog rules. Upstream ships only an x86_64 .deb;
# arm64 (local Docker on Apple silicon) builds the same tag from source. mcpp is
# the preprocessor souffle runs over every .dl file.
ARG SOUFFLE_VERSION=2.5
RUN set -eux; \
    sudo apt-get update; \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      deb="x86_64-ubuntu-2404-souffle-${SOUFFLE_VERSION}-Linux.deb"; \
      wget -q "https://github.com/souffle-lang/souffle/releases/download/${SOUFFLE_VERSION}/${deb}" -O "/tmp/${deb}"; \
      echo "6b86e554f6aa5abf8a8b55d8312ae37c0957c5bd6c9edeea89246db9406f645ec5e600b84fe6636b1c163da556f0da6c3d2dad46c1083413f2fcf4f95b9ac62c  /tmp/${deb}" | sha512sum -c -; \
      sudo apt-get install -y --no-install-recommends "/tmp/${deb}"; \
      rm -f "/tmp/${deb}"; \
    else \
      sudo apt-get install -y --no-install-recommends bison flex cmake g++ make mcpp \
        libffi-dev libsqlite3-dev zlib1g-dev libncurses-dev; \
      wget -q "https://github.com/souffle-lang/souffle/archive/refs/tags/${SOUFFLE_VERSION}.tar.gz" -O /tmp/souffle.tar.gz; \
      echo "5d009ad6c74ccec10207d865c059716afac625759bff7c8070e529bd80385067  /tmp/souffle.tar.gz" | sha256sum -c -; \
      tar xzf /tmp/souffle.tar.gz -C /tmp; \
      cmake -S "/tmp/souffle-${SOUFFLE_VERSION}" -B /tmp/souffle-build -DSOUFFLE_ENABLE_TESTING=OFF -DSOUFFLE_GIT=OFF -DPACKAGE_VERSION="${SOUFFLE_VERSION}"; \
      cmake --build /tmp/souffle-build -j"$(nproc)"; \
      sudo cmake --install /tmp/souffle-build; \
      rm -rf /tmp/souffle*; \
    fi; \
    sudo rm -rf /var/lib/apt/lists/*; \
    souffle --version

# argus_beam's escript, pinned. The worker calls it by absolute path, so PATH
# under an arbitrary --user uid does not matter. `argus version` fails the image
# build when souffle is missing or broken.
ARG ARGUS_VERSION=0.20.1
RUN mix escript.install hex argus_beam ${ARGUS_VERSION} --force && \
    /home/nerves/.mix/escripts/argus version

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
