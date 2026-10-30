defmodule Portal.BuilderTest do
  use ExUnit.Case, async: false

  alias Portal.Builder
  import ExUnit.CaptureLog

  # `build_docker_args/4` takes the assembled job; `build/2` takes the caller's
  # args and assembles it itself.
  @build_args %{package: "jason", version: "1.4.1", run_id: "run-1", image_digest: "sha256:x"}

  @job %{
    run_id: "11111111-2222-3333-4444-555555555555",
    image_name: "ncc-worker",
    image_digest: "sha256:deadbeef"
  }

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    {:ok, previous: previous}
  end

  defp put_builder(overrides, previous) do
    Application.put_env(:portal, Portal.Builder, Keyword.merge(previous, overrides))
  end

  defp args,
    do: Builder.build_docker_args(@job, "/scratch/work", "/scratch/out", "/scratch/files")

  test "tells the runtimes how much CPU the container actually has", %{previous: previous} do
    put_builder([cpus: "2"], previous)

    # `--cpus` is a quota; `nproc` inside the container still reports the host's
    # cores, so without these the BEAM starts a scheduler per host core and
    # busy-waits through a quota it does not have.
    assert "ERL_FLAGS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "ELIXIR_ERL_OPTIONS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
  end

  # sqfstar sees every host core as well, and started one thread each.
  test "tells sqfstar how many processors it has", %{previous: previous} do
    put_builder([cpus: "2"], previous)
    assert "NCC_SQUASHFS_PROCESSORS=2" in args()

    put_builder([cpus: nil], previous)
    refute Enum.any?(args(), &String.starts_with?(&1, "NCC_SQUASHFS_PROCESSORS="))
  end

  # elixir_make passes no -j, so without this a NIF's C code builds on one
  # core whatever the quota (duckdbex: 47 min per 32-bit ARM target).
  test "make may use every core of the quota", %{previous: previous} do
    put_builder([cpus: "2"], previous)
    assert "MAKEFLAGS=-j2" in args()
  end

  test "a fractional cap still gets one whole scheduler", %{previous: previous} do
    put_builder([cpus: "1.5"], previous)

    assert "ERL_FLAGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "MAKEFLAGS=-j1" in args()
  end

  test "an uncapped build is left alone", %{previous: previous} do
    put_builder([cpus: nil], previous)

    refute Enum.any?(args(), &String.starts_with?(&1, "ERL_FLAGS="))
    refute Enum.any?(args(), &String.starts_with?(&1, "MAKEFLAGS="))
  end

  test "scratch and cache names cannot refer to a parent or root directory" do
    for input <- ["", ".", ".."] do
      assert_raise ArgumentError, fn -> Builder.safe_name(input) end
      assert_raise ArgumentError, fn -> Builder.cache_slug(input) end
    end

    assert Builder.safe_name("a/b") == "a_b"
  end

  describe "load_run/1 log reading" do
    # `read_log/1` is private; `load_run/1` is the reachable path through it,
    # and it is the path that runs on `ingest:3` for every finished build.
    defp seed_run do
      root = Path.join(System.tmp_dir!(), "builder-log-#{System.unique_integer([:positive])}")
      run_id = "pkg-1.0.0-#{System.unique_integer([:positive])}"
      out = Path.join([root, run_id, "out"])
      File.mkdir_p!(out)
      File.write!(Path.join(out, "result.json"), ~s({"package":{"name":"pkg"}}))
      on_exit(fn -> File.rm_rf(root) end)
      {root, run_id, out}
    end

    test "rejects a symlink result.json", %{previous: previous} do
      {root, run_id, out} = seed_run()
      put_builder([scratch_root: root], previous)
      result = Path.join(out, "result.json")
      target = Path.join(root, "other.json")
      File.rename!(result, target)
      File.ln_s!(target, result)
      assert {:error, :missing_result_json} = Builder.load_run(run_id)
    end

    test "reads a small runner.log whole", %{previous: previous} do
      {root, run_id, out} = seed_run()
      put_builder([scratch_root: root], previous)
      File.write!(Path.join(out, "runner.log"), "short log\n")

      assert {:ok, %{log: "short log\n"}} = Builder.load_run(run_id)
    end

    test "reads only the tail of a runner.log larger than the cap", %{previous: previous} do
      # A build stuck in a retry loop can emit gigabytes into this file, and
      # both consumers — a 16 KB sanitized excerpt and a column nothing reads —
      # throw away all but the end of it. Reading it whole allocated every byte
      # inside the ingest transaction.
      {root, run_id, out} = seed_run()
      put_builder([scratch_root: root], previous)

      head = String.duplicate("x", 2 * 1024 * 1024)
      File.write!(Path.join(out, "runner.log"), head <> "the end\n")

      assert {:ok, %{log: log}} = Builder.load_run(run_id)
      assert byte_size(log) == 1024 * 1024
      assert String.ends_with?(log, "the end\n")
    end

    test "a runner.log that is a symlink reads as empty", %{previous: previous} do
      # `/out` is a read-write bind mount the container writes as the invoking
      # host user, so package code can point `runner.log` at any file that user
      # can read.
      {root, run_id, out} = seed_run()
      put_builder([scratch_root: root], previous)

      secret = Path.join(root, "secret")
      File.write!(secret, "AWS_SECRET_ACCESS_KEY=hunter2")
      File.ln_s!(secret, Path.join(out, "runner.log"))

      assert {:ok, %{log: ""}} = Builder.load_run(run_id)
    end

    test "a missing runner.log reads as empty", %{previous: previous} do
      {root, run_id, _out} = seed_run()
      put_builder([scratch_root: root], previous)

      assert {:ok, %{log: ""}} = Builder.load_run(run_id)
    end
  end

  describe "free-space preflight" do
    test "refuses to start a build when the scratch filesystem is nearly full", %{
      previous: previous
    } do
      root = Path.join(System.tmp_dir!(), "builder-space-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      # Nothing has this much free, so the check must trip.
      put_builder([scratch_root: root, min_free_disk_gb: 10_000_000], previous)

      assert {:error, {:insufficient_disk, free, needed}} = Builder.build(@build_args)
      assert is_integer(free) and free >= 0
      assert needed == 10_000_000 * 1024 * 1024 * 1024

      # Non-vacuous: the refusal has to come before anything touches the disk or
      # starts a container, which is the entire point of a preflight.
      assert File.ls!(root) == []
    end

    # The counterpart to the test above, without paying for a real docker run:
    # the threshold is the only thing that differs, so if this also refused, the
    # test above would be proving nothing.
    test "a threshold under the real free space does not trip", %{previous: previous} do
      root = Path.join(System.tmp_dir!(), "builder-space-#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf(root) end)

      put_builder([scratch_root: root, min_free_disk_gb: 0], previous)

      assert Builder.free_bytes(root) >= Builder.min_free_bytes()
    end

    test "free_bytes/1 measures a filesystem that exists" do
      assert is_integer(Builder.free_bytes(System.tmp_dir!()))
      assert Builder.free_bytes(System.tmp_dir!()) > 0
    end

    test "free_bytes/1 climbs to an existing ancestor rather than failing" do
      missing = Path.join(System.tmp_dir!(), "no-such-dir-#{System.unique_integer([:positive])}")

      # `~/.ncc-scratch` does not exist until the first build creates it, and
      # `df` on a missing path exits non-zero.
      assert is_integer(Builder.free_bytes(missing))
    end

    test "min_free_bytes/0 accepts the string an env var supplies", %{previous: previous} do
      put_builder([min_free_disk_gb: "8"], previous)
      assert Builder.min_free_bytes() == 8 * 1024 * 1024 * 1024
    end
  end

  describe "cache_slug/1" do
    test "matches the sanitizing build_cache_dir/1 does", %{previous: previous} do
      cache = Path.join(System.tmp_dir!(), "builder-cache-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(cache) end)
      put_builder([build_cache: cache], previous)

      # `Portal.Workers.Sweep` prunes by `cache_slug/1`. If the writer and the
      # pruner ever disagree, the sweep deletes the live cache.
      _ = Builder.build_docker_args(@job, "/work", "/out", "/files")

      assert File.dir?(Path.join(cache, Builder.cache_slug(@job.image_digest)))
    end
  end

  describe "build cache mount" do
    setup %{previous: previous} do
      cache = Path.join(System.tmp_dir!(), "builder-cache-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(cache) end)
      put_builder([build_cache: cache], previous)
      %{cache: cache}
    end

    # The container must not write the shared cache: a build could plant
    # beams under another dependency's key. `Portal.BuildCache.Promotion`, on
    # the host, is the only writer.
    test "is read-only" do
      mount = Enum.find(args(), &String.contains?(&1, "target=/build-cache"))
      assert String.ends_with?(mount, "target=/build-cache,readonly")
    end

    test "build_cache_slug_dir/1 is the mounted directory, under the configured root", %{
      cache: cache
    } do
      dir = Builder.build_cache_slug_dir("sha256:deadbeef")
      assert dir == Path.join(cache, Builder.cache_slug("sha256:deadbeef"))
      assert "type=bind,source=#{dir},target=/build-cache,readonly" in args()
    end

    test "build_cache_slug_dir/1 is nil when the cache is off", %{previous: previous} do
      put_builder([build_cache: nil], previous)
      assert Builder.build_cache_slug_dir("sha256:deadbeef") == nil
    end
  end

  test "output_dir/1 is the run's out directory under the scratch root", %{previous: previous} do
    put_builder([scratch_root: "/scratch"], previous)
    assert Builder.output_dir("run-1") == "/scratch/run-1/out"
  end

  describe "worker_input/1" do
    @input_job %{
      run_id: "r1",
      image_name: "ncc-worker",
      image_digest: "sha256:x",
      package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
      systems_filter: nil
    }

    test "carries the argus config when given" do
      argus = %{"analyses" => ["default"], "scope" => "all", "timeout_seconds" => 60}
      assert Builder.worker_input(Map.put(@input_job, :argus, argus))["argus"] == argus
    end

    test "omits argus when off" do
      refute Map.has_key?(Builder.worker_input(Map.put(@input_job, :argus, nil)), "argus")
      refute Map.has_key?(Builder.worker_input(@input_job), "argus")
    end

    test "an argus-only build tells the worker so" do
      input =
        Builder.worker_input(Map.merge(@input_job, %{systems_filter: nil, mode: "argus_only"}))

      assert input["mode"] == "argus_only"
      refute Map.has_key?(input, "systems_filter")
    end

    test "a normal build sends no mode" do
      refute Map.has_key?(Builder.worker_input(Map.put(@input_job, :mode, nil)), "mode")
    end

    test "a toolchain build tells the worker its mode and toolchain" do
      input =
        Builder.worker_input(
          Map.merge(@input_job, %{mode: "toolchain", toolchain: %{elixir: "1.19", otp: "28"}})
        )

      assert input["mode"] == "toolchain"
      assert input["toolchain"] == %{elixir: "1.19", otp: "28"}

      assert Jason.decode!(Jason.encode!(input))["toolchain"] == %{
               "elixir" => "1.19",
               "otp" => "28"
             }
    end

    test "a normal build sends no toolchain" do
      refute Map.has_key?(Builder.worker_input(@input_job), "toolchain")
    end

    test "carries egress probe targets when given, and nothing otherwise" do
      targets = [%{"address" => "100.64.0.1", "port" => 5432}]

      assert Builder.worker_input(Map.put(@input_job, :egress_probe, targets))["egress_probe"] ==
               targets

      refute Map.has_key?(Builder.worker_input(@input_job), "egress_probe")
    end
  end

  # The container's root filesystem is the image: a build that writes outside
  # the mounts gets EROFS rather than a change that outlives the container.
  test "runs the container on a read-only root filesystem" do
    assert "--read-only" in args()
  end

  # A runaway `make -j` or fork bomb in a package build dies at the limit
  # instead of taking the host's pid table.
  test "caps the container's process count" do
    assert ["--pids-limit", "4096" | _] = Enum.drop_while(args(), &(&1 != "--pids-limit"))
  end

  # With a read-only root, /tmp and rebar3's ~/.cache need somewhere to go.
  # Per-run scratch directories rather than tmpfs: disk-backed on the
  # filesystem the free-space check already guards, no RAM budget, exec
  # allowed, removed with the run.
  test "binds /tmp and the home cache to per-run scratch directories" do
    mounts =
      args()
      |> Enum.chunk_every(2, 1)
      |> Enum.filter(&match?(["--mount", _], &1))
      |> Enum.map(&List.last/1)

    assert "type=bind,source=/scratch/tmp,target=/tmp" in mounts
    assert "type=bind,source=/scratch/cache,target=/home/nerves/.cache" in mounts
  end

  # The container's /tmp is the scratch filesystem, and fakeroot executes
  # helpers there, so a scratch root mounted noexec breaks every firmware
  # build in a way that reads as the package's fault. Probe it for real
  # (write a script, run it) rather than parsing mount options.
  describe "exec preflight" do
    test "probe_exec/1 passes on a filesystem that allows exec" do
      assert :ok = Builder.probe_exec(System.tmp_dir!())
    end

    test "a probe failure refuses the build before anything is written", %{previous: previous} do
      root = Path.join(System.tmp_dir!(), "noexec-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      put_builder(
        [scratch_root: root, min_free_disk_gb: 0, exec_probe: fn _path -> {:error, :eacces} end],
        previous
      )

      assert {:error, :scratch_noexec} = Builder.build(@build_args)
      refute File.exists?(Path.join(root, "run-1"))
    end
  end

  # The build egress filter lives in rootless dockerd's network namespace
  # (ops/builder-egress.nft). A host without it must refuse to build rather
  # than run package code with the private network in reach (isolation spec, section 3).
  describe "egress preflight" do
    @egress_listing """
    table inet ncc_egress {
      chain build_forward {
        type filter hook forward priority filter - 10; policy accept;
        iifname != "ncc0" accept
        drop comment "ncc_egress_v1"
      }
    }
    """

    # A stand-in for the builder's root status helper (homelab
    # modules/ncc-gvisor.nix): a unix socket that answers each connection
    # with `reply` and closes, or with nothing at all when `reply` is :hang.
    # Short path: a unix socket path is limited to ~100 bytes.
    defp egress_status_socket(reply) do
      path = "/tmp/ncc-egress-#{System.unique_integer([:positive])}.sock"
      File.rm(path)

      {:ok, listen} =
        :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, active: false, reuseaddr: true])

      server = spawn(fn -> serve_egress_status(listen, reply) end)
      :ok = :gen_tcp.controlling_process(listen, server)

      on_exit(fn ->
        Process.exit(server, :kill)
        File.rm(path)
      end)

      path
    end

    defp serve_egress_status(listen, reply) do
      with {:ok, conn} <- :gen_tcp.accept(listen) do
        answer_egress_status(conn, reply)
        :gen_tcp.close(conn)
        serve_egress_status(listen, reply)
      end
    end

    defp answer_egress_status(_conn, :hang), do: Process.sleep(5_000)
    defp answer_egress_status(conn, reply), do: :ok = :gen_tcp.send(conn, reply)

    test "a missing filter refuses the build before anything is written", %{previous: previous} do
      root = Path.join(System.tmp_dir!(), "egress-root-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      put_builder(
        [
          scratch_root: root,
          min_free_disk_gb: 0,
          exec_probe: fn _path -> :ok end,
          egress_check: true,
          egress_filter_probe: fn -> {:error, {:missing_executable, "nft"}} end
        ],
        previous
      )

      log =
        capture_log(fn ->
          assert {:error, :egress_filter_missing} = Builder.build(@build_args)
        end)

      assert log =~ "Build egress filter missing"
      assert log =~ ~s({:missing_executable, "nft"})
      refute File.exists?(Path.join(root, "run-1"))
    end

    test "check_egress/0 passes when the probe finds the table", %{previous: previous} do
      put_builder([egress_check: true, egress_filter_probe: fn -> :ok end], previous)
      assert :ok = Builder.check_egress()
    end

    test "NCC_EGRESS_CHECK=0 skips the probe", %{previous: previous} do
      test = self()

      put_builder(
        [
          egress_check: false,
          egress_filter_probe: fn ->
            send(test, :probed)
            {:error, :should_not_run}
          end
        ],
        previous
      )

      refute Builder.egress_check?()
      assert :ok = Builder.check_egress()
      refute_received :probed
    end

    test "the check is on unless configured off", %{previous: previous} do
      put_builder([], Keyword.delete(previous, :egress_check))
      assert Builder.egress_check?()
    end

    test "egress_table_complete?/1 wants the forward hook and the versioned final drop" do
      assert Builder.egress_table_complete?(@egress_listing)

      # A table someone emptied with `flush table`.
      refute Builder.egress_table_complete?("table inet ncc_egress {\n}\n")

      # An older ruleset whose marker is not the one this release expects.
      refute Builder.egress_table_complete?(
               String.replace(@egress_listing, "ncc_egress_v1", "ncc_egress_v0")
             )

      # Some other table that happens to have a forward hook.
      refute Builder.egress_table_complete?(
               String.replace(@egress_listing, "inet ncc_egress", "inet other")
             )

      # The right table and marker, but hooked somewhere other than forward.
      refute Builder.egress_table_complete?(
               String.replace(@egress_listing, "hook forward", "hook input")
             )
    end

    test "probe_egress/1 reads the table from the status socket" do
      assert :ok = Builder.probe_egress(socket: egress_status_socket(@egress_listing))
    end

    test "probe_egress/1 reports what nft said when the table is absent" do
      socket = egress_status_socket("Error: No such file or directory\n")

      assert {:error, {:nft_failed, "Error: No such file or directory"}} =
               Builder.probe_egress(socket: socket)
    end

    test "probe_egress/1 refuses a table without the marker" do
      socket = egress_status_socket("table inet ncc_egress {\n}\n")
      assert {:error, :egress_table_incomplete} = Builder.probe_egress(socket: socket)
    end

    test "probe_egress/1 fails closed without the status socket" do
      missing = "/tmp/ncc-egress-absent-#{System.unique_integer([:positive])}.sock"

      assert {:error, {:status_socket, ^missing, _reason}} =
               Builder.probe_egress(socket: missing)
    end

    test "probe_egress/1 fails closed when the helper hangs past its bound" do
      socket = egress_status_socket(:hang)
      started = System.monotonic_time(:millisecond)

      assert {:error, :timeout} = Builder.probe_egress(socket: socket, timeout_ms: 100)

      # Bounded by timeout_ms, not by the helper's 5s sleep.
      assert System.monotonic_time(:millisecond) - started < 1000
    end

    # The real probe, end to end: no table in the host namespace, no build.
    test "a host whose table is absent refuses the build", %{previous: previous} do
      root = Path.join(System.tmp_dir!(), "egress-root-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)
      socket = egress_status_socket("Error: No such file or directory\n")

      put_builder(
        [
          scratch_root: root,
          min_free_disk_gb: 0,
          exec_probe: fn _path -> :ok end,
          egress_check: true,
          egress_filter_probe: nil,
          egress_status_socket: socket
        ],
        previous
      )

      log =
        capture_log(fn ->
          assert {:error, :egress_filter_missing} = Builder.build(@build_args)
        end)

      assert log =~ "No such file or directory"
      refute File.exists?(Path.join(root, "run-1"))
    end

    test "check_egress/0 fails closed and logs a probe timeout like any other probe failure",
         %{previous: previous} do
      put_builder(
        [egress_check: true, egress_filter_probe: fn -> {:error, :timeout} end],
        previous
      )

      log =
        capture_log(fn ->
          assert {:error, :egress_filter_missing} = Builder.check_egress()
        end)

      assert log =~ "Build egress filter missing"
      assert log =~ ":timeout"
    end

    test "boot_egress_check/0 warns when the check is off", %{previous: previous} do
      put_builder([egress_check: false], previous)
      log = capture_log(fn -> assert :disabled = Builder.boot_egress_check() end)
      assert log =~ "not egress-filtered"
    end

    # A probe that answers `answers` in turn, then the last one forever.
    defp probe_answering(answers) do
      {:ok, calls} = Agent.start_link(fn -> answers end)
      on_exit(fn -> if Process.alive?(calls), do: Agent.stop(calls) end)

      test = self()

      fn ->
        send(test, :probed)

        Agent.get_and_update(calls, fn
          [answer] -> {answer, [answer]}
          [answer | rest] -> {answer, rest}
        end)
      end
    end

    test "boot_egress_check/1 reports a filter still missing after its retries",
         %{previous: previous} do
      test = self()

      probe = fn ->
        send(test, :probed)
        {:error, :nope}
      end

      put_builder([egress_check: true, egress_filter_probe: probe], previous)

      log =
        capture_log(fn ->
          assert {:error, :egress_filter_missing} =
                   Builder.boot_egress_check(attempts: 3, interval_ms: 0)
        end)

      assert log =~ "Build egress filter missing"
      # Once, after the last attempt, not on every retry.
      assert length(String.split(log, "Build egress filter missing")) == 2

      for _ <- 1..3, do: assert_received(:probed)
      refute_received :probed
    end

    # At boot the portal usually comes up before the rootless daemon and its
    # ExecStartPost loader do.
    test "boot_egress_check/1 waits for a daemon that loads the filter after boot",
         %{previous: previous} do
      probe = probe_answering([{:error, :no_child_pid}, {:error, :no_child_pid}, :ok])
      put_builder([egress_check: true, egress_filter_probe: probe], previous)

      log =
        capture_log(fn ->
          assert :ok = Builder.boot_egress_check(attempts: 5, interval_ms: 10)
        end)

      # Stops at the first :ok.
      for _ <- 1..3, do: assert_received(:probed)
      refute_received :probed
      # The "is loaded" line is info, below the test log level.
      refute log =~ "Build egress filter missing"
    end

    test "boot_egress_check/1 retries for a minute by default", %{previous: previous} do
      put_builder([egress_check: true], previous)
      assert Builder.boot_egress_retry() == {13, 5_000}
    end
  end

  # The argv is `Compatibility.Builder.Argv`'s, and remote builders run the
  # same function; this pins that the portal's config resolves to the shared
  # fixture, so the two cannot drift apart unnoticed.
  describe "argv parity" do
    @argv_fixture Path.expand(
                    "../../../compatibility/test/fixtures/argv/post_isolation.exs",
                    __DIR__
                  )

    test "the portal builds exactly the argv the shared fixture pins", %{previous: previous} do
      {%{input: input, argv: argv}, _binding} = Code.eval_file(@argv_fixture)
      cache = Path.join(System.tmp_dir!(), "builder-parity-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(cache) end)

      put_builder(
        [
          run_as_user: input.user,
          cpus: input.cpus,
          memory: input.memory,
          build_concurrency: input.build_concurrency,
          nerves_cache: input.paths.nerves_cache,
          nerves_cache_rw: false,
          hex_cache: input.paths.hex_cache,
          build_cache: cache
        ],
        previous
      )

      job = %{
        run_id: "11111111-2222-3333-4444-555555555555",
        image_name: input.image,
        image_digest: "sha256:deadbeef"
      }

      # The build cache slug dir is created on the host, so it has to be a real
      # temp path here; everything else is the fixture's own.
      slug_dir = Path.join(cache, Builder.cache_slug(job.image_digest))
      expected = Enum.map(argv, &String.replace(&1, input.paths.build_cache, slug_dir))

      assert Builder.build_docker_args(job, input.paths.work, input.paths.out, input.paths.files) ==
               expected
    end
  end

  describe "Nerves cache mount" do
    defp mounts(argv) do
      argv
      |> Enum.chunk_every(2, 1)
      |> Enum.filter(&match?(["--mount", _], &1))
      |> Enum.map(&List.last/1)
    end

    test "a build mounts it read-only at /nerves-cache", %{previous: previous} do
      put_builder([nerves_cache: "/srv/nerves", nerves_cache_rw: nil], previous)

      assert "type=bind,source=/srv/nerves,target=/nerves-cache,readonly" in mounts(args())
      refute "NCC_NERVES_CACHE_RW=1" in args()
      refute Enum.any?(args(), &String.contains?(&1, "/home/nerves/.nerves"))
    end

    test "a warm job mounts it read-write", %{previous: previous} do
      put_builder([nerves_cache: "/srv/nerves", nerves_cache_rw: nil], previous)
      job = Map.put(@job, :mode, "warm_nerves")

      argv = Builder.build_docker_args(job, "/scratch/work", "/scratch/out", "/scratch/files")

      assert "type=bind,source=/srv/nerves,target=/nerves-cache" in mounts(argv)
      refute "NCC_NERVES_CACHE_RW=1" in argv
    end

    test "NCC_NERVES_CACHE_RW=1 mounts it read-write and drops the farm", %{previous: previous} do
      put_builder([nerves_cache: "/srv/nerves", nerves_cache_rw: true], previous)

      assert "type=bind,source=/srv/nerves,target=/nerves-cache" in mounts(args())
      assert "NCC_NERVES_CACHE_RW=1" in args()
    end

    # Under the rollback builds write the cache again, so whatever a later
    # read-only deploy finds there must be wiped first, not trusted; the
    # marker goes before any such container can start, not only at deploy.
    test "an rw build removes the trust marker before it starts", %{previous: previous} do
      tmp = Path.join(System.tmp_dir!(), "rw-marker-#{System.unique_integer([:positive])}")
      cache = Path.join(tmp, "nerves-cache")
      marker = Portal.NervesCache.trusted_marker(cache)
      File.mkdir_p!(cache)
      on_exit(fn -> File.rm_rf(tmp) end)

      put_builder(
        [
          scratch_root: Path.join(tmp, "scratch"),
          nerves_cache: cache,
          min_free_disk_gb: 0,
          exec_probe: fn _path -> {:error, :eacces} end,
          nerves_cache_rw: nil
        ],
        previous
      )

      File.write!(marker, "trusted")
      assert {:error, :scratch_noexec} = Builder.build(@build_args)
      assert File.regular?(marker)

      assert {:error, :scratch_noexec} =
               Builder.build(Map.merge(@build_args, %{mode: "warm_nerves", nerves_packages: []}))

      assert File.regular?(marker)

      put_builder([nerves_cache_rw: true], Application.get_env(:portal, Portal.Builder))
      assert {:error, :scratch_noexec} = Builder.build(@build_args)
      refute File.exists?(marker)

      # Nothing to remove is fine.
      assert {:error, :scratch_noexec} = Builder.build(@build_args)
    end

    test "nerves_cache_mode/1 picks warm first, then the fallback", %{previous: previous} do
      put_builder([nerves_cache_rw: nil], previous)
      assert Builder.nerves_cache_mode(@job) == :readonly
      assert Builder.nerves_cache_mode(Map.put(@job, :mode, "warm_nerves")) == :warm
      assert Builder.nerves_cache_mode(Map.put(@job, :mode, "argus_only")) == :readonly

      put_builder([nerves_cache_rw: true], previous)
      assert Builder.nerves_cache_mode(@job) == :rw
      assert Builder.nerves_cache_mode(Map.put(@job, :mode, "warm_nerves")) == :warm
    end
  end

  describe "Hex cache mount" do
    defp hex_mounts(argv) do
      argv
      |> Enum.chunk_every(2, 1)
      |> Enum.filter(&match?(["--mount", _], &1))
      |> Enum.map(&List.last/1)
    end

    test "every build, a warm one included, mounts it read-only", %{previous: previous} do
      put_builder([hex_cache: "/srv/hex", hex_cache_rw: nil], previous)

      assert "type=bind,source=/srv/hex,target=/hex-cache,readonly" in hex_mounts(args())
      refute "NCC_HEX_CACHE_RW=1" in args()

      warm =
        Builder.build_docker_args(
          Map.put(@job, :mode, "warm_nerves"),
          "/scratch/work",
          "/scratch/out",
          "/scratch/files"
        )

      assert "type=bind,source=/srv/hex,target=/hex-cache,readonly" in hex_mounts(warm)
    end

    test "NCC_HEX_CACHE_RW=1 mounts it read-write and tells the worker", %{previous: previous} do
      put_builder([hex_cache: "/srv/hex", hex_cache_rw: true], previous)

      assert "type=bind,source=/srv/hex,target=/hex-cache" in hex_mounts(args())
      assert "NCC_HEX_CACHE_RW=1" in args()
      assert Builder.hex_cache_mode(@job) == {:ok, :rw}

      put_builder([hex_cache_rw: nil], previous)
      assert Builder.hex_cache_mode(@job) == {:ok, :readonly}
    end

    # A lease or a queued job can name an image from before the seeded
    # HEX_HOME: its worker writes /hex-cache/packages itself, so it keeps
    # the read-write mount, and the rollback env would mean nothing to it.
    test "an image without the seeded label keeps the read-write mount", %{previous: previous} do
      parent = self()

      put_builder(
        [
          hex_cache: "/srv/hex",
          hex_cache_rw: nil,
          hex_cache_image_label: fn ref ->
            send(parent, {:inspected, ref})
            {:ok, nil}
          end
        ],
        previous
      )

      assert Builder.hex_cache_mode(@job) == {:ok, :legacy}
      assert_received {:inspected, "ncc-worker"}

      assert "type=bind,source=/srv/hex,target=/hex-cache" in hex_mounts(args())
      refute "NCC_HEX_CACHE_RW=1" in args()
    end

    test "the label of the exact image run is read, once per digest-pinned image", %{
      previous: previous
    } do
      parent = self()
      digest = "sha256:" <> String.duplicate("c", 64)

      put_builder(
        [
          hex_cache_rw: nil,
          hex_cache_image_label: fn ref ->
            send(parent, {:inspected, ref})
            {:ok, "seeded"}
          end
        ],
        previous
      )

      job = %{@job | image_name: "registry.example/ncc-worker", image_digest: digest}

      assert Builder.hex_cache_mode(job) == {:ok, :readonly}
      assert Builder.hex_cache_mode(job) == {:ok, :readonly}
      assert_received {:inspected, "registry.example/ncc-worker@" <> ^digest}
      refute_received {:inspected, _}

      # A tag can move, so a local name is asked about every time.
      Builder.hex_cache_mode(@job)
      Builder.hex_cache_mode(@job)
      assert_received {:inspected, "ncc-worker"}
      assert_received {:inspected, "ncc-worker"}
    end

    test "the rollback does not ask docker at all", %{previous: previous} do
      put_builder(
        [hex_cache_rw: true, hex_cache_image_label: fn _ -> flunk("inspected") end],
        previous
      )

      assert Builder.hex_cache_mode(@job) == {:ok, :rw}
    end

    # An inspect that fails says nothing about the image: it must neither
    # downgrade the build to the read-write mount nor be remembered.
    test "a failed inspect is an error, never the legacy mount, and is not kept", %{
      previous: previous
    } do
      parent = self()
      digest = "sha256:" <> String.duplicate("d", 64)
      job = %{@job | image_name: "registry.example/ncc-worker", image_digest: digest}

      put_builder(
        [
          hex_cache_rw: nil,
          hex_cache_image_label: fn ref ->
            send(parent, {:inspected, ref})
            :error
          end
        ],
        previous
      )

      assert {:error, {:hex_cache_label, _ref}} = Builder.hex_cache_mode(job)
      assert_raise ArgumentError, fn -> Builder.build_docker_args(job, "/w", "/o", "/f") end

      put_builder(
        [
          hex_cache_rw: nil,
          hex_cache_image_label: fn ref ->
            send(parent, {:inspected, ref})
            {:ok, "seeded"}
          end
        ],
        previous
      )

      assert Builder.hex_cache_mode(job) == {:ok, :readonly}
      assert_received {:inspected, _}
      assert_received {:inspected, _}
    end
  end

  describe "warm runs" do
    test "worker_input/1 sends the mode and pairs and no package" do
      pairs = [%{"name" => "nerves_system_rpi4", "version" => "2.0.0"}]

      input =
        Builder.worker_input(%{
          run_id: "warm_nerves-1",
          image_name: "ncc-worker",
          image_digest: "sha256:x",
          package: nil,
          systems_filter: nil,
          mode: "warm_nerves",
          nerves_packages: pairs
        })

      assert input["mode"] == "warm_nerves"
      assert input["nerves_packages"] == pairs
      refute Map.has_key?(input, "package")
    end

    test "worker_input/1 sends no nerves_packages for a build" do
      job = %{
        run_id: "r1",
        image_name: "ncc-worker",
        image_digest: "sha256:x",
        package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
        systems_filter: nil
      }

      refute Map.has_key?(Builder.worker_input(job), "nerves_packages")
      assert Builder.worker_input(job)["package"]["name"] == "jason"
    end

    # Reaching the exec preflight proves the job was assembled without a
    # package: a build without one raises KeyError before that.
    test "build/2 needs no package or version for a warm run", %{previous: previous} do
      root = Path.join(System.tmp_dir!(), "warm-args-#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf(root) end)

      put_builder(
        [scratch_root: root, min_free_disk_gb: 0, exec_probe: fn _path -> {:error, :eacces} end],
        previous
      )

      assert {:error, :scratch_noexec} =
               Builder.build(%{
                 run_id: "warm_nerves-1",
                 mode: "warm_nerves",
                 nerves_packages: [],
                 image_digest: "sha256:x"
               })
    end
  end

  # L2 shares only content-addressed slugs, so these builds name a full digest.
  @l2_args Map.put(@build_args, :image_digest, "sha256:" <> String.duplicate("d", 64))

  # Before the container runs, the build pulls what the shared L2 cache holds
  # for this image into the local slug dir. A fake `docker` on PATH answers
  # the version check and the run, so this exercises `build/2` end to end
  # without a daemon.
  describe "L2 prefetch" do
    @describetag :capture_log

    alias Portal.BuildCache.L2
    alias Portal.BuildCache.L2.{Stats, Tarball}
    alias Portal.Test.FakeS3

    setup %{previous: previous} do
      tmp = Path.join(System.tmp_dir!(), "builder-l2-#{System.unique_integer([:positive])}")
      bin = Path.join(tmp, "bin")
      cache = Path.join(tmp, "build-cache")
      File.mkdir_p!(bin)

      docker = Path.join(bin, "docker")

      File.write!(docker, """
      #!/bin/sh
      case "$1" in
        version) echo 99.0 ;;
        *) echo "fake docker $1" ;;
      esac
      exit 0
      """)

      File.chmod!(docker, 0o755)

      old_path = System.get_env("PATH")
      old_l2 = Application.get_env(:portal, L2)
      System.put_env("PATH", bin <> ":" <> old_path)

      on_exit(fn ->
        System.put_env("PATH", old_path)

        if old_l2,
          do: Application.put_env(:portal, L2, old_l2),
          else: Application.delete_env(:portal, L2)

        File.rm_rf(tmp)
      end)

      put_builder(
        [
          build_cache: cache,
          scratch_root: Path.join(tmp, "scratch"),
          nerves_cache: Path.join(tmp, "nerves"),
          hex_cache: Path.join(tmp, "hex"),
          min_free_disk_gb: 0,
          exec_probe: fn _ -> :ok end,
          egress_check: false
        ],
        previous
      )

      Stats.reset()
      {:ok, s} = FakeS3.start()
      key = String.duplicate("c", 64)
      src = Path.join(tmp, "src")
      File.mkdir_p!(Path.join(src, "ebin"))
      File.write!(Path.join(src, "ebin/Elixir.Jason.beam"), "beam")
      tar = Path.join(tmp, "entry.tar.gz")
      {:ok, %{sha256: sha}} = Tarball.pack(src, tar, :any)
      object = Builder.cache_slug(@l2_args.image_digest) <> "/" <> key <> ".tar.gz"
      FakeS3.put_object(s, object, File.read!(tar), %{"x-amz-meta-sha256" => sha})

      %{s: s, cache: cache, key: key}
    end

    defp put_l2(s) do
      Application.put_env(:portal, L2,
        endpoint: s.endpoint,
        bucket: s.bucket,
        region: s.region,
        access_key: s.access_key,
        secret_key: s.secret_key
      )
    end

    test "restores the image's entries into the local cache before the run", %{
      s: s,
      cache: cache,
      key: key
    } do
      put_l2(s)

      assert {:ok, %{exit_code: 0, log: log}} = Builder.build(@l2_args)

      slug_dir = Path.join(cache, Builder.cache_slug(@l2_args.image_digest))
      assert File.read!(Path.join([slug_dir, key, "ebin/Elixir.Jason.beam"])) == "beam"
      assert log =~ "Build cache L2 prefetch for run-1: 1 downloaded"
      # The docker header still opens the log, so `LogSanitizer` strips it.
      assert log =~ ~r/\A=+\nPortal.Builder - Docker Execution Log/
      refute Portal.Catalog.LogSanitizer.runner_excerpt(log) =~ "Command: docker"
    end

    test "with too little free space under the cache it skips the prefetch", %{s: s} do
      put_l2(s)
      current = Application.get_env(:portal, Portal.Builder)
      put_builder([prefetch_min_free_bytes: 1_000_000_000_000_000_000], current)

      assert {:ok, %{exit_code: 0, log: log}} = Builder.build(@l2_args)
      assert log =~ "Build cache L2 prefetch for run-1 skipped: low disk space"
      assert FakeS3.requests(s) == []
    end

    test "with L2 off the build neither prefetches nor contacts the store", %{s: s} do
      Application.delete_env(:portal, L2)

      assert {:ok, %{exit_code: 0, log: log}} = Builder.build(@l2_args)
      refute log =~ "Build cache L2 prefetch"
      assert FakeS3.requests(s) == []
    end
  end
end
