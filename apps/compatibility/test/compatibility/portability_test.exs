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

    test "never stores a path, a quoted value or more than 200 characters" do
      assert Portability.with_cause(Portability.could_not_judge(), [
               "built outside the trace: kino (digest failed now: {:enoent, ~c\"/work/proj/_build/host/lib/kino/ebin\"})"
             ]) ==
               "portability could not be judged " <>
                 "(built outside the trace: kino (digest failed now: {:enoent, ~c\"…/ebin\"}))"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "judge failed: no match of right hand side value: %{\"value\" => \"s3cr3t\"}"
             ]) ==
               "portability could not be judged (judge failed: no match of right hand side value)"

      assert Portability.with_cause(Portability.could_not_judge(), [
               "tracer: {:install_failed, \"could not write /home/me/x\"}"
             ]) == "portability could not be judged (tracer: :install_failed)"

      long = "windows [" <> Enum.join(List.duplicate("plug_crypto", 100), ", ") <> "]"
      reason = Portability.with_cause(Portability.could_not_judge(), [long])
      cause = reason |> String.replace_prefix("portability could not be judged (", "")
      assert String.length(cause) == 201
      assert String.ends_with?(cause, "…)")

      assert Portability.with_cause(Portability.could_not_judge(), ["one\nline\ttwo"]) ==
               "portability could not be judged (one line two)"
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
