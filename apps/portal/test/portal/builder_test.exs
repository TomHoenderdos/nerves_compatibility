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

  defp args, do: Builder.build_docker_args(@job, "/work", "/out", "/files")

  test "tells the runtimes how much CPU the container actually has", %{previous: previous} do
    put_builder([cpus: "2"], previous)

    # `--cpus` is a quota; `nproc` inside the container still reports the host's
    # cores, so without these the BEAM starts a scheduler per host core and
    # busy-waits through a quota it does not have.
    assert "ERL_FLAGS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "ELIXIR_ERL_OPTIONS=+S 2:2 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
    assert "MAKEFLAGS=-j2" in args()
  end

  test "a fractional cap still gets one whole scheduler", %{previous: previous} do
    put_builder([cpus: "1.5"], previous)

    assert "MAKEFLAGS=-j1" in args()
    assert "ERL_FLAGS=+S 1:1 +sbwt none +sbwtdcpu none +sbwtdio none" in args()
  end

  test "an uncapped build is left alone", %{previous: previous} do
    put_builder([cpus: nil], previous)

    refute Enum.any?(args(), &String.starts_with?(&1, "ERL_FLAGS="))
    refute Enum.any?(args(), &String.starts_with?(&1, "MAKEFLAGS="))
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
end
