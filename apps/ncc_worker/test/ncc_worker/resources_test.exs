defmodule NccWorker.ResourcesTest do
  use ExUnit.Case, async: true

  alias NccWorker.{JsonWriter, Resources, Worker}

  @moduletag :tmp_dir

  @keys ~w(peak_used_bytes peak_total_bytes limit_bytes samples read_errors interval_ms started_at sampled_at)

  # Never fires during a test: every tick is sent by hand.
  @interval_ms 60_000

  defp meminfo(total, free, buffers, cached) do
    """
    MemTotal:       #{total} kB
    MemFree:        #{free} kB
    MemAvailable:   #{free + cached} kB
    Buffers:        #{buffers} kB
    Cached:         #{cached} kB
    SwapCached:     999999 kB
    Active:         1234 kB
    """
  end

  defp start(dir, meminfo_path) do
    start_supervised!(
      {Resources, meminfo_path: meminfo_path, output_dir: dir, interval_ms: @interval_ms}
    )
  end

  defp tick(pid) do
    send(pid, :tick)
    :sys.get_state(pid)
  end

  defp side_file(dir), do: dir |> Path.join("resources.json") |> File.read!() |> JSON.decode!()

  describe "parse/1" do
    test "reads MemTotal, MemFree, Buffers and Cached, not SwapCached" do
      assert {:ok, %{mem_total: 4_000_000, mem_free: 1_000_000, buffers: 100, cached: 200_000}} =
               Resources.parse(meminfo(4_000_000, 1_000_000, 100, 200_000))
    end

    test "is an error when a field is missing or not a number" do
      assert :error = Resources.parse("MemTotal: 4000 kB\nMemFree: 10 kB\n")
      assert :error = Resources.parse(meminfo(4000, 10, 1, 1) |> String.replace("4000", "x"))
      assert :error = Resources.parse("")
    end
  end

  test "a sample records used and total bytes and the limit", %{tmp_dir: dir} do
    path = Path.join(dir, "meminfo")
    File.write!(path, meminfo(4_000_000, 1_000_000, 100_000, 900_000))

    report = dir |> start(path) |> Resources.stop()

    assert report.peak_used_bytes == (4_000_000 - 1_000_000 - 100_000 - 900_000) * 1024
    assert report.peak_total_bytes == (4_000_000 - 1_000_000) * 1024
    assert report.limit_bytes == 4_000_000 * 1024
    assert report.samples >= 1
    assert report.read_errors == 0
    assert report.interval_ms == @interval_ms
    assert {:ok, _, 0} = DateTime.from_iso8601(report.started_at)
    assert {:ok, _, 0} = DateTime.from_iso8601(report.sampled_at)
  end

  test "peaks only grow across ticks", %{tmp_dir: dir} do
    path = Path.join(dir, "meminfo")
    File.write!(path, meminfo(4_000_000, 1_000_000, 0, 0))
    pid = start(dir, path)

    File.write!(path, meminfo(4_000_000, 2_000_000, 0, 0))
    tick(pid)
    File.write!(path, meminfo(4_000_000, 3_000_000, 0, 0))
    tick(pid)

    report = Resources.stop(pid)
    assert report.peak_used_bytes == 3_000_000 * 1024
    assert report.peak_total_bytes == 3_000_000 * 1024
    assert report.samples == 4
  end

  test "the side file is valid JSON after a tick and equals stop/1's map", %{tmp_dir: dir} do
    path = Path.join(dir, "meminfo")
    File.write!(path, meminfo(2_000_000, 500_000, 1000, 2000))
    pid = start(dir, path)
    tick(pid)

    assert dir |> side_file() |> Map.keys() |> Enum.sort() == Enum.sort(@keys)
    assert side_file(dir)["samples"] == 2

    report = Resources.stop(pid)
    assert side_file(dir) == Map.new(report, fn {k, v} -> {Atom.to_string(k), v} end)
    refute File.exists?(Path.join(dir, "resources.json.tmp"))
  end

  test "a missing meminfo counts read errors and never crashes", %{tmp_dir: dir} do
    pid = start(dir, Path.join(dir, "no-such-meminfo"))
    tick(pid)

    report = Resources.stop(pid)
    assert report.read_errors == 3
    assert report.samples == 0
    assert report.peak_used_bytes == nil
    assert report.sampled_at == nil
    assert side_file(dir)["read_errors"] == 3
  end

  test "starts with the default meminfo path whether or not it exists", %{tmp_dir: dir} do
    report = {Resources, output_dir: dir} |> start_supervised!() |> Resources.stop()

    assert report.interval_ms == 5_000
    assert report.samples + report.read_errors >= 1
  end

  describe "the worker" do
    test "puts the sampler's report into its result as resources", %{tmp_dir: dir} do
      path = Path.join(dir, "meminfo")
      File.write!(path, meminfo(4_000_000, 1_000_000, 0, 0))

      assert {:ok, result} =
               Worker.with_resources(dir, fn -> {:ok, %{run_id: "r"}} end, meminfo_path: path)

      assert result.run_id == "r"
      assert result.resources.samples >= 1
      assert result.resources.peak_used_bytes == 3_000_000 * 1024
      assert side_file(dir)["samples"] == result.resources.samples
    end

    test "passes an error through and still stops the sampler", %{tmp_dir: dir} do
      assert {:error, :boom} = Worker.with_resources(dir, fn -> {:error, :boom} end)
      assert File.exists?(Path.join(dir, "resources.json"))
    end

    test "result.json carries resources with the same keys", %{tmp_dir: dir} do
      path = Path.join(dir, "meminfo")
      File.write!(path, meminfo(4_000_000, 1_000_000, 0, 0))

      base = %{
        run_id: "res",
        package: %{name: "jason", version: "1.4.4"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-11-12T10:00:00Z"
      }

      {:ok, result} = Worker.with_resources(dir, fn -> {:ok, base} end, meminfo_path: path)
      assert :ok = JsonWriter.write_result(dir, result)

      decoded = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["resources"] == side_file(dir)
      assert decoded["resources"]["samples"] >= 1
    end

    # A work dir that is a file fails the Nerves cache step, the first one
    # under the sampler, before any `mix` or network.
    test "run/1 samples under the sampler and writes the side file", %{tmp_dir: dir} do
      work = Path.join(dir, "work")
      File.write!(work, "not a directory")
      out = Path.join(dir, "out")

      assert {:error, _reason} =
               Worker.run(%{
                 run_id: "resources-wiring-1",
                 image: %{name: "ncc-worker:local", digest: "sha256:test"},
                 package: %{name: "jason", version: "1.4.4"},
                 paths: %{work_dir: work, output_dir: out}
               })

      assert Enum.sort(Map.keys(side_file(out))) == Enum.sort(@keys)
    end
  end
end
