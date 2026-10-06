defmodule Portal.ScanRequests.FailureSummaryTest do
  use ExUnit.Case, async: true

  alias Portal.ScanRequests.FailureSummary

  # Shaped like max_31856's real excerpt: a wall of compiler-warning noise, the
  # crash and its stack trace, then the Builder footer.
  @crash """
  [... truncated, showing the last 16384 bytes of 191261 ...]
      warning: found quoted keyword "uboot_env" but the quotes are not required.
      │
   30 │   "uboot_env": {:hex, :uboot_env, "1.0.2"},
      │   ~
      └─ /work/proj/mix.lock:30:3
  08:46:23.881 [debug] Found 928 files to archive for nerves_system_x86_64
  ** (ErlangError) Erlang error: {:invalid_byte, 130}: invalid byte 16#82 at byte position 0
      (stdlib 8.1) json.erl:543: :json.invalid_byte/2
      (elixir 1.20.3) lib/json.ex:172: JSON.Encoder.Map.next/2
      (elixir 1.20.3) lib/json.ex:162: JSON.Encoder.Map.encode/2
      (elixir 1.20.3) lib/json.ex:172: JSON.Encoder.Map.next/2
      (elixir 1.20.3) lib/json.ex:172: JSON.Encoder.Map.next/2
      (elixir 1.20.3) lib/json.ex:162: JSON.Encoder.Map.encode/2
      (elixir 1.20.3) lib/json.ex:172: JSON.Encoder.Map.next/2
      (elixir 1.20.3) lib/json.ex:172: JSON.Encoder.Map.next/2

  ================================================================================
  Docker exit status: 1
  Completed: 2026-10-06T08:55:47.532614Z
  ================================================================================
  """

  test "an Elixir crash yields the exception line and the top of its stack" do
    summary = FailureSummary.from_log(@crash)

    assert summary =~ "** (ErlangError) Erlang error: {:invalid_byte, 130}"
    assert summary =~ "json.erl:543"
    refute summary =~ "quoted keyword"
    refute summary =~ "Docker exit status"
    assert length(String.split(summary, "\n")) <= 8
  end

  test "the last of several crashes is the one reported" do
    log = "** (RuntimeError) first\n    a.ex:1\nok\n** (ArgumentError) second\n    b.ex:2\n"
    summary = FailureSummary.from_log(log)
    assert summary =~ "second"
    refute summary =~ "first"
  end

  test "a compile failure without an exception falls back to the error lines" do
    log = """
    ==> circuits_gpio
    make: *** [Makefile:42: gpio_nif.o] Error 1
    could not compile dependency :circuits_gpio, "mix compile" failed.
    ================================================================================
    Docker exit status: 10
    """

    summary = FailureSummary.from_log(log)
    assert summary =~ "Error 1"
    assert summary =~ "could not compile dependency :circuits_gpio"
    refute summary =~ "Docker exit status"
  end

  test "a policy message from the worker is picked up" do
    log = "Worker failed: {:policy_violation, [\"deps/foo is a git dep\"]}\n"
    assert FailureSummary.from_log(log) =~ "Worker failed: {:policy_violation"
  end

  test "nothing recognisable gives nil, and so does no log" do
    assert FailureSummary.from_log("all quiet\n") == nil
    assert FailureSummary.from_log(nil) == nil
    assert FailureSummary.from_log("") == nil
  end
end
