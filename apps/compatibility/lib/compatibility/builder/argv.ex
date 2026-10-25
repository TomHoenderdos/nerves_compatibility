defmodule Compatibility.Builder.Argv do
  @moduledoc """
  The `docker run` argument list for one worker build container.

  A pure function of a plain map, so every host that starts a worker — the
  portal's own builders, and remote build VMs — runs the same sandbox: the same
  flags, mounts, environment and limits. Callers resolve their configuration,
  paths and user into the map; this module alone decides what the container
  gets. `test/fixtures/argv/post_hardening.exs` pins the result, and every
  caller's tests compare against that fixture.

  `:paths` are host paths. The build cache, when given, is always mounted
  read-only: a build runs untrusted package code, and the host-side promotion
  is the cache's only writer.
  """

  @type paths :: %{
          required(:work) => Path.t(),
          required(:out) => Path.t(),
          required(:files) => Path.t(),
          required(:tmp) => Path.t(),
          required(:cache) => Path.t(),
          required(:nerves_cache) => Path.t(),
          required(:hex_cache) => Path.t(),
          optional(:build_cache) => Path.t() | nil
        }

  @type spec :: %{
          required(:container_name) => String.t(),
          required(:user) => String.t(),
          required(:image) => String.t(),
          required(:paths) => paths(),
          optional(:cpus) => String.t() | number() | nil,
          optional(:memory) => String.t() | nil,
          optional(:build_concurrency) => String.t() | pos_integer() | nil
        }

  @doc "The argument list for `docker`, starting with `run` and ending with the image."
  @spec build(spec()) :: [String.t()]
  def build(spec) do
    paths = Map.fetch!(spec, :paths)

    flags(spec) ++
      limits(spec) ++
      mounts(paths) ++
      env() ++
      build_cache_env(paths) ++
      cpu_env(spec) ++ concurrency_env(spec) ++ [Map.fetch!(spec, :image)]
  end

  defp flags(spec) do
    [
      "run",
      "--rm",
      "--pull=never",
      "--name",
      Map.fetch!(spec, :container_name),
      "--user",
      Map.fetch!(spec, :user),
      "--cap-drop=ALL",
      "--security-opt=no-new-privileges",
      # The image is the root filesystem and nothing may change it: a package
      # that writes outside the mounts gets EROFS. /tmp and ~/.cache are the
      # two places the toolchain legitimately writes, and they are bound to
      # per-run scratch below.
      "--read-only",
      # A runaway `make -j` or a fork bomb dies here rather than exhausting the
      # host's pid table.
      "--pids-limit",
      "4096"
    ]
  end

  # Buildroot cross-compiles will use every core they are given. On a host that
  # shares the machine with other services, an unbounded build starves them, so
  # deployments can cap what a single build may take. Unset means unbounded,
  # which is the historical behaviour and stays the default.
  defp limits(spec) do
    [{:cpus, "--cpus"}, {:memory, "--memory"}]
    |> Enum.flat_map(fn {key, flag} ->
      case Map.get(spec, key) do
        nil -> []
        value -> [flag, to_string(value)]
      end
    end)
  end

  defp mounts(paths) do
    List.flatten([
      bind(Map.fetch!(paths, :work), "/work"),
      bind(Map.fetch!(paths, :out), "/out"),
      bind(Map.fetch!(paths, :files), "/files"),
      # Per-run, disk-backed, removed by cleanup/1 with the rest of the run.
      # Not tmpfs: that is RAM, and `mix firmware` (fwup, mksquashfs,
      # fakeroot) puts whole rootfs images in /tmp.
      bind(Map.fetch!(paths, :tmp), "/tmp"),
      bind(Map.fetch!(paths, :cache), "/home/nerves/.cache"),
      bind(Map.fetch!(paths, :nerves_cache), "/home/nerves/.nerves"),
      bind(Map.fetch!(paths, :hex_cache), "/hex-cache"),
      build_cache_mount(Map.get(paths, :build_cache))
    ])
  end

  defp bind(source, target), do: ["--mount", "type=bind,source=#{source},target=#{target}"]

  defp build_cache_mount(nil), do: []

  # Read-only: a build runs untrusted package code, and one that could
  # write here could plant beams under another dependency's key. What a
  # build compiles goes to /out/build-cache, and
  # `Portal.BuildCache.Promotion` moves what it accepts in from the host.
  defp build_cache_mount(dir),
    do: ["--mount", "type=bind,source=#{dir},target=/build-cache,readonly"]

  defp env do
    [
      "-e",
      "NCC_INPUT=/work/input.json",
      "-e",
      "LANG=C.UTF-8",
      "-e",
      "HOME=/home/nerves",
      "-e",
      "HEX_HOME=/hex-cache",
      # Nerves extracts prebuilt system tarballs with the external `tar`, and
      # GNU tar restores ownership by default when it believes it is root. On a
      # rootless daemon run_as_user is "0:0", so it does believe that, and every
      # chown then fails against --cap-drop=ALL: tar exits 2 and
      # Nerves.Artifact.Cache.put/2 raises. Dropping the chown is the fix, not
      # granting CAP_CHOWN back to a container that builds untrusted package
      # code. Under a rootful daemon we run as our own non-root uid, where this
      # is already tar's default, so it is a no-op there.
      "-e",
      "TAR_OPTIONS=--no-same-owner"
    ]
  end

  defp build_cache_env(paths) do
    case Map.get(paths, :build_cache) do
      nil -> []
      _dir -> ["-e", "NCC_BUILD_CACHE=/build-cache"]
    end
  end

  # `--cpus` is a CFS quota, not a core assignment: `nproc` inside the container
  # still reports every core the host has. Nothing in the build reads the quota,
  # so each container started a BEAM with one scheduler per *host* core, and BEAM
  # schedulers busy-wait by default. Five concurrent builds on six cores left the
  # host at 21% system time with a run queue of 20: a fifth of the machine spent
  # spinning and being throttled instead of compiling. Tell the runtimes how much
  # CPU they actually have.
  #
  # ERL_FLAGS covers the worker's own VM and any `erl` it starts; mix and elixir
  # read ELIXIR_ERL_OPTIONS instead, and that is where the compile parallelism
  # lives.
  #
  # MAKEFLAGS is deliberately not set. It never capped anything: elixir_make
  # passes no -j, so a NIF's C code builds serially by default, and
  # `MAKEFLAGS=-jN` *raised* that to N for a few seconds saved per NIF package.
  # The price was false failures on Makefiles that are not parallel-safe, which
  # no user hits because their `mix compile` runs make serially -- circuits_spi
  # 2.1.0 failed on rpi4 creating obj/ while compiling into it. Frank Hunleth is
  # fixing the elixir-circuits Makefiles; `MAKEFLAGS=-j#{quota}` can come back
  # once that has shipped, if the seconds are worth it.
  defp cpu_env(spec) do
    case cpu_quota(spec) do
      nil ->
        []

      quota ->
        beam_flags = "+S #{quota}:#{quota} +sbwt none +sbwtdcpu none +sbwtdio none"

        # sqfstar has the same blind spot and started a thread per host core
        # for every rootfs; the worker turns this into `-processors`.
        [
          "-e",
          "ERL_FLAGS=#{beam_flags}",
          "-e",
          "ELIXIR_ERL_OPTIONS=#{beam_flags}",
          "-e",
          "NCC_SQUASHFS_PROCESSORS=#{quota}"
        ]
    end
  end

  # Whole cores only, and never zero: a fractional cap still needs at least one
  # scheduler to make progress.
  defp cpu_quota(spec) do
    with value when not is_nil(value) <- Map.get(spec, :cpus),
         {cpus, _rest} <- Float.parse(to_string(value)) do
      max(1, trunc(cpus))
    else
      _ -> nil
    end
  end

  # How many targets the worker may build at once inside one container. Unset
  # means one, the serial behaviour this started with. Worth raising only
  # together with the CPU cap: the targets share whatever `--cpus` allows, and
  # the gain comes from overlapping the single-threaded stretches (release
  # assembly, squashfs, fwup), not from finding more cores.
  defp concurrency_env(spec) do
    case Map.get(spec, :build_concurrency) do
      nil -> []
      value -> ["-e", "NCC_BUILD_CONCURRENCY=#{value}"]
    end
  end
end
