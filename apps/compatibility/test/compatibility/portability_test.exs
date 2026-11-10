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
          "compile-time native library load: /tmp/evil.so"
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
    reason = Compatibility.Portability.manager_mismatch() <> "ranch (trace make, lock rebar3)"
    assert reason == "manager mismatch: ranch (trace make, lock rebar3)"
    assert Compatibility.Portability.refusal?(reason)
    refute Compatibility.Portability.withdraws?(reason)
  end
end
