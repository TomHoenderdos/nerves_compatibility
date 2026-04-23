FROM ghcr.io/nerves-project/nerves_system_br:1.33.0

# Install Elixir from GitHub releases
RUN wget https://repo.hex.pm/builds/elixir/v1.19.4-otp-28.zip && \
    unzip v1.19.4-otp-28.zip -d /home/nerves/.elixir && \
    rm v1.19.4-otp-28.zip

ENV PATH="/home/nerves/.elixir/bin:${PATH}"

# Install Hex, Rebar, Nerves Bootstrap, and Igniter archives
RUN mix local.hex --force && \
    mix local.rebar --force && \
    mix archive.install hex nerves_bootstrap --force && \
    mix archive.install hex igniter_new --force

# Create mount points
RUN sudo mkdir -p /work /out /hex-cache /home/nerves/.nerves

# Create app directory
WORKDIR /app

# Copy compat and worker code
COPY compat ./compat
COPY beam_scanner ./beam_scanner
COPY worker ./worker

# Ensure nerves user owns the directories
RUN sudo chown -R nerves:nerves /app/worker /work /out /hex-cache /home/nerves/.nerves

# Build worker
WORKDIR /app/worker
RUN mix clean --deps
RUN mix deps.get
RUN mix escript.build

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
ENTRYPOINT ["/app/worker/ncc_worker"]
