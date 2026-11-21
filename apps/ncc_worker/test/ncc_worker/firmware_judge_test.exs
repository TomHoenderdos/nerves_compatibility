defmodule NccWorker.FirmwareJudgeTest do
  use ExUnit.Case, async: true

  alias NccWorker.FirmwareJudge

  describe "classes/1" do
    test "a compile-time probe, in any of its shapes" do
      for text <- [
            "compile-time probe of a module the trace loaded: httpc (inets)",
            "compile-time probe of an OTP application outside the closure: wx",
            "compile-time probe of whether a module is loaded: Jason",
            "pkg: compile-time call into a module the trace loaded: crypto:info/0 (crypto)",
            "compile-time list of the loaded modules: code:all_loaded/0"
          ] do
        assert FirmwareJudge.classes([text]) == ["probe"], text
      end
    end

    test "a rebar3 rule or plugin" do
      for text <- [
            "rebar3 build runs plugins",
            "rebar3 build runs pre_hooks",
            "rebar3 build evaluates rebar.config.script",
            "rebar3 build uses platform_define",
            "rebar3 build runs plugin rebar3_dirs 0.1.0, a release not reviewed",
            "yamerl: rebar3 plugin rebar3_hex 7.0.8: no cached Hex tarball"
          ] do
        assert FirmwareJudge.classes([text]) == ["plugins_hooks"], text
      end
    end

    test "a dependency's taint counts only when its own reason is a probe or a rebar3 rule" do
      assert FirmwareJudge.classes([
               "closure dependency observed the host: crc32cer (rebar3 build runs pre_hooks)"
             ]) == ["taint"]

      assert FirmwareJudge.classes([
               "closure dependency observed the host: x (compile-time probe of a module the trace loaded: httpc (inets))"
             ]) == ["taint"]

      for text <- [
            "closure dependency observed the host: muontrap (compile-time host read: Mix.target/0)",
            "closure dependency observed the host: membrane_core (bakes the build path: X)"
          ] do
        assert FirmwareJudge.classes([text]) == [], text
      end
    end

    test "every other refusal is no class, and classes are sorted and unique" do
      assert FirmwareJudge.classes([
               "compile-time host read: os:getenv/1 (HOME)",
               "portability could not be judged",
               "calls a NIF or port driver"
             ]) == []

      assert FirmwareJudge.classes([
               "rebar3 build runs plugins",
               "compile-time probe of whether a module is loaded: Jason",
               "rebar3 build runs pre_hooks"
             ]) == ["plugins_hooks", "probe"]
    end
  end

  describe "texts/1" do
    test "the verdict's reason, refusals, problems and taint, each taint as the refusal names it" do
      verdict = %{
        reason: "portability could not be judged",
        observations: %{
          "refusals" => [%{"owner" => "pkg", "reason" => "rebar3 build runs plugins"}, "odd"],
          "problems" => ["pkg: compile-time probe of whether a module is loaded: X", 7],
          "taint" => %{"crc32cer" => "rebar3 build runs pre_hooks"}
        }
      }

      assert FirmwareJudge.texts(verdict) == [
               "portability could not be judged",
               "rebar3 build runs plugins",
               "pkg: compile-time probe of whether a module is loaded: X",
               "closure dependency observed the host: crc32cer (rebar3 build runs pre_hooks)"
             ]
    end

    test "a verdict without observations has only its reason" do
      assert FirmwareJudge.texts(%{reason: "rebar3 build runs plugins"}) == [
               "rebar3 build runs plugins"
             ]

      assert FirmwareJudge.texts(%{reason: nil, observations: nil}) == []
    end
  end
end
