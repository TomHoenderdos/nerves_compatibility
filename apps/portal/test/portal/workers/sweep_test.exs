defmodule Portal.Workers.SweepTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  require Logger

  alias Portal.Workers.Sweep

  @hour :timer.hours(1)

  # Fixed clock. Real timestamps are `System.system_time(:millisecond)`, and the
  # sweeper only ever compares differences, so any consistent epoch works.
  @now 1_800_000_000_000

  setup do
    root = Path.join(System.tmp_dir!(), "sweep-scratch-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp scratch(root, name) do
    dir = Path.join(root, name)
    File.mkdir_p!(Path.join(dir, "work"))
    dir
  end

  # Everything the sweeper would otherwise reach out to docker or the config for.
  defp opts(root, extra \\ []) do
    Keyword.merge(
      [
        now_ms: @now,
        scratch_root: root,
        max_age_ms: :timer.hours(3),
        live_run_ids: MapSet.new(),
        running_containers: MapSet.new(),
        build_cache: nil,
        hex_cache: nil
      ],
      extra
    )
  end

  defp age(hours), do: @now - hours * @hour

  describe "scratch sweeping" do
    test "removes a dir older than the cutoff with nothing claiming it", %{root: root} do
      dir = scratch(root, "jason-1.4.1-#{age(5)}")

      assert :ok = Sweep.run(opts(root))
      refute File.exists?(dir)
    end

    test "keeps a dir younger than the cutoff", %{root: root} do
      dir = scratch(root, "jason-1.4.1-#{age(1)}")

      assert :ok = Sweep.run(opts(root))
      assert File.exists?(dir)
    end

    test "keeps an old dir whose ingest job is still live", %{root: root} do
      run_id = "jason-1.4.1-#{age(9)}"
      dir = scratch(root, run_id)

      assert :ok = Sweep.run(opts(root, live_run_ids: MapSet.new([run_id])))
      assert File.exists?(dir)
    end

    # The disk name is `safe_name(run_id)`, so a run_id that sanitizes has to be
    # compared in sanitized form or it never matches its own ingest job.
    test "keeps an old dir whose live run_id needed sanitizing", %{root: root} do
      run_id = "pkg-1.0.0+build.1-#{age(9)}"
      dir = scratch(root, "pkg-1.0.0_build.1-#{age(9)}")

      assert :ok =
               Sweep.run(opts(root, live_run_ids: MapSet.new([Portal.Builder.safe_name(run_id)])))

      assert File.exists?(dir)
    end

    test "removes an old dir whose ingest job has finished", %{root: root} do
      dir = scratch(root, "jason-1.4.1-#{age(9)}")

      # A completed ingest is not in the live set — that is the whole signal.
      assert :ok = Sweep.run(opts(root, live_run_ids: MapSet.new(["some-other-run-123"])))
      refute File.exists?(dir)
    end

    test "keeps an old dir whose container is still running", %{root: root} do
      name = "nerves_system_rpi0-1.2.3-#{age(9)}"
      dir = scratch(root, name)

      assert :ok = Sweep.run(opts(root, running_containers: MapSet.new(["ncc-#{name}"])))
      assert File.exists?(dir)
    end

    test "keeps and warns about a dir with no trailing timestamp", %{root: root} do
      dir = scratch(root, "hand-made-debris")

      log = capture_log(fn -> assert :ok = Sweep.run(opts(root)) end)

      assert File.exists?(dir)
      assert log =~ "unrecognized scratch dir"
    end

    test "a missing scratch root is a no-op, not a failure" do
      assert :ok = Sweep.run(opts("/nonexistent/ncc-scratch"))
    end

    test "one undeletable dir does not stop the others", %{root: root} do
      keep = scratch(root, "blocked-1.0.0-#{age(9)}")
      other = scratch(root, "fine-1.0.0-#{age(9)}")

      File.chmod!(keep, 0o500)
      on_exit(fn -> File.chmod(keep, 0o700) end)

      log = capture_log(fn -> assert :ok = Sweep.run(opts(root)) end)

      # The unwritable parent keeps its child; the sweeper still got the other.
      assert File.exists?(Path.join(keep, "work"))
      refute File.exists?(other)
      assert log =~ "could not remove"
    end

    test "dry_run reports without deleting", %{root: root} do
      dir = scratch(root, "jason-1.4.1-#{age(9)}")

      # The whole point of dry_run is the log, and the suite runs at :warning.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log = capture_log(fn -> assert :ok = Sweep.run(opts(root, dry_run: true)) end)

      assert File.exists?(dir)
      assert log =~ "Sweep removed scratch"
      # The total counts files (hex cache) as well as dirs.
      assert log =~ ~r/Sweep reclaimed 1 entries/
    end
  end

  describe "build cache pruning" do
    setup do
      cache = Path.join(System.tmp_dir!(), "sweep-cache-#{System.unique_integer([:positive])}")
      File.mkdir_p!(cache)
      on_exit(fn -> File.rm_rf(cache) end)
      %{cache: cache}
    end

    defp slug(cache, name, opts) do
      dir = Path.join(cache, name)
      File.mkdir_p!(Path.join(dir, "deps"))

      if hours = opts[:age_hours] do
        posix = div(@now, 1000) - hours * 3600
        File.touch!(dir, posix)
      end

      dir
    end

    test "removes a slug for an image that no longer exists", %{root: root, cache: cache} do
      dead = slug(cache, "sha256_666603aaaa", age_hours: 24 * 30)

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil
                 )
               )

      refute File.exists?(dead)
    end

    test "keeps the slug of the current image", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 24 * 30)

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil
                 )
               )

      assert File.exists?(live)
    end

    test "keeps a recently written slug even if no image claims it", %{root: root, cache: cache} do
      fresh = slug(cache, "sha256_deadbeef", age_hours: 2)

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil
                 )
               )

      assert File.exists?(fresh)
    end

    # image_digest/1 answers with the zero digest on any docker failure, so a
    # hiccup is indistinguishable from "the live image is gone".
    test "deletes nothing when the current digest is unresolved", %{root: root, cache: cache} do
      zero = "sha256:" <> String.duplicate("0", 64)
      dead = slug(cache, "sha256_666603aaaa", age_hours: 24 * 30)

      log =
        capture_log(fn ->
          assert :ok =
                   Sweep.run(
                     opts(root,
                       build_cache: cache,
                       current_digest: zero,
                       nerves_cache: nil,
                       hex_cache: nil
                     )
                   )
        end)

      assert File.exists?(dead)
      assert log =~ "current image digest unresolved"
    end

    test "removes abandoned .tmp staging trees inside a live slug", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 2)
      staging = Path.join(live, "jason-1.4.1.tmp.a1b2c3d4e5f60718")
      real = Path.join(live, "jason-1.4.1")
      File.mkdir_p!(staging)
      File.mkdir_p!(real)

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil
                 )
               )

      refute File.exists?(staging)
      # The completed entry is the whole reason the cache exists.
      assert File.exists?(real)
    end

    test "refuses to prune a build cache that overlaps a protected cache", %{
      root: root,
      cache: cache
    } do
      dead = slug(cache, "sha256_666603aaaa", age_hours: 24 * 30)

      log =
        capture_log(fn ->
          assert :ok =
                   Sweep.run(
                     opts(root,
                       build_cache: Path.join(cache, "nested"),
                       current_digest: "sha256:0b9beb41",
                       nerves_cache: cache,
                       hex_cache: nil
                     )
                   )
        end)

      assert File.exists?(dead)
      assert log =~ "overlaps a protected cache"
    end

    test "an unconfigured build cache is a no-op", %{root: root} do
      assert :ok = Sweep.run(opts(root, build_cache: nil))
    end
  end

  # Everything above injects the live sets. These exercise the real queries: the
  # JSONB `->>` extraction, and the fact that Oban stores `worker` without the
  # "Elixir." prefix. Both are easy to get subtly wrong and silently return the
  # empty set — which would make every scratch dir look orphaned.
  describe "live job queries against the real oban_jobs table" do
    alias Portal.Workers.{Build, Ingest}

    test "an available ingest job protects its scratch dir", %{root: root} do
      run_id = "jason-1.4.1-#{age(9)}"
      dir = scratch(root, run_id)
      Portal.Repo.insert!(Ingest.new(%{"run_id" => run_id, "image_digest" => "sha256:x"}))

      assert :ok = Sweep.run(root |> opts() |> Keyword.delete(:live_run_ids))
      assert File.exists?(dir)
    end

    test "a completed ingest job does not", %{root: root} do
      run_id = "jason-1.4.1-#{age(9)}"
      dir = scratch(root, run_id)

      Portal.Repo.insert!(
        Ingest.new(%{"run_id" => run_id, "image_digest" => "sha256:x"},
          state: "completed",
          completed_at: DateTime.utc_now()
        )
      )

      assert :ok = Sweep.run(root |> opts() |> Keyword.delete(:live_run_ids))
      refute File.exists?(dir)
    end

    # The disk name is `safe_name(run_id)`, so the query has to sanitize too or a
    # semver with build metadata never matches its own ingest job.
    test "a live ingest job whose run_id needs sanitizing still protects its dir", %{root: root} do
      run_id = "pkg-1.0.0+build.1-#{age(9)}"
      dir = scratch(root, "pkg-1.0.0_build.1-#{age(9)}")
      Portal.Repo.insert!(Ingest.new(%{"run_id" => run_id, "image_digest" => "sha256:x"}))

      assert :ok = Sweep.run(root |> opts() |> Keyword.delete(:live_run_ids))
      assert File.exists?(dir)
    end

    test "an unrelated ingest job does not protect anything", %{root: root} do
      dir = scratch(root, "jason-1.4.1-#{age(9)}")
      Portal.Repo.insert!(Ingest.new(%{"run_id" => "other-2.0.0-1", "image_digest" => "x"}))

      assert :ok = Sweep.run(root |> opts() |> Keyword.delete(:live_run_ids))
      refute File.exists?(dir)
    end

    test "a queued build job protects the cache slug it will want", %{root: root} do
      cache = Path.join(System.tmp_dir!(), "sweep-cache-#{System.unique_integer([:positive])}")
      claimed = Path.join(cache, "sha256_aaaa1111")
      File.mkdir_p!(claimed)
      File.touch!(claimed, div(@now, 1000) - 30 * 24 * 3600)
      on_exit(fn -> File.rm_rf(cache) end)

      Portal.Repo.insert!(
        Build.new(%{
          "package" => "jason",
          "version" => "1.4.1",
          "image_digest" => "sha256:aaaa1111"
        })
      )

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil
                 )
               )

      assert File.exists?(claimed)
    end
  end

  describe "hex cache size bound" do
    # The cache is `packages/hexpm/<name>-<version>.tar` next to `cache.ets`.
    # Tarballs are content-addressed by Hex and re-fetched on demand, so
    # evicting the oldest is safe; `cache.ets` is the registry and never goes.
    #
    # Lives in its own tmp dir rather than under `root`: `sweep_scratch` would
    # otherwise see a `hex` dir inside the scratch root and warn about it as
    # an unrecognized orphan.
    setup do
      hex = Path.join(System.tmp_dir!(), "sweep-hex-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(hex, "packages/hexpm"))
      File.write!(Path.join(hex, "cache.ets"), "registry")
      on_exit(fn -> File.rm_rf(hex) end)
      %{hex: hex}
    end

    defp tarball(hex, name, bytes, age_hours) do
      path = Path.join(hex, "packages/hexpm/#{name}.tar")
      File.write!(path, String.duplicate("x", bytes))
      File.touch!(path, div(age(age_hours), 1000))
      path
    end

    test "evicts oldest-modified tarballs until under the bound", %{root: root, hex: hex} do
      old = tarball(hex, "old-1.0.0", 400, 48)
      mid = tarball(hex, "mid-1.0.0", 400, 24)
      new = tarball(hex, "new-1.0.0", 400, 1)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 900))

      refute File.exists?(old)
      assert File.exists?(mid)
      assert File.exists?(new)
      assert File.exists?(Path.join(hex, "cache.ets"))
    end

    test "touches nothing under the bound", %{root: root, hex: hex} do
      a = tarball(hex, "a-1.0.0", 100, 48)
      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 1_000))
      assert File.exists?(a)
    end

    test "dry_run reports without deleting", %{root: root, hex: hex} do
      old = tarball(hex, "old-1.0.0", 400, 48)
      tarball(hex, "new-1.0.0", 400, 1)

      # The whole point of dry_run is the log, and the suite runs at :warning.
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 500, dry_run: true))
        end)

      assert File.exists?(old)
      assert log =~ "old-1.0.0.tar"
    end

    # Seconds since the epoch, `hours` before the fixed clock.
    defp posix_ago(hours), do: div(age(hours), 1000)

    defp hex_file(hex, rel, bytes, opts) do
      path = Path.join(hex, rel)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, String.duplicate("x", bytes))

      # `File.touch!/2` sets both times to one value; these tests need them apart.
      stat = File.stat!(path, time: :posix)

      File.write_stat!(
        path,
        %{stat | atime: Keyword.fetch!(opts, :atime), mtime: Keyword.fetch!(opts, :mtime)},
        time: :posix
      )

      path
    end

    # The bound is on bytes, not on names: a build that writes `.bin` files
    # (or anything else) under packages/ must not dodge it.
    test "counts and evicts non-tarball files under packages", %{root: root, hex: hex} do
      bin = hex_file(hex, "packages/hexpm/x.bin", 400, atime: posix_ago(48), mtime: posix_ago(48))
      top = hex_file(hex, "packages/junk", 400, atime: posix_ago(36), mtime: posix_ago(36))
      tar = tarball(hex, "keep-1.0.0", 400, 24)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 500))

      refute File.exists?(bin)
      refute File.exists?(top)
      assert File.exists?(tar)
    end

    # Hex does not rewrite a cached tarball on a 304, so mtime alone is the
    # first-download order. A tarball read recently is in use, whatever its mtime.
    test "a recently read file outlives one old in both times", %{root: root, hex: hex} do
      read =
        hex_file(hex, "packages/hexpm/read-1.0.0.tar", 400,
          atime: posix_ago(3),
          mtime: posix_ago(96)
        )

      stale =
        hex_file(hex, "packages/hexpm/stale-1.0.0.tar", 400,
          atime: posix_ago(24),
          mtime: posix_ago(24)
        )

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 500))

      assert File.exists?(read)
      refute File.exists?(stale)
    end

    # A hostile file dated in the future would otherwise sort newest and push
    # every legitimate tarball out ahead of it.
    test "a future-dated file is evicted first", %{root: root, hex: hex} do
      future = posix_ago(-24)

      evil =
        hex_file(hex, "packages/hexpm/evil-1.0.0.tar", 400, atime: future, mtime: future)

      old = tarball(hex, "old-1.0.0", 400, 48)
      mid = tarball(hex, "mid-1.0.0", 400, 24)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 900))

      refute File.exists?(evil)
      assert File.exists?(old)
      assert File.exists?(mid)
    end

    # A build may have just had a 304 for this tarball and be about to unpack it.
    test "never evicts a file used within the build wall clock", %{root: root, hex: hex} do
      recent = tarball(hex, "recent-1.0.0", 400, 1)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 0))

      assert File.exists?(recent)
    end

    test "removes old junk at the cache root but keeps the registry and config", %{
      root: root,
      hex: hex
    } do
      ets = Path.join(hex, "cache.ets")
      config = Path.join(hex, "hex.config")
      File.write!(config, "config")

      for path <- [ets, config], do: File.touch!(path, posix_ago(24 * 30))

      junk = hex_file(hex, "junk", 100, atime: posix_ago(5), mtime: posix_ago(5))

      temp =
        hex_file(hex, ".cache.ets.12345", 100, atime: posix_ago(24), mtime: posix_ago(24))

      fresh = hex_file(hex, "fresh", 100, atime: posix_ago(1), mtime: posix_ago(1))
      dir = Path.join(hex, "somedir")
      File.mkdir_p!(dir)

      # Under the size bound: root junk goes on age alone.
      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 1_000_000))

      refute File.exists?(junk)
      refute File.exists?(temp)
      assert File.exists?(fresh)
      assert File.exists?(ets)
      assert File.exists?(config)
      assert File.dir?(dir)
      assert File.dir?(Path.join(hex, "packages"))
    end

    test "never follows or removes a symlink at the cache root", %{root: root, hex: hex} do
      victim_dir =
        Path.join(System.tmp_dir!(), "sweep-hex-victim-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim_dir)
      on_exit(fn -> File.rm_rf(victim_dir) end)

      victim = Path.join(victim_dir, "victim")
      File.write!(victim, "x")
      File.touch!(victim, posix_ago(96))

      link = Path.join(hex, "link")
      File.ln_s!(victim, link)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 0))

      assert File.exists?(victim)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(link)
    end

    # Nothing but a build container writes /hex-cache. With none alive there
    # is no one to swap a directory for a symlink mid-sweep, so the hex sweep
    # runs only then.
    test "skips the whole hex sweep while a build container is running", %{
      root: root,
      hex: hex
    } do
      old = tarball(hex, "old-1.0.0", 400, 48)
      junk = hex_file(hex, "junk", 100, atime: posix_ago(5), mtime: posix_ago(5))
      dead = scratch(root, "jason-1.4.1-#{age(9)}")

      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: :warning) end)

      log =
        capture_log(fn ->
          Sweep.run(
            opts(root,
              hex_cache: hex,
              hex_cache_max_bytes: 0,
              running_containers: MapSet.new(["ncc-jason-1.4.1-123", "postgres"])
            )
          )
        end)

      assert File.exists?(old)
      assert File.exists?(junk)
      assert log =~ "Sweep skipping hex cache: 1 build container(s) running"
      # The scratch sweep is unaffected: this dir belongs to no running build.
      refute File.exists?(dead)
    end

    test "unrelated running containers do not stop the hex sweep", %{root: root, hex: hex} do
      old = tarball(hex, "old-1.0.0", 400, 48)
      junk = hex_file(hex, "junk", 100, atime: posix_ago(5), mtime: posix_ago(5))

      Sweep.run(
        opts(root,
          hex_cache: hex,
          hex_cache_max_bytes: 0,
          running_containers: MapSet.new(["postgres", "umami"])
        )
      )

      refute File.exists?(old)
      refute File.exists?(junk)
    end

    # `:error` is a failed docker lookup. A build may be running, so fail closed.
    test "a failed container lookup skips the hex sweep", %{root: root, hex: hex} do
      old = tarball(hex, "old-1.0.0", 400, 48)
      junk = hex_file(hex, "junk", 100, atime: posix_ago(5), mtime: posix_ago(5))
      dead = scratch(root, "jason-1.4.1-#{age(9)}")

      log =
        capture_log(fn ->
          Sweep.run(
            opts(root, hex_cache: hex, hex_cache_max_bytes: 0, running_containers: :error)
          )
        end)

      assert File.exists?(old)
      assert File.exists?(junk)
      assert log =~ "could not list running containers"
      # The scratch path keeps its old behaviour: a failed lookup is an empty
      # set there, and its age floor keeps that safe.
      refute File.exists?(dead)
    end

    # A build that starts after the walk and before the deletes must still
    # stop them. The lookup is asked again right before deleting.
    test "a build starting during the walk stops the deletes", %{hex: hex} do
      old = tarball(hex, "old-1.0.0", 400, 48)
      junk = hex_file(hex, "junk", 100, atime: posix_ago(5), mtime: posix_ago(5))

      # Counts calls: the first (before the walk) sees no build, the second
      # (before deleting) sees one. A missing scratch root keeps the scratch
      # sweep from consuming a call.
      Process.put(:lookups, 0)

      lookup = fn ->
        n = Process.put(:lookups, Process.get(:lookups) + 1)
        if n == 0, do: MapSet.new(), else: MapSet.new(["ncc-late-1.0.0-1"])
      end

      capture_log(fn ->
        Sweep.run(
          opts("/nonexistent/ncc-scratch",
            hex_cache: hex,
            hex_cache_max_bytes: 0,
            running_containers: lookup
          )
        )
      end)

      assert Process.get(:lookups) == 2
      assert File.exists?(old)
      assert File.exists?(junk)
    end

    # Clock skew or a write landing during the walk can put a just-used file a
    # little after `now`. That is "just used", not hostile.
    test "a slightly future file is in use, a far-future one goes first", %{
      root: root,
      hex: hex
    } do
      soon =
        hex_file(hex, "packages/hexpm/soon-1.0.0.tar", 400,
          atime: posix_ago(48),
          mtime: div(@now, 1000) + 60
        )

      far = posix_ago(-24)
      evil = hex_file(hex, "packages/hexpm/evil-1.0.0.tar", 400, atime: far, mtime: far)
      old = tarball(hex, "old-1.0.0", 400, 48)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 500))

      assert File.exists?(soon)
      refute File.exists?(evil)
      # Over the bound still (soon + old = 800), but old is the only candidate.
      refute File.exists?(old)
    end

    test "a missing hex cache is a no-op", %{root: root} do
      assert :ok =
               Sweep.run(opts(root, hex_cache: Path.join(root, "nope"), hex_cache_max_bytes: 1))
    end

    # `/hex-cache` is bind-mounted read-write into every build container,
    # which runs the package's own build scripts, so a symlink planted inside
    # `packages/` is attacker-controlled. Sweep must never follow one: not to
    # walk it (a symlinked directory could point outside the cache entirely,
    # even at `/`) and not to stat or delete it (a symlinked file could point
    # at anything the ncc user can reach on the host).
    test "does not follow a symlinked directory inside packages", %{root: root, hex: hex} do
      victim_dir =
        Path.join(System.tmp_dir!(), "sweep-hex-victim-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim_dir)
      on_exit(fn -> File.rm_rf(victim_dir) end)

      victim = Path.join(victim_dir, "victim.tar")
      File.write!(victim, String.duplicate("x", 10_000))
      File.touch!(victim, div(age(96), 1000))

      link = Path.join(hex, "packages/hexpm/evil")
      File.ln_s!(victim_dir, link)

      # A real tarball in the cache, over the bound, so the sweep does evict
      # something -- proving the symlinked dir survives a real eviction pass
      # rather than merely being skipped because nothing ran. Older than the
      # 2h in-use window, which would otherwise protect it.
      a = tarball(hex, "a-1.0.0", 100, 5)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 0))

      refute File.exists?(a)
      assert File.exists?(victim)
      assert File.exists?(link)
    end

    # A build can `rm -rf /hex-cache/packages && ln -s / /hex-cache/packages`.
    # Walking through that link would make Sweep delete the oldest files
    # anywhere on the host the portal user can unlink.
    test "does nothing when packages itself is a symlink", %{root: root, hex: hex} do
      victim_dir =
        Path.join(System.tmp_dir!(), "sweep-hex-victim-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim_dir)
      on_exit(fn -> File.rm_rf(victim_dir) end)

      victim = Path.join(victim_dir, "old.tar")
      File.write!(victim, String.duplicate("x", 10_000))
      File.touch!(victim, div(age(96), 1000))

      packages = Path.join(hex, "packages")
      File.rm_rf!(packages)
      File.ln_s!(victim_dir, packages)

      log =
        capture_log(fn ->
          assert :ok = Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 0))
        end)

      assert File.exists?(victim)
      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(packages)
      assert log =~ "not a real directory"
    end

    test "does nothing when the cache root itself is a symlink", %{root: root, hex: hex} do
      victim = Path.join(hex, "packages/hexpm/old.tar")
      File.write!(victim, String.duplicate("x", 10_000))
      File.touch!(victim, div(age(96), 1000))

      link =
        Path.join(System.tmp_dir!(), "sweep-hex-link-#{System.unique_integer([:positive])}")

      File.ln_s!(hex, link)
      on_exit(fn -> File.rm(link) end)

      capture_log(fn ->
        assert :ok = Sweep.run(opts(root, hex_cache: link, hex_cache_max_bytes: 0))
      end)

      assert File.exists?(victim)
    end

    test "does not follow a symlinked tarball", %{root: root, hex: hex} do
      victim_dir =
        Path.join(System.tmp_dir!(), "sweep-hex-victim-#{System.unique_integer([:positive])}")

      File.mkdir_p!(victim_dir)
      on_exit(fn -> File.rm_rf(victim_dir) end)

      victim = Path.join(victim_dir, "victim.tar")
      File.write!(victim, String.duplicate("x", 10_000))

      link = Path.join(hex, "packages/hexpm/link.tar")
      File.ln_s!(victim, link)

      Sweep.run(opts(root, hex_cache: hex, hex_cache_max_bytes: 0))

      assert File.exists?(victim)
      assert File.exists?(link)
    end
  end
end
