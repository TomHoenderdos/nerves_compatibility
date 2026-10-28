# The docker argv a worker build runs with, pinned. Every host that starts a
# worker container must produce exactly this list from this input:
# `Compatibility.Builder.ArgvTest` checks `Argv.build/1`, `Portal.BuilderTest`
# checks the portal's builder from equivalent config, and a remote build agent
# checks its own. Post-isolation (isolation spec sections 4 and 1): read-only
# root, pids limit, per-run /tmp and ~/.cache, read-only build cache, the
# Nerves cache read-only at /nerves-cache, and the Hex cache read-only at
# /hex-cache (`HEX_HOME` still names it: the worker reads it as the cache to
# seed its per-run `HEX_HOME` from). Section 3 (egress) is not reflected
# here. Change it only together with the sandbox, and expect every builder's
# test to follow.
%{
  input: %{
    container_name: "ncc-11111111-2222-3333-4444-555555555555",
    user: "1000:1000",
    image: "ncc-worker:local",
    cpus: "2",
    memory: "4g",
    build_concurrency: "2",
    nerves_cache_mode: :readonly,
    paths: %{
      work: "/scratch/run/work",
      out: "/scratch/run/out",
      files: "/scratch/run/files",
      tmp: "/scratch/run/tmp",
      cache: "/scratch/run/cache",
      nerves_cache: "/srv/ncc/nerves-cache",
      hex_cache: "/srv/ncc/hex-cache",
      build_cache: "/srv/ncc/build-cache/sha256_deadbeef"
    }
  },
  argv: [
    "run",
    "--rm",
    "--pull=never",
    "--name",
    "ncc-11111111-2222-3333-4444-555555555555",
    "--user",
    "1000:1000",
    "--cap-drop=ALL",
    "--security-opt=no-new-privileges",
    "--read-only",
    "--pids-limit",
    "4096",
    "--cpus",
    "2",
    "--memory",
    "4g",
    "--mount",
    "type=bind,source=/scratch/run/work,target=/work",
    "--mount",
    "type=bind,source=/scratch/run/out,target=/out",
    "--mount",
    "type=bind,source=/scratch/run/files,target=/files",
    "--mount",
    "type=bind,source=/scratch/run/tmp,target=/tmp",
    "--mount",
    "type=bind,source=/scratch/run/cache,target=/home/nerves/.cache",
    "--mount",
    "type=bind,source=/srv/ncc/nerves-cache,target=/nerves-cache,readonly",
    "--mount",
    "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache,readonly",
    "--mount",
    "type=bind,source=/srv/ncc/build-cache/sha256_deadbeef,target=/build-cache,readonly",
    "-e",
    "NCC_INPUT=/work/input.json",
    "-e",
    "LANG=C.UTF-8",
    "-e",
    "HOME=/home/nerves",
    "-e",
    "HEX_HOME=/hex-cache",
    "-e",
    "TAR_OPTIONS=--no-same-owner",
    "-e",
    "NCC_BUILD_CACHE=/build-cache",
    "-e",
    "ERL_FLAGS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none",
    "-e",
    "ELIXIR_ERL_OPTIONS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none",
    "-e",
    "NCC_SQUASHFS_PROCESSORS=2",
    "-e",
    "MAKEFLAGS=-j2",
    "-e",
    "NCC_BUILD_CONCURRENCY=2",
    "ncc-worker:local"
  ]
}
