defmodule Portal.Catalog.RunMemoryTest do
  use Portal.DataCase, async: false

  import ExUnit.CaptureLog

  alias Portal.Catalog.RunMemory

  @resources %{
    "peak_used_bytes" => 1_500_000_000,
    "peak_total_bytes" => 2_000_000_000,
    "limit_bytes" => 4_294_967_296,
    "samples" => 12,
    "read_errors" => 0,
    "interval_ms" => 5000,
    "started_at" => "2026-11-12T10:00:00.000000Z",
    "sampled_at" => "2026-11-12T10:01:00.000000Z"
  }

  @firmware_args %{
    run_id: "jason-1.4.4-1",
    package: "jason",
    version: "1.4.4",
    image_digest: "sha256:fw"
  }

  defp ok(exit_code, resources) do
    {:ok,
     %{
       exit_code: exit_code,
       result: nil,
       resources: resources,
       files_dir: "",
       output_dir: "",
       log: ""
     }}
  end

  defp rows, do: Ash.read!(RunMemory, domain: Portal.Catalog)

  setup do
    previous = Application.get_env(:portal, Portal.Builder, [])
    on_exit(fn -> Application.put_env(:portal, Portal.Builder, previous) end)
    {:ok, previous: previous}
  end

  test "a firmware build writes its memory record" do
    assert :ok = RunMemory.record(:firmware, @firmware_args, ok(0, @resources), %{attempt: 2})

    assert [row] = rows()
    assert row.run_id == "jason-1.4.4-1"
    assert row.kind == :firmware
    assert row.package == "jason"
    assert row.version == "1.4.4"
    assert row.toolchain == nil
    assert row.image_digest == "sha256:fw"
    assert row.host == Atom.to_string(node())
    assert row.attempt == 2
    assert row.exit_code == 0
    refute row.timed_out
    refute row.oom_killed
    # The sampler's MemTotal is the limit the container actually had.
    assert row.memory_limit_bytes == 4_294_967_296
    assert row.peak_used_bytes == 1_500_000_000
    assert row.peak_total_bytes == 2_000_000_000
    assert row.samples == 12
    assert row.started_at == ~U[2026-11-12 10:00:00.000000Z]
    assert %DateTime{} = row.finished_at
    assert %DateTime{} = row.inserted_at
  end

  test "an OOM-killed container with no side file is still counted", %{previous: previous} do
    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.merge(previous, memory: "3g", cpus: "2", build_concurrency: "4")
    )

    assert :ok = RunMemory.record(:firmware, @firmware_args, ok(137, nil), %{attempt: 1})

    assert [row] = rows()
    assert row.exit_code == 137
    assert row.oom_killed
    assert row.memory_limit_bytes == 3 * 1024 * 1024 * 1024
    assert row.cpus == "2"
    assert row.build_concurrency == 4
    assert row.peak_used_bytes == nil
    assert row.peak_total_bytes == nil
    assert row.samples == nil
    assert row.started_at == nil
  end

  test "the caller's effective limit and concurrency win over the configured ones" do
    resources = Map.delete(@resources, "limit_bytes")

    assert :ok =
             RunMemory.record(:firmware, @firmware_args, ok(0, resources), %{
               attempt: 1,
               memory_limit_bytes: 1024,
               build_concurrency: 2
             })

    assert [%{memory_limit_bytes: 1024, build_concurrency: 2}] = rows()
  end

  test "a timeout reads the side file the scratch dir still holds", %{previous: previous} do
    root = Path.join(System.tmp_dir!(), "run-memory-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    Application.put_env(:portal, Portal.Builder, Keyword.put(previous, :scratch_root, root))
    out = Portal.Builder.output_dir(@firmware_args.run_id)
    File.mkdir_p!(out)
    File.write!(Path.join(out, "resources.json"), Jason.encode!(@resources))

    outcome = {:error, {:build_timeout, 7200, "ncc-jason"}}
    assert :ok = RunMemory.record(:firmware, @firmware_args, outcome, %{attempt: 1})

    assert [row] = rows()
    assert row.exit_code == nil
    assert row.timed_out
    refute row.oom_killed
    assert row.peak_used_bytes == 1_500_000_000
  end

  test "a runner failure or a host-condition snooze ran no container and writes no row" do
    for reason <- [
          :docker_unavailable,
          {:input_write_failed, "eacces"},
          {:insufficient_disk, 1, 2},
          :scratch_noexec,
          :egress_filter_missing,
          :build_memory_limit_missing
        ] do
      assert :ok = RunMemory.record(:firmware, @firmware_args, {:error, reason}, %{attempt: 1})
    end

    assert rows() == []
  end

  test "a toolchain run names its toolchain; a warm run has no package" do
    toolchain_args =
      Map.merge(@firmware_args, %{run_id: "tc-jason-1", toolchain: %{elixir: "1.19", otp: "28"}})

    assert :ok =
             RunMemory.record(:toolchain, toolchain_args, ok(0, @resources), %{
               attempt: 1,
               toolchain: "1.19/28"
             })

    warm_args = %{run_id: "warm_nerves-1", mode: "warm_nerves", image_digest: "sha256:w"}
    assert :ok = RunMemory.record(:warm, warm_args, ok(0, @resources), %{attempt: 1})

    by_kind = Map.new(rows(), &{&1.kind, &1})
    assert %{toolchain: "1.19/28", package: "jason"} = by_kind.toolchain
    assert %{package: nil, version: nil, toolchain: nil, image_digest: "sha256:w"} = by_kind.warm
  end

  # The side file is written by a container that runs package code.
  test "values that are not sizes are dropped, not trusted" do
    resources = %{
      @resources
      | "peak_used_bytes" => "lots",
        "peak_total_bytes" => -1,
        "samples" => 1.5,
        "limit_bytes" => 10 ** 30,
        "started_at" => "yesterday"
    }

    assert :ok =
             RunMemory.record(:firmware, @firmware_args, ok(0, resources), %{
               attempt: 1,
               memory_limit_bytes: 2048
             })

    assert [row] = rows()
    assert row.peak_used_bytes == nil
    assert row.peak_total_bytes == nil
    assert row.samples == nil
    assert row.memory_limit_bytes == 2048
    assert row.started_at == nil
  end

  test "a failed insert logs a warning and never raises into the worker" do
    log =
      capture_log(fn ->
        assert :ok = RunMemory.record(:bogus, @firmware_args, ok(0, @resources), %{attempt: 1})
      end)

    assert log =~ "run memory"
    assert log =~ "jason-1.4.4-1"
    assert rows() == []
  end
end
