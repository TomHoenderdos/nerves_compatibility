import Config

# runtime.exs does NOT support import_config, so portal's runtime config
# is inlined here, guarded so the worker Docker image (which copies only
# compatibility + ncc_worker) still builds without apps/portal on disk.
#
# The disk check alone is not enough. In a release this file is evaluated from
# the release's own config dir, where apps/portal does not exist, so the guard
# was false and every variable below was silently ignored: SECRET_KEY_BASE,
# DATABASE_URL, PHX_SERVER, all of it. A release booted on compile-time dev
# config instead. Checking whether the portal code is actually loadable covers
# the release case; the disk check still covers `mix` in the umbrella.
portal_available? =
  File.exists?(Path.expand("../apps/portal", __DIR__)) or
    match?({:module, _}, Code.ensure_loaded(PortalWeb.Endpoint))

if portal_available? do
  if System.get_env("PHX_SERVER") do
    config :portal, PortalWeb.Endpoint, server: true
  end

  config :portal, PortalWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4001"))]

  if images = System.get_env("NCC_IMAGES_JSON"),
    do: config(:portal, Portal.Builders.Images, path: images)

  repo_config = Application.get_env(:portal, Portal.Repo, [])

  repo_pool_size =
    case System.get_env("PORTAL_DATABASE_POOL_SIZE") do
      nil -> Keyword.get(repo_config, :pool_size, 10)
      value -> String.to_integer(value)
    end

  case System.get_env("DATABASE_URL") do
    nil ->
      :ok

    url ->
      maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

      # The build box talks to Postgres across a ~80ms private network link while five
      # buildroot compiles fight for its six cores. DBConnection's 15s default
      # kills a connection that is merely slow, which surfaces as
      # `tcp recv: closed` rather than as a timeout.
      repo_timeout =
        case System.get_env("PORTAL_DATABASE_TIMEOUT") do
          nil -> 60_000
          value -> String.to_integer(value)
        end

      # DBConnection decides the pool is unhealthy when a checkout waits longer
      # than queue_target, and then starts dropping queued requests outright. The
      # 50ms default assumes Postgres is on the same box; across the private network a
      # single round trip already costs more than that, so the pool looks
      # permanently sick and drops work that was only waiting its turn. That
      # surfaced as `connection not available and request was dropped from queue`
      # once the checkout-hold bug above stopped masking it.
      queue_target =
        case System.get_env("PORTAL_DATABASE_QUEUE_TARGET") do
          nil -> 500
          value -> String.to_integer(value)
        end

      queue_interval =
        case System.get_env("PORTAL_DATABASE_QUEUE_INTERVAL") do
          nil -> 5_000
          value -> String.to_integer(value)
        end

      config :portal, Portal.Repo,
        url: url,
        pool_size: repo_pool_size,
        timeout: repo_timeout,
        queue_target: queue_target,
        queue_interval: queue_interval,
        socket_options: maybe_ipv6
  end

  # Which Oban queues this node runs, e.g. "builds:1,node:2". Unset means the
  # full set, so a single-node deploy needs nothing here.
  #
  # This is how the work splits across hosts: the web box runs the light queues,
  # the build boxes run `builds` and `toolchain` (limit 1, so toolchain builds
  # never take a firmware slot), and Postgres is the only thing they share. A
  # build hands off to its ingest through the run's scratch directory on local
  # disk, not through the database, and each node's disks need their own sweep,
  # so each build node runs a queue of its own for both, `node_<node>`
  # (`Portal.NodeQueue`), as wide as `node` here (default 2). `node` is not a
  # queue itself, and neither is `ingest`, which no node runs any more: an
  # `ingest:N` left here from before is read as `node:N`, with a warning at
  # boot. `remote` belongs on the web box: it only writes `builder_leases` rows
  # for remote builders to claim.
  # `toolchain_big` goes only on the build boxes with memory to spare: it runs
  # the toolchain builds of the packages that need more than a `toolchain`
  # slot, each at NCC_TOOLCHAIN_BIG_MEMORY (`Portal.Toolchains.MemoryRouting`).
  # The unset default leaves it out: a single node has no bigger slot to give.
  parsed_queues =
    case System.get_env("OBAN_QUEUES") do
      nil ->
        [builds: 1, node: 2, intake: 5, maintenance: 1, toolchain: 1, remote: 2, reports: 1]

      queues ->
        queues
        |> String.split(",", trim: true)
        |> Enum.map(fn pair ->
          case String.split(pair, ":", parts: 2) do
            [name, limit] ->
              {String.to_atom(String.trim(name)), String.to_integer(String.trim(limit))}

            _ ->
              raise "OBAN_QUEUES entries must look like `name:limit`, got: #{inspect(pair)}"
          end
        end)
    end

  # `reports` runs wherever `maintenance` does (the web host), without an
  # OBAN_QUEUES change: both blue/green releases read one environment, and
  # only a release with `Portal.Workers.ReportRequeue` adds the queue. Both
  # branches above build a keyword list; anything else passes through.
  parsed_queues =
    if is_list(parsed_queues) and Keyword.keyword?(parsed_queues) and
         Keyword.has_key?(parsed_queues, :maintenance) and
         not Keyword.has_key?(parsed_queues, :reports),
       do: parsed_queues ++ [reports: 1],
       else: parsed_queues

  # `host_native_<arch>` (`Portal.Workers.HostNativeBuild`, board #85) runs
  # wherever `toolchain` does, for this node's own architecture only: a
  # host-native build is never emulated, so an x86_64 node never takes an
  # aarch64 job, and a node that is no glibc Linux (a Mac) runs none. It stays
  # idle while the `host_native_enabled` setting is off.
  parsed_queues =
    with true <- is_list(parsed_queues) and Keyword.keyword?(parsed_queues),
         true <- Keyword.get(parsed_queues, :toolchain, 0) > 0,
         {:ok, triple} <- Compatibility.HostTriple.current(),
         {:ok, machine} <- Compatibility.HostTriple.elf_machine(triple) do
      queue = String.to_atom("host_native_#{machine}")
      Keyword.put_new(parsed_queues, queue, 1)
    else
      _ -> parsed_queues
    end

  config :portal, Oban, queues: parsed_queues

  # Which toolchains to build on, as comma-separated `toolchain=image` pairs:
  # `1.20/29=ncc-worker:local,1.19/28=ncc-worker:elixir-1.19-otp-28`. A
  # toolchain is `<elixir major.minor>/<otp major>`; the image is a local tag
  # on the build host (`make build-toolchains`). Unset keeps the list in
  # config.exs. A malformed entry stops the boot (`Portal.Toolchains.parse/1`).
  if toolchains = System.get_env("NCC_TOOLCHAINS") do
    config :portal, Portal.Toolchains, images: Portal.Toolchains.parse(toolchains)
  end

  # Which named config variants the toolchain sweep builds: `all` (the
  # default), `none`, or comma-separated names. An unknown name stops the boot
  # (`Portal.Toolchains.parse_config_variants/1`).
  if value = System.get_env("NCC_CONFIG_VARIANTS") do
    config :portal, Portal.Toolchains,
      config_variants: Portal.Toolchains.parse_config_variants(value)
  end

  config :portal,
    orchestrator_scan_request_url: System.get_env("ORCHESTRATOR_SCAN_REQUEST_URL"),
    scan_request_shared_secret: System.get_env("SCAN_REQUEST_SHARED_SECRET"),
    github_client_id: System.get_env("GITHUB_CLIENT_ID")

  if store = System.get_env("NCC_ARTIFACT_STORE") do
    config :portal, :artifact_store, path: store
  end

  config :portal, :precompiled_signing, key_path: System.get_env("PRECOMPILED_SIGNING_KEY")

  # `0` publishes an untraced firmware build's `compile_env` as stored,
  # without Logger's compile-time purge keys (stream S11,
  # `Portal.Catalog`'s `put_logger_keys/3`). Anything else, or unset, keeps
  # them on.
  config :portal, firmware_logger_keys: System.get_env("NCC_FIRMWARE_LOGGER_KEYS") != "0"

  # How many packages a precompiled batch renders at once (default 4; see
  # Portal.Precompiled.Batches). Lanes share this node's pool and schedulers:
  # more of them open no connection to Postgres, but take more of its CPU.
  if lanes = System.get_env("NCC_PRECOMPILED_BATCH_LANES") do
    config :portal, Portal.Precompiled.Batches, lanes: lanes
  end

  # CDN/mirror origins signed into each batch as `content`; see
  # docs/PRECOMPILED_CDN.md. Parsed and validated by Portal.Precompiled.Content.
  config :portal, :precompiled_content_origins, System.get_env("NCC_PRECOMPILED_CONTENT_ORIGINS")

  if key = System.get_env("NCC_BUILDER_CA_KEY"),
    do: config(:portal, Portal.Builders.CA, key_path: key)

  if root = System.get_env("NCC_UPLOAD_ROOT"),
    do: config(:portal, Portal.Builders.Upload, root: root)

  # The remote builders' mTLS listener: served with PHX_SERVER once a CA key
  # is configured. `Portal.Builders.Listener` adds the certificates to
  # `https:` at boot, and leaves it off if the CA does not load. Never in
  # test, where Phoenix.ConnTest dispatches to it directly.
  builder_port = String.to_integer(System.get_env("NCC_BUILDER_PORT", "8443"))
  config :portal, PortalWeb.BuilderEndpoint, https: [port: builder_port]

  if config_env() != :test and System.get_env("PHX_SERVER") != nil and
       System.get_env("NCC_BUILDER_CA_KEY") != nil,
     do: config(:portal, PortalWeb.BuilderEndpoint, server: true)

  # Lets a separate deployment of this codebase send its bug reports to its own
  # tracker rather than to whichever repo the compile-time default names.
  if issues_url = System.get_env("NCC_ISSUES_URL") do
    config :portal, :issues_url, issues_url
  end

  # Every path here is handed to `docker run --mount source=`, so it is resolved
  # by the *host* daemon, not by this process. They must be host paths.
  #
  # NCC_BUILD_CPUS caps a single build's CPUs; unset means unbounded.
  # NCC_BUILD_MEMORY caps its memory and is required on a node that builds:
  # without it `Portal.Builder.check_memory_limit/0` refuses every build.
  # NCC_TOOLCHAIN_MEMORY and NCC_WARM_MEMORY each cap one container of that
  # kind (a toolchain run, a Nerves cache warm) and fall back to
  # NCC_BUILD_MEMORY when unset; set but not a limit, they refuse every build.
  # NCC_WARM_MEMORY also bounds the deploy-time warm (ops/builder-deploy.sh).
  # NCC_TOOLCHAIN_BIG_MEMORY caps a toolchain run on the `toolchain_big` queue
  # (`Portal.Toolchains.MemoryRouting`: the packages whose memory record shows
  # an OOM or a near-limit peak), with the same fallback and the same refusal.
  builder_env = [
    docker_image: System.get_env("NCC_DOCKER_IMAGE"),
    scratch_root: System.get_env("NCC_SCRATCH_ROOT"),
    nerves_cache: System.get_env("NCC_NERVES_CACHE"),
    # `1` mounts the Nerves cache read-write into builds and drops the worker's
    # symlink farm, as before the isolation work: the one-release rollback.
    # Anything else, or unset, keeps it read-only.
    nerves_cache_rw: if(System.get_env("NCC_NERVES_CACHE_RW") == "1", do: true),
    hex_cache: System.get_env("NCC_HEX_CACHE"),
    # `1` mounts the Hex cache read-write into builds and has the worker use it
    # as its HEX_HOME, as before the isolation work: the one-release rollback.
    # Anything else, or unset, keeps it read-only.
    hex_cache_rw: if(System.get_env("NCC_HEX_CACHE_RW") == "1", do: true),
    # `1` lets rule 2 accept a dependency whose native build file Mix never
    # runs (precompiled judge refinements, item 1): toolchain builds get
    # `NCC_INPUT.judge.makefile_rule2`. Anything else, or unset, keeps it off
    # until clients older than elixir_precompiled 0.3.1 are decided on.
    #
    # Fleet hazard: every node running the `:toolchain` queue must use the
    # same worker image and the same value of this flag. A node on a lower
    # judge revision (the flag off) than another node's toolchain rows
    # leaves `judge_revision` lower on the rows it builds, and the backlog's
    # judge-revision reopen (`Portal.Catalog`, `@judge_reopen`) requeues
    # those `skipped` rows against the fleet's newest revision every sweep,
    # rebuilding the same package weekly instead of once.
    judge_makefile_rule2: if(System.get_env("NCC_JUDGE_MAKEFILE_RULE2") == "1", do: true),
    # `1` sets a natively built dependency's native side apart from its
    # beams (elixir_make's own activity in its window no longer taints its
    # dependents) and reads rule 2's target and native-tool grep finer:
    # toolchain builds get `NCC_INPUT.judge.native_side`. It changes no judge
    # revision, so turning it on reopens nothing: a targeted requeue
    # rebuilds the rows it can change. Anything else, or unset, keeps it off.
    judge_native_side: if(System.get_env("NCC_JUDGE_NATIVE_SIDE") == "1", do: true),
    # `1` turns on differential builds (`NccWorker.Portability.Differential`):
    # toolchain builds get `NCC_INPUT.judge.differential`, and a scheduler
    # count, HOME or rebar.config.script plain-arguments read whose value
    # reaches no published file passes after two variant builds. It bumps no
    # judge revision, so a fleet with it on some nodes only reopens nothing:
    # a node without it skips such a row as before. Anything else, or unset,
    # keeps it off.
    judge_differential: if(System.get_env("NCC_JUDGE_DIFFERENTIAL") == "1", do: true),
    # `0` turns off the firmware targets' traced compile-input pass
    # (`NccWorker.FirmwareInputs`, judge revision 19): firmware builds get
    # `NCC_INPUT.firmware_inputs: false`, local and remote alike, with no
    # image change. Anything else, or unset, keeps it on.
    firmware_inputs: if(System.get_env("NCC_FIRMWARE_INPUTS") == "0", do: false),
    # `1` turns on the firmware judge (`NccWorker.FirmwareInputs`, stream
    # S8: every passing target traced for probes, rebar3 plugins and hooks)
    # for this node's firmware builds, local and remote leases alike
    # (`NCC_INPUT.firmware_judge: true`). Anything else, or unset, keeps it
    # off; the holds of earlier refusals stay either way.
    # NCC_FIRMWARE_JUDGE_BUDGET_SEC (seconds, an integer) is the judge's own
    # budget per run, sent as `NCC_INPUT.firmware_judge_budget_sec`; unset,
    # the worker's default (1800).
    firmware_judge: if(System.get_env("NCC_FIRMWARE_JUDGE") == "1", do: true),
    firmware_judge_budget_sec:
      case Integer.parse(System.get_env("NCC_FIRMWARE_JUDGE_BUDGET_SEC", "")) do
        {n, ""} when n >= 0 -> n
        _ -> nil
      end,
    build_cache: System.get_env("NCC_BUILD_CACHE"),
    cpus: System.get_env("NCC_BUILD_CPUS"),
    memory: System.get_env("NCC_BUILD_MEMORY"),
    toolchain_memory: System.get_env("NCC_TOOLCHAIN_MEMORY"),
    toolchain_big_memory: System.get_env("NCC_TOOLCHAIN_BIG_MEMORY"),
    warm_memory: System.get_env("NCC_WARM_MEMORY"),
    build_concurrency: System.get_env("NCC_BUILD_CONCURRENCY"),
    run_as_user: System.get_env("NCC_BUILD_USER"),
    # `Portal.Builder.min_free_bytes/0` parses this, so the string is fine.
    min_free_disk_gb: System.get_env("NCC_MIN_FREE_GB"),
    # The same for a toolchain build, `min_free_bytes/1`; never above the one above.
    min_free_disk_gb_toolchain: System.get_env("NCC_MIN_FREE_GB_TOOLCHAIN"),
    # `0` turns the egress preflight off (a host without docker-ncc and its
    # filter), `1` on. Anything else keeps the default, which
    # is on, so a typo can never switch the check off.
    egress_check:
      case System.get_env("NCC_EGRESS_CHECK") do
        "0" -> false
        "1" -> true
        _ -> nil
      end,
    # Hours are the human unit; `Portal.Workers.Sweep` wants milliseconds. An
    # unparseable value falls through as nil and leaves the compile-time default,
    # rather than silently becoming a retention of zero — which would have the
    # sweeper delete running builds' scratch dirs.
    scratch_max_age_ms:
      case System.get_env("NCC_SCRATCH_MAX_AGE_HOURS") do
        nil ->
          nil

        raw ->
          case Float.parse(raw) do
            {hours, _rest} when hours > 0 -> trunc(hours * 60 * 60 * 1000)
            _ -> nil
          end
      end,
    # GiB is the human unit; `Portal.Workers.Sweep` wants bytes. Unparseable
    # falls through as nil and keeps the compile-time default.
    hex_cache_max_bytes:
      case System.get_env("NCC_HEX_CACHE_MAX_GB") do
        nil ->
          nil

        raw ->
          case Float.parse(raw) do
            {gb, _rest} when gb > 0 -> trunc(gb * 1024 * 1024 * 1024)
            _ -> nil
          end
      end,
    # Same units and fallback for the Nerves cache's `artifacts/` bound.
    nerves_cache_max_bytes:
      case System.get_env("NCC_NERVES_CACHE_MAX_GB") do
        nil ->
          nil

        raw ->
          case Float.parse(raw) do
            {gb, _rest} when gb > 0 -> trunc(gb * 1024 * 1024 * 1024)
            _ -> nil
          end
      end
  ]

  case Enum.reject(builder_env, fn {_k, v} -> is_nil(v) end) do
    [] -> :ok
    overrides -> config :portal, Portal.Builder, overrides
  end

  # The shared S3 layer behind the build cache (`Portal.BuildCache.L2`).
  # Unset endpoint: off. Every other value is required once it is set.
  config :portal, Portal.BuildCache.L2,
    endpoint: System.get_env("NCC_BUILD_CACHE_S3_ENDPOINT"),
    bucket: System.get_env("NCC_BUILD_CACHE_S3_BUCKET"),
    region: System.get_env("NCC_BUILD_CACHE_S3_REGION"),
    access_key: System.get_env("NCC_BUILD_CACHE_S3_ACCESS_KEY"),
    secret_key: System.get_env("NCC_BUILD_CACHE_S3_SECRET_KEY"),
    read_only: System.get_env("NCC_BUILD_CACHE_S3_READ_ONLY") == "1",
    # The bucket's size mark in GB (10^9 bytes): above 90 % of it the oldest
    # objects are deleted down to 75 % (`Portal.BuildCache.L2.Evict`).
    max_gb: System.get_env("NCC_BUILD_CACHE_S3_MAX_GB")

  # Megabytes are the human unit; `Portal.Workers.LogRetention` wants bytes. An
  # unparseable or non-positive value leaves the compile-time default alone
  # rather than becoming a budget of zero, which would evict every stored log on
  # the next tick.
  case System.get_env("NCC_LOG_BUDGET_MB") do
    nil ->
      :ok

    raw ->
      case Float.parse(raw) do
        {mb, _rest} when mb > 0 ->
          config :portal, Portal.Workers.LogRetention, budget_bytes: trunc(mb * 1024 * 1024)

        _ ->
          :ok
      end
  end

  # Polling hex.pm for package updates — see `Portal.Workers.UpdateCheck`. On by
  # default; this is the kill switch, so that stopping the traffic to somebody
  # else's service never requires a deploy.
  #
  # A typo leaves the compile-time default alone rather than guessing. That cuts
  # the safer way in each direction: an unrecognised value cannot silently stop
  # a check we mean to be running, and cannot silently start one we have
  # deliberately switched off, because the deliberate `0` is still there to read.
  case System.get_env("NCC_UPDATE_CHECK") do
    v when v in ["1", "true", "yes"] ->
      config :portal, Portal.Workers.UpdateCheck, enabled: true

    v when v in ["0", "false", "no"] ->
      config :portal, Portal.Workers.UpdateCheck, enabled: false

    _ ->
      :ok
  end

  # The daily closure-drift rebuilds (`Portal.Workers.ClosureDrift`): the
  # same parsing, and the same reasoning about typos, as `NCC_UPDATE_CHECK`.
  # `NCC_CLOSURE_DRIFT_MAX` caps the rebuilds one run queues; anything but a
  # non-negative integer leaves the compile-time default alone.
  case System.get_env("NCC_CLOSURE_DRIFT") do
    v when v in ["1", "true", "yes"] ->
      config :portal, Portal.Workers.ClosureDrift, enabled: true

    v when v in ["0", "false", "no"] ->
      config :portal, Portal.Workers.ClosureDrift, enabled: false

    _ ->
      :ok
  end

  case Integer.parse(System.get_env("NCC_CLOSURE_DRIFT_MAX", "")) do
    {max, ""} when max >= 0 -> config :portal, Portal.Workers.ClosureDrift, max_per_run: max
    _ -> :ok
  end

  # The release fast path (`Portal.Workers.ReleaseFastPath`), parsed the
  # same way and read at boot: `NCC_RELEASE_FAST_PATH=0` offers no release
  # and cancels a queued one once the `:intake` nodes restart; the daily
  # drift run goes on. `NCC_CLOSURE_DRIFT=0` stops it too. `NCC_RELEASE_FAST_PATH_BUDGET`
  # caps its rebuilds incomplete at once; anything but a non-negative
  # integer leaves the compile-time default alone.
  case System.get_env("NCC_RELEASE_FAST_PATH") do
    v when v in ["1", "true", "yes"] ->
      config :portal, Portal.Workers.ReleaseFastPath, enabled: true

    v when v in ["0", "false", "no"] ->
      config :portal, Portal.Workers.ReleaseFastPath, enabled: false

    _ ->
      :ok
  end

  case Integer.parse(System.get_env("NCC_RELEASE_FAST_PATH_BUDGET", "")) do
    {budget, ""} when budget >= 0 ->
      config :portal, Portal.Workers.ReleaseFastPath, budget: budget

    _ ->
      :ok
  end

  # Its firmware phase, parsed the same way: `NCC_FIRMWARE_DRIFT=0` stops the
  # firmware rebuilds and leaves the toolchain ones running.
  case System.get_env("NCC_FIRMWARE_DRIFT") do
    v when v in ["1", "true", "yes"] ->
      config :portal, Portal.Workers.ClosureDrift, firmware: true

    v when v in ["0", "false", "no"] ->
      config :portal, Portal.Workers.ClosureDrift, firmware: false

    _ ->
      :ok
  end

  case Integer.parse(System.get_env("NCC_FIRMWARE_DRIFT_MAX", "")) do
    {max, ""} when max >= 0 ->
      config :portal, Portal.Workers.ClosureDrift, firmware_max_per_run: max

    _ ->
      :ok
  end

  # Same parsing, and the same reasoning about typos, as `NCC_UPDATE_CHECK`.
  case System.get_env("NCC_QUEUE_FILTER") do
    v when v in ["1", "true", "yes"] ->
      config :portal, :queue_filter, enabled: true

    v when v in ["0", "false", "no"] ->
      config :portal, :queue_filter, enabled: false

    _ ->
      :ok
  end

  if config_env() == :prod do
    secret_key_base =
      System.get_env("SECRET_KEY_BASE") ||
        raise """
        environment variable SECRET_KEY_BASE is missing.
        You can generate one by calling: mix phx.gen.secret
        """

    host = System.get_env("PHX_HOST") || "example.com"

    # relying party id registrable domain passkey bound to.
    # Changing it invalidates every registered passkey, so it tracks PHX_HOST
    # rather than a second thing to keep in sync.
    webauthn_rp_id = System.get_env("NCC_WEBAUTHN_RP_ID") || host

    config :portal, Portal.Accounts.WebAuthn,
      rp_id: webauthn_rp_id,
      origin: System.get_env("NCC_WEBAUTHN_ORIGIN") || "https://#{webauthn_rp_id}"

    config :portal, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

    # Self-hosted Umami: cookieless, no consent banner needed. The site id is
    # public anyway, it ships in every page, so a default here beats another
    # required environment variable. Set UMAMI_WEBSITE_ID="" to turn it off.
    umami_website_id =
      case System.get_env("UMAMI_WEBSITE_ID", "437028cd-8e45-471d-854c-87508b70f2e4") do
        "" -> nil
        id -> id
      end

    config :portal, :umami_website_id, umami_website_id

    # Defaults to every interface. Behind a reverse proxy on the same host,
    # set PHX_BIND_IP=127.0.0.1 so the port is not reachable from outside it.
    bind_ip =
      case System.get_env("PHX_BIND_IP") do
        nil ->
          {0, 0, 0, 0, 0, 0, 0, 0}

        value ->
          case value |> String.to_charlist() |> :inet.parse_address() do
            {:ok, address} -> address
            {:error, _} -> raise "PHX_BIND_IP is not a valid IP address: #{inspect(value)}"
          end
      end

    config :portal, PortalWeb.Endpoint,
      url: [host: host, port: 443, scheme: "https"],
      http: [
        ip: bind_ip
      ],
      secret_key_base: secret_key_base

    # Never signs anything; Phoenix wants one per endpoint.
    config :portal, PortalWeb.BuilderEndpoint,
      secret_key_base: secret_key_base,
      url: [host: host, port: builder_port, scheme: "https"]
  end
end
