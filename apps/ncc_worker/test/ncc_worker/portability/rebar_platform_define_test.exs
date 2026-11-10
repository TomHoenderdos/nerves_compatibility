defmodule NccWorker.Portability.RebarPlatformDefineTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.Rebar

  @refusal {:refuse, "rebar3 build uses platform_define"}

  defp check(config, parents \\ []) do
    Rebar.check_sources(
      %{config: config, script?: false},
      Enum.map(parents, &%{config: &1, script?: false}),
      nil
    )
  end

  # `regex` is Erlang source text: a "string" (charlist) or a <<"binary">>.
  defp define(regex), do: ~s({erl_opts, [{platform_define, #{regex}, 'X'}]}.\n)

  test "a regex that can consume only the leading OTP major is accepted" do
    for regex <- [
          ~s("^2"),
          ~s{"^(1[89]|2)"},
          ~s("^R1[4-6]"),
          ~s(<<"^2">>),
          ~s{<<"^(1[89]|2)">>},
          ~s("^[0-9][0-9]")
        ] do
      assert check(define(regex)) == :ok, regex
    end

    assert check(~s({erl_opts, [{platform_define, "^2", 'X', true}]}.\n)) == :ok
  end

  test "anything that can see past the major, or is not a regex string, keeps refusing" do
    for regex <- [
          ~s("^28\\\\.1"),
          ~s("alpine"),
          ~s("musl"),
          ~s("darwin2[5-9]"),
          ~s("^28-x86"),
          ~s("^2.*linux"),
          ~s("^2$"),
          ~s("^2+"),
          ~s("^(2"),
          ~s("^[^0]"),
          ~s('atom'),
          ~s(42)
        ] do
      assert check(define(regex)) == @refusal, regex
    end

    assert check(~s({erl_opts, [{platform_define, "^2"}]}.\n)) == @refusal
    assert check(define(~s("^2")) <> define(~s("musl"))) == @refusal
  end

  test "a define a rebar3 parent's overrides inject is held to the same rule" do
    good = ~s({overrides, [{add, [{erl_opts, [{platform_define, "^2", 'X'}]}]}]}.\n)
    bad = ~s({overrides, [{add, [{erl_opts, [{platform_define, "musl", 'X'}]}]}]}.\n)
    assert check("{erl_opts, []}.\n", [good]) == :ok
    assert check("{erl_opts, []}.\n", [bad]) == @refusal
  end
end
