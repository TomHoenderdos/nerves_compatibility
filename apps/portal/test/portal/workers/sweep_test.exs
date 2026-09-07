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
        build_cache: nil
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
end
