defmodule Compatibility.Builder.Argv do
  @moduledoc """
  The `docker run` argument list for one worker build container.

  A pure function of a plain map, so every host that starts a worker — the
  portal's own builders, and remote build VMs — runs the same sandbox: the same
  flags, mounts, environment and limits. Callers resolve their configuration,
  paths and user into the map; this module alone decides what the container
  gets. `test/fixtures/argv/post_isolation.exs` pins the result, and every
  caller's tests compare against that fixture.

  `:paths` are host paths. The build cache, when given, is always mounted
  read-only: a build runs untrusted package code, and the host-side promotion
  is the cache's only writer. The Nerves cache is mounted at `/nerves-cache`
  as `:nerves_cache_mode` says: `:readonly` for every build, `:warm` (read-write)
  for the warm run that is its only writer, and `:rw` (read-write, plus
  `NCC_NERVES_CACHE_RW=1` so the worker skips its symlink farm) for the
  one-release rollback. The Hex cache is mounted at `/hex-cache` as
  `:hex_cache_mode` says: `:readonly` (the default) for every build, whose
  worker seeds a per-run `HEX_HOME` from it (`NccWorker.HexCache`) and whose
  downloads only the host promotes (`Compatibility.HexCache`), `:rw`
  (read-write, plus `NCC_HEX_CACHE_RW=1` so the worker uses it as its
  `HEX_HOME` again) for the one-release rollback, and `:legacy` (read-write,
  no env) for an image without the `ncc.hex-cache=seeded` label, whose
  worker writes `/hex-cache` itself. `hex_cache_mode/2` picks one.

  Every container runs under gVisor (`runtime_flag/0`), with no other
  runtime to fall back to: a host without `runsc` fails every build.
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

  @type nerves_cache_mode :: :readonly | :warm | :rw
  @type hex_cache_mode :: :readonly | :rw | :legacy

  @hex_cache_label "ncc.hex-cache"

  @runtime_flag "--runtime=runsc"

  @type spec :: %{
          required(:container_name) => String.t(),
          required(:user) => String.t(),
          required(:image) => String.t(),
          required(:paths) => paths(),
          required(:nerves_cache_mode) => nerves_cache_mode(),
          optional(:hex_cache_mode) => hex_cache_mode(),
          optional(:cpus) => String.t() | number() | nil,
          optional(:memory) => String.t() | number() | nil,
          optional(:build_concurrency) => String.t() | pos_integer() | nil
        }

  @doc "The argument list for `docker`, starting with `run` and ending with the image."
  @spec build(spec()) :: [String.t()]
  def build(spec) do
    paths = Map.fetch!(spec, :paths)
    image = Map.fetch!(spec, :image)
    nerves_cache_mode = Map.fetch!(spec, :nerves_cache_mode)
    hex_cache_mode = Map.get(spec, :hex_cache_mode, :readonly)

    validate_paths!(paths)
    validate_image!(image)

    flags(spec) ++
      limits(spec) ++
      mounts(paths, nerves_cache_mode, hex_cache_mode) ++
      env() ++
      nerves_cache_env(nerves_cache_mode) ++
      hex_cache_env(hex_cache_mode) ++
      build_cache_env(paths) ++
      cpu_env(spec) ++ concurrency_env(spec) ++ [image]
  end

  # A comma in a mount source is a field separator in `--mount`'s own
  # `type=bind,source=...,target=...` syntax, so it would inject extra mount
  # options rather than naming a path.
  defp validate_paths!(paths) do
    Enum.each(paths, fn {_key, value} ->
      if is_binary(value) and String.contains?(value, ",") do
        raise ArgumentError,
              "path contains a comma, which `--mount` would read as a separator: #{inspect(value)}"
      end
    end)
  end

  # docker reads a leading `-` as the start of another flag rather than the
  # image argument.
  defp validate_image!(image) do
    if String.starts_with?(image, "-") do
      raise ArgumentError,
            "image starts with '-', which docker would read as a flag: #{inspect(image)}"
    end
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
      "4096",
      # Package code that escapes the container lands in the gVisor sentry,
      # not on the host kernel. Under the kvm platform the pids limit above
      # is not enforced; only `--memory` bounds a fork bomb there.
      @runtime_flag
    ]
  end

  @doc """
  The `docker run` flag every ncc container starts with: a build, a warm
  run, the egress probe and the build-cache promotion copy alike.
  """
  @spec runtime_flag() :: String.t()
  def runtime_flag, do: @runtime_flag

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

  defp mounts(paths, nerves_cache_mode, hex_cache_mode) do
    List.flatten([
      bind(Map.fetch!(paths, :work), "/work"),
      bind(Map.fetch!(paths, :out), "/out"),
      bind(Map.fetch!(paths, :files), "/files"),
      # Per-run, disk-backed, removed with the rest of the run by the caller.
      # Not tmpfs: that is RAM, and `mix firmware` (fwup, mksquashfs,
      # fakeroot) puts whole rootfs images in /tmp.
      bind(Map.fetch!(paths, :tmp), "/tmp"),
      bind(Map.fetch!(paths, :cache), "/home/nerves/.cache"),
      nerves_cache_mount(Map.fetch!(paths, :nerves_cache), nerves_cache_mode),
      hex_cache_mount(Map.fetch!(paths, :hex_cache), hex_cache_mode),
      build_cache_mount(Map.get(paths, :build_cache))
    ])
  end

  defp bind(source, target), do: ["--mount", "type=bind,source=#{source},target=#{target}"]

  # Read-only for a build: Nerves only checks an artifact's `.fingerprint`,
  # so a build that could write here could swap a toolchain binary or a
  # rootfs under every later firmware on the host. The worker resolves
  # through a per-run symlink farm instead (`NccWorker.NervesCache`); the
  # warm run is the cache's only writer.
  defp nerves_cache_mount(dir, :readonly),
    do: ["--mount", "type=bind,source=#{dir},target=/nerves-cache,readonly"]

  defp nerves_cache_mount(dir, mode) when mode in [:warm, :rw], do: bind(dir, "/nerves-cache")

  # Only the rollback tells the worker: it then points Nerves straight at
  # the mounted cache, as builds did before the farm.
  defp nerves_cache_env(:rw), do: ["-e", "NCC_NERVES_CACHE_RW=1"]
  defp nerves_cache_env(mode) when mode in [:readonly, :warm], do: []

  # Read-only for a build: one that could write here could leave a
  # `hex.config` naming its own mirror, or a registry cache with its own
  # checksums, for every later build on the host to trust. The worker
  # resolves through a per-run `HEX_HOME` seeded from it instead
  # (`NccWorker.HexCache`), and the host promotes what a build downloaded
  # only after checking it against Hex (`Compatibility.HexCache`).
  defp hex_cache_mount(dir, :readonly),
    do: ["--mount", "type=bind,source=#{dir},target=/hex-cache,readonly"]

  defp hex_cache_mount(dir, mode) when mode in [:rw, :legacy], do: bind(dir, "/hex-cache")

  # Only the rollback tells the worker. An unlabelled image predates the
  # variable and ignores it, so `:legacy` sends nothing.
  defp hex_cache_env(:rw), do: ["-e", "NCC_HEX_CACHE_RW=1"]
  defp hex_cache_env(mode) when mode in [:readonly, :legacy], do: []

  @doc """
  The image label that says the image's worker seeds a per-run `HEX_HOME`
  from a read-only `/hex-cache` (`NccWorker.HexCache`). Both worker
  Dockerfiles set it to `seeded`.
  """
  @spec hex_cache_label() :: String.t()
  def hex_cache_label, do: @hex_cache_label

  @doc """
  The Hex cache mode for an image whose `hex_cache_label/0` reads `label`
  (`nil` when absent or unknown), with the `NCC_HEX_CACHE_RW=1` rollback
  `rw?` taking precedence. Only a `seeded` image gets the read-only mount:
  an older one would write into it and fail its `deps.get`, which the run
  would publish as the package failing to build. A lease keeps the image it
  was created with, so a host can be asked to run one from before the label.
  """
  @spec hex_cache_mode(String.t() | nil, boolean()) :: hex_cache_mode()
  def hex_cache_mode(_label, true), do: :rw
  def hex_cache_mode("seeded", false), do: :readonly
  def hex_cache_mode(_label, false), do: :legacy

  defp build_cache_mount(nil), do: []

  # Read-only: a build runs untrusted package code, and one that could
  # write here could plant beams under another dependency's key. What a
  # build compiles goes to /out/build-cache, and the host-side promotion
  # is the cache's only writer, moving in what it accepts after the run exits.
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
      # GNU tar restores ownership by default when it believes it is root.
      # Rootless hosts pass `0:0` as :user, so it does believe that, and every
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
  # MAKEFLAGS raises make's parallelism to the quota. elixir_make passes no -j,
  # so without it a NIF's C code builds on one core however many the container
  # has; duckdbex 0.6.0 (435 C++ files at -O3) took 47 min per 32-bit ARM
  # target that way and timed out on a loaded host. It is a raise, not a cap:
  # a user's `mix compile` runs make serially, so a Makefile that is not
  # parallel-safe fails only here. That happened once (circuits_spi 2.1.0 on
  # rpi4, creating obj/ while compiling into it) and was removed on 2026-10-06;
  # the elixir-circuits Makefiles were fixed upstream (order-only directory
  # prerequisites, released 2026-10-08 to 10-13) and it came back on
  # 2026-10-26. A NIF failing with "No such file or directory" on an object
  # file on one target only is that class of bug, not an incompatibility.
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
          "NCC_SQUASHFS_PROCESSORS=#{quota}",
          "-e",
          "MAKEFLAGS=-j#{quota}"
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

  @doc """
  The container name for a run id: `ncc-` plus `safe_name/1` of it. Every
  host names its containers this way, so a run's container can be found,
  killed or listed by the same rule on any of them.
  """
  @spec container_name(String.t()) :: String.t()
  def container_name(run_id), do: "ncc-#{safe_name(run_id)}"

  @doc """
  The one transform from a run id to a directory or container name: anything
  outside `[A-Za-z0-9_.-]` becomes `_`, and the names that would escape a
  scratch root (`""`, `"."`, `".."`) raise. `Portal.Builder.safe_name/1` and
  the remote agent's scratch layout are this function.
  """
  @spec safe_name(String.t()) :: String.t()
  def safe_name(run_id) when run_id in ["", ".", ".."],
    do: raise(ArgumentError, "invalid directory name")

  def safe_name(run_id), do: String.replace(run_id, ~r/[^A-Za-z0-9_.\-]/, "_")
end
