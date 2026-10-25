defmodule Portal.BuilderTest do
  use ExUnit.Case, async: false

  alias Portal.Builder

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

  # Not passed for now: a plain `mix compile` runs make serially, so a parallel
  # make fails builds on Makefiles that are not -j safe -- failures no user
  # ever sees (circuits_spi 2.1.0 on rpi4). Restore once those are fixed.
  test "make runs serially, as it does for a user", %{previous: previous} do
    put_builder([cpus: "2"], previous)
    refute Enum.any?(args(), &String.starts_with?(&1, "MAKEFLAGS="))
  end

  test "a fractional cap still gets one whole scheduler", %{previous: previous} do
    put_builder([cpus: "1.5"], previous)

    assert "ERL_FLAGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
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
end
