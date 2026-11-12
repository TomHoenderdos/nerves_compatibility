defmodule Portal.Catalog.SkipReasonsTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.SkipReasons

  defp c(class, detail \\ nil, blocker \\ nil),
    do: %{class: class, detail: detail, blocker: blocker}

  defp samples,
    do: [
      {"portability could not be judged", c(:could_not_judge)},
      {"portability could not be judged (transient 5 times)", c(:could_not_judge)},
      {"closure dependency observed the host: hackney (rebar3 build runs post_hooks)",
       c(:build_hooks, "post_hooks", "hackney")},
      {"reads the target or ships native code", c(:native_code)},
      {"no compiled beams", c(:no_beams)},
      {"compile-time host read: os:getenv/1 (GITHUB_ACTIONS) (dispatcher stack, first frame erl_eval)",
       c(:env_read, "GITHUB_ACTIONS")},
      {"closure dependency observed the host: file_system (compile-time host read in mix.exs: " <>
         "os:type/0 sets aliases (/work/proj/deps/file_system/mix.exs:47))",
       c(:host_read, "os:type/0", "file_system")},
      {"calls erlang:load_nif/2", c(:native_code, "erlang:load_nif/2")},
      {"closure dependency observed the host: quic (rebar3 build runs pre_hooks)",
       c(:build_hooks, "pre_hooks", "quic")},
      {"nerves-specific source", c(:nerves_specific)},
      {"rebar3 build evaluates rebar.config.script", c(:build_hooks, "rebar.config.script")},
      {"closure dependency observed the host: membrane_core (compile-time host read in mix.exs: " <>
         "os:getenv/1 mix.exs evaluates code dynamically (/work/proj/deps/membrane_core/mix.exs:12))",
       c(:env_read, nil, "membrane_core")},
      {"closure dependency observed the host: ex_cldr (compile-time Elixir patch dependence: " <>
         "System.version/0 project/0 is not a keyword list literal (/work/proj/deps/ex_cldr/mix.exs:9))",
       c(:elixir_version, "System.version/0", "ex_cldr")},
      {"compile-time host read: os:getenv/1 (REBAR_DEPS) (dispatcher stack, first frame rebar_utils)",
       c(:env_read, "REBAR_DEPS")},
      {"compile-time host read: os:getenv/1 (dispatcher stack, first frame erl_eval)",
       c(:env_read)},
      {"rebar3 build uses platform_define", c(:build_hooks, "platform_define")},
      {"compile-time host read: erlang:system_info/1 (schedulers_online) " <>
         "(lineage stack, first frame Elixir.Module.ParallelChecker)",
       c(:host_read, "erlang:system_info/1 (schedulers_online)")},
      {"calls natively built dependency at compile time: Igniter.Mix.Task.MACRO-__using__/2",
       c(:native_code, "Igniter.Mix.Task.MACRO-__using__/2")},
      {"closure dependency observed the host: certifi (compile-time host read: os:getenv/1 " <>
         "(CERTIFI_EMBED) in certifi_pt.embedded/1 (/work/proj/deps/certifi/src/certifi_pt.erl:20))",
       c(:env_read, "CERTIFI_EMBED", "certifi")}
    ]

  test "every production reason shape" do
    for {reason, expected} <- samples() do
      assert SkipReasons.classify(reason) == expected, reason
    end
  end

  test "the other worker shapes" do
    assert SkipReasons.classify("rebar3 build runs provider_hooks") ==
             c(:build_hooks, "provider_hooks")

    assert SkipReasons.classify("calls a NIF or port driver") == c(:native_code)
    assert SkipReasons.classify("compile-time native library load: /x/y.so").class == :native_code
    assert SkipReasons.classify("calls os:cmd/1") == c(:other, "os:cmd/1")
    assert SkipReasons.classify("beam scan incomplete") == c(:could_not_judge)

    assert SkipReasons.classify("compile-time host read: application:get_env/2 (ssl) is read") ==
             c(:host_read, "application:get_env/2 (ssl)")
  end

  test "nil and unknown reasons are :other" do
    assert SkipReasons.classify(nil) == c(:other)
    assert SkipReasons.classify("") == c(:other)
    assert SkipReasons.classify("something new") == c(:other)

    assert SkipReasons.classify("compile-time write outside ebin: file:write_file/2 x") ==
             c(:other)

    # A closure taint whose inner reason is unknown still names its blocker.
    assert SkipReasons.classify("closure dependency observed the host: foo (bar)") ==
             c(:other, nil, "foo")
  end

  test "every class has a label" do
    for class <- SkipReasons.classes(), do: assert(is_binary(SkipReasons.label(class)))
  end
end
