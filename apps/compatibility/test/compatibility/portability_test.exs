defmodule Compatibility.PortabilityTest do
  use ExUnit.Case, async: true

  alias Compatibility.Portability

  test "every trace refusal starts with a shared prefix" do
    for reason <- [
          "compile-time host read: os:type/0 in elixir_compiler_1.__MODULE__/1 (lib/x.ex:2)",
          "compile-time host read in mix.exs: os:getenv/1 sets elixirc_options (/p/mix.exs:9)",
          "compile-time write outside ebin: file:make_dir/1 /p/_build/host/phoenix-colocated/x",
          "compile-time tracing or system flag: erlang:system_flag/2",
          "calls natively built dependency at compile time: circuits_gpio:open/2",
          "bakes the build path: Elixir.X \"/p/deps/x\"",
          "closure dependency observed the host: d (compile-time host read: os:type/0)",
          "rebar3 build runs pre_hooks",
          "compile-time native library load: /tmp/evil.so",
          "compile-time priv write not reproducible: priv/assets/x.tar.gz differs"
        ] do
      assert Portability.refusal?(reason), reason
    end
  end

  # Only R1 (the package's own compile observed the host, or read the Elixir
  # version in a way that differs between patches) and R2 (a baked build
  # path) withdraw an earlier publication.
  test "the withdrawing prefixes are the R1 and R2 subset of the refusal prefixes" do
    assert Portability.withdrawing_prefixes() -- Portability.refusal_prefixes() == []

    assert Enum.sort(Portability.withdrawing_prefixes()) ==
             Enum.sort([
               "compile-time host read: ",
               "compile-time host read in mix.exs: ",
               "compile-time write outside ebin: ",
               "compile-time tracing or system flag: ",
               "compile-time Elixir patch dependence: ",
               "compile-time priv write not reproducible: ",
               "bakes the build path: "
             ])

    for reason <- [
          "closure dependency observed the host: d (compile-time host read: os:type/0)",
          "calls natively built dependency at compile time: circuits_gpio:open/2",
          "rebar3 build runs pre_hooks",
          "compile-time native library load: /tmp/evil.so",
          "portability could not be judged"
        ] do
      refute Portability.withdraws?(reason), reason
    end

    assert Portability.withdraws?("compile-time host read: os:type/0")
    assert Portability.withdraws?("bakes the build path: Elixir.X \"<root>\"")

    assert Portability.withdraws?(
             Portability.priv_not_reproduced() <> "priv/assets/x.tar.gz differs"
           )

    refute Portability.withdraws?(nil)
  end

  test "could-not-judge, rule 1 reasons and non-strings are not refusals" do
    refute Portability.refusal?(Portability.could_not_judge())
    refute Portability.refusal?("calls System.cmd/2")
    refute Portability.refusal?("OS-specific (lib/x.ex: :os.type()")
    refute Portability.refusal?(nil)
  end

  test "the could-not-judge reason is the one portable?/4 already writes" do
    assert Portability.could_not_judge() == "portability could not be judged"
  end

  test "a compile-time config read refusal is a refusal that withdraws nothing" do
    reason = "compile-time config read: application:get_all_env/1 (x) has no key to match on"
    assert Portability.refusal?(reason)
    refute Portability.withdraws?(reason)
  end

  test "an Elixir patch dependence refusal is an R1 refusal that withdraws" do
    reason = "compile-time Elixir patch dependence: System.build_info/0 in X (lib/x.ex:1)"
    assert Portability.refusal?(reason)
    assert Portability.withdraws?(reason)
  end

  test "a manager mismatch is a refusal that withdraws nothing" do
    reason = Compatibility.Portability.manager_mismatch() <> "ranch (trace make, tarball rebar3)"
    assert reason == "manager mismatch: ranch (trace make, tarball rebar3)"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end

  test "a tree that differs from its tarball is a refusal that withdraws nothing" do
    reason = Compatibility.Portability.tree_differs() <> "kino (extra file lib/x.js)"
    assert reason == "dependency tree differs from its tarball: kino (extra file lib/x.js)"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end

  describe "with_cause/2" do
    test "names the trace break, not the lines missing because of it" do
      problems = [
        "no end line",
        "stats missing or unjudged events",
        "trace collector died: killed",
        "no stats line",
        "date_time_parser's window was never closed"
      ]

      assert Portability.with_cause(Portability.could_not_judge(), problems) ==
               "portability could not be judged (trace collector died: killed)"
    end

    test "a child VM's collector and the read budget are trace breaks too" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "rebar3 app has no verified Hex tarball",
               "child trace of dns_erlang: trace collector died: killed"
             ]) ==
               "portability could not be judged (child trace of dns_erlang: trace collector died: killed)"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "no start line",
               "the host build is not the traced compile",
               "the trace files exceed the report's read budget"
             ]) ==
               "portability could not be judged (the trace files exceed the report's read budget)"
    end

    test "a failed traced compile comes before what follows from it" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "the host build is not the traced compile",
               "traced compile exited 1"
             ]) == "portability could not be judged (traced compile exited 1)"
    end

    test "otherwise the first problem, unwrapped when it is a could-not-judge itself" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "unreviewed toolchain config read: elixir dbg_callback from Elixir.Kernel",
               "compile-time probe of a module the trace loaded: httpc (inets)"
             ]) ==
               "portability could not be judged " <>
                 "(unreviewed toolchain config read: elixir dbg_callback from Elixir.Kernel)"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "portability could not be judged (dependency tree changed after the check: " <>
                 "gpb (read descr_src/gpb_descriptor.erl))"
             ]) ==
               "portability could not be judged (dependency tree changed after the check: " <>
                 "gpb (read descr_src/gpb_descriptor.erl))"
    end

    test "keeps the portal's transient count after the cause" do
      reason = Portability.could_not_judge() <> " (transient 5 times)"

      assert Portability.with_cause(reason, ["tracer: :timeout", "no end line"]) ==
               "portability could not be judged (tracer: :timeout) (transient 5 times)"
    end

    defp cause(problems) do
      Portability.could_not_judge()
      |> Portability.with_cause(problems)
      |> Portability.cause_of()
    end

    test "never stores a path, absolute or under ~, spaces and all" do
      assert cause([
               "built outside the trace: kino (digest failed now: {:enoent, ~c\"/work/proj/_build/host/lib/kino/ebin\"})"
             ]) == "built outside the trace: kino (digest failed now: {:enoent, ~c\"…\"})"

      assert cause(["could not read /home/nerves/my secret dir/key.pem"]) ==
               "could not read …"

      assert cause(["could not read ~/.ssh/id_rsa (enoent)"]) == "could not read … (enoent)"

      assert cause(["/etc/x: refused, then ~/a b/c, d"]) == "…: refused, then …, d"

      assert cause(["file:make_dir/1 /work/proj/_build (a link)"]) ==
               "file:make_dir/1 … (a link)"

      # A path's line number is not part of it; relative paths and MFAs stay.
      assert cause(["read /work/proj/deps/x/mix.exs:12 in Mix.Project.deps/0"]) ==
               "read …:12 in Mix.Project.deps/0"

      assert cause([
               "dependency tree changed after the check: gpb (read descr_src/gpb_descriptor.erl)"
             ]) ==
               "dependency tree changed after the check: gpb (read descr_src/gpb_descriptor.erl)"
    end

    test "never stores a value an exception, a tracer or a dead process quotes" do
      assert cause([
               "judge failed: no match of right hand side value: %{\"value\" => \"s3cr3t\"}"
             ]) ==
               "judge failed: no match of right hand side value"

      assert cause(["tracer: {:install_failed, \"could not write /home/me/x\"}"]) ==
               "tracer: :install_failed"

      assert cause(["tracer: SECRET=abc"]) == "tracer: SECRET"
      assert cause(["tracer: :timeout"]) == "tracer: :timeout"
      assert cause(["trace collector died: killed"]) == "trace collector died: killed"

      assert cause(["trace collector died: {badarg,[{m,f,[<<\"SECRET=abc\">>],[]}]}"]) ==
               "trace collector died: badarg"

      assert cause(["trace watcher died: {{nocatch,\"s3cr3t\"},[]}"]) ==
               "trace watcher died:"

      assert cause(["child trace of x: tracer: {:install_failed, \"SECRET=abc\"}"]) ==
               "child trace of x: tracer: :install_failed"

      assert cause(["child trace of dns_erlang: trace collector died: killed"]) ==
               "child trace of dns_erlang: trace collector died: killed"
    end

    test "is one line of at most 200 bytes" do
      long = "windows [" <> Enum.join(List.duplicate("plug_crypto", 100), ", ") <> "]"
      long_cause = cause([long])
      assert byte_size(long_cause) <= 200
      assert byte_size(long_cause) > 190
      assert String.ends_with?(long_cause, "…")
      assert String.valid?(long_cause)

      # One grapheme of 5,000 combining marks is 10 KB.
      marks = "e" <> String.duplicate("\u0301", 5_000)
      marked = cause([marks])
      assert byte_size(marked) <= 200
      assert String.valid?(marked)

      wide = cause([String.duplicate("ü", 300)])
      assert byte_size(wide) <= 200
      assert String.valid?(wide)

      assert cause(["one\nline\ttwo\u2028three\u2029four\u0085five\u202Esix"]) ==
               "one line two three four five six"
    end

    test "a bare could-not-judge problem names no cause" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               Portability.could_not_judge()
             ]) == Portability.could_not_judge()

      assert cause([Portability.could_not_judge(), "trace overflowed: queue"]) ==
               "trace overflowed: queue"
    end

    test "leaves every other reason, and a could-not-judge with no problems, as it is" do
      for reason <- [
            "compile-time host read: os:type/0",
            "portability could not be judged (unknown variant)",
            nil
          ] do
        assert Portability.with_cause(reason, ["trace collector died: killed"]) == reason
      end

      for problems <- [[], nil, [""], [1, :x]] do
        assert Portability.with_cause(Portability.could_not_judge(), problems) ==
                 Portability.could_not_judge()
      end
    end

    test "cause_of/1 reads the cause back" do
      for problems <- [
            ["trace collector died: killed"],
            ["built outside the trace: quicer (digest failed at window close: outside_tree)"]
          ],
          suffix <- ["", " (transient 5 times)"] do
        reason = Portability.with_cause(Portability.could_not_judge() <> suffix, problems)
        assert Portability.cause_of(reason) == hd(problems), reason
      end

      for reason <- [
            Portability.could_not_judge(),
            Portability.could_not_judge() <> " (transient 5 times)",
            "compile-time host read: os:type/0 (x)",
            nil
          ] do
        assert Portability.cause_of(reason) == nil, inspect(reason)
      end
    end

    test "a reason with its cause is still a could-not-judge and no refusal" do
      reason =
        Portability.with_cause(Portability.could_not_judge(), [
          "compile-time host read: os:type/0"
        ])

      assert Portability.could_not_judge?(reason)
      refute Portability.refusal?(reason)
      refute Portability.withdraws?(reason)
      refute Portability.could_not_judge?("compile-time host read: os:type/0")
      refute Portability.could_not_judge?(nil)
    end
  end
end
