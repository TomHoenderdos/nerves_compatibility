defmodule NccWorker.TargetDepsGetTest do
  use ExUnit.Case, async: true

  alias NccWorker.TargetDepsGet

  @stale "** (Mix) Unknown package version nerves_system_qemu_aarch64 0.5.2 in lockfile\n"

  # A runner that answers from `results` in order and records each call.
  defp runner(results) do
    agent = start_supervised!({Agent, fn -> results end})

    fn ->
      Agent.get_and_update(agent, fn [next | rest] -> {next, rest} end)
    end
  end

  defp no_sleep(test_pid), do: fn ms -> send(test_pid, {:slept, ms}) end

  test "passes a first success through without a retry" do
    assert TargetDepsGet.run(runner([{"ok\n", 0}]), sleep: no_sleep(self())) == :ok
    refute_received {:slept, _}
  end

  test "retries a lockfile version the registry answer does not know, then succeeds" do
    run = runner([{@stale, 1}, {"ok\n", 0}])

    assert TargetDepsGet.run(run, sleep: no_sleep(self()), waits: [20_000, 60_000]) == :ok
    assert_received {:slept, 20_000}
    refute_received {:slept, 60_000}
  end

  test "gives up after its waits with the last exit code" do
    run = runner([{@stale, 1}, {@stale, 1}, {@stale, 1}])

    assert TargetDepsGet.run(run, sleep: no_sleep(self()), waits: [1, 2]) == {:error, 1}
    assert_received {:slept, 1}
    assert_received {:slept, 2}
  end

  test "does not retry any other failure" do
    run = runner([{"** (Mix) Unknown package foo in lockfile\n", 1}])

    assert TargetDepsGet.run(run, sleep: no_sleep(self())) == {:error, 1}
    refute_received {:slept, _}
  end

  test "stale?/1 names exactly Hex's lockfile-version message" do
    assert TargetDepsGet.stale?(@stale)
    refute TargetDepsGet.stale?("Unknown package version of something else")
    refute TargetDepsGet.stale?("** (Mix) Unknown package foo in lockfile")
  end
end
