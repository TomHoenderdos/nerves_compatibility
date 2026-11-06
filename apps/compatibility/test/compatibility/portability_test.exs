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
          "rebar3 build runs pre_hooks"
        ] do
      assert Portability.refusal?(reason), reason
    end
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
end
