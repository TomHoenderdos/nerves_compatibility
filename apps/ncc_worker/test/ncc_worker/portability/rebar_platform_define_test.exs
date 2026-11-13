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

    # `^` and `^()` always define: a start anchor with nothing, or an
    # anchored empty group, matches at the start of every string, so both
    # probes agree and the result is the same on every host.
    for regex <- [~s("^"), ~s{"^()"}] do
      assert check(define(regex)) == :ok, regex
    end
  end

  # The builder's OTP major: rebar3 matches `<OTP_VERSION>-<arch>-<words>`
  # (`rebar_utils:get_arch/0`), so every major-relative case is written
  # from it.
  @major :erlang.system_info(:otp_release) |> List.to_string()

  test "quantifiers and top-level alternation are decided branch by branch" do
    # On an OTP 2x builder: a branch that always matches decides, and so do
    # branches that all never match, whatever follows the part they consume.
    for regex <- [
          ~s("^2+"),
          ~s("^[0-9]+"),
          ~s("^2[0-9]{1}"),
          ~s("^2{1,2}"),
          ~s("^2[0-9]*"),
          ~s("^19.|^2"),
          ~s("18|19|^2"),
          ~s("^2|musl"),
          ~s("^R|^1"),
          ~s{"^(1|(20))"},
          ~s{"^(R|1|20)"},
          ~s("^1[0-9]\\\\.|^R1"),
          ~s("^20\\\\.3"),
          # tls_certificate_check 1.32.2
          ~s("^23\\\\.[1-3]"),
          ~s("^2[4-9]"),
          ~s("^[3-9]"),
          ~s("^22\\\\."),
          ~s("^23\\\\.[0-2][^0-9]"),
          ~s("^2[3-6]\\\\."),
          ~s("^#{String.to_integer(@major) - 1}\\\\.[0-2]\\\\."),
          ~s("^#{String.to_integer(@major) + 1}\\\\.")
        ] do
      assert check(define(regex)) == :ok, regex
    end
  end

  test "a branch that might match depending on what follows the major keeps refusing" do
    for regex <- [
          ~s("^#{@major}\\\\.1"),
          ~s("^#{@major}-x86"),
          ~s("^#{@major}\\\\."),
          ~s("^2[7-9]\\\\."),
          ~s("^3|musl"),
          ~s("19"),
          ~s("18|19"),
          ~s{"(R12|R13|R14|R15|R16|17)"},
          ~s("R14"),
          ~s("^2+?"),
          ~s("^2{"),
          ~s("^2{x}"),
          ~s("^1[8|9]"),
          ~s("^1\\\\Q|^2"),
          ~s{"^1|(?#x)^2"},
          ~s{"(*UTF)^2"},
          ~s("^1|^2\\\\c|"),
          ~s("^3||^2x")
        ] do
      assert check(define(regex)) == @refusal, regex
    end
  end

  test "anything that can see past the major, or is not a regex string, keeps refusing" do
    for regex <- [
          ~s("^#{@major}\\\\.1"),
          ~s("alpine"),
          ~s("musl"),
          ~s("darwin2[5-9]"),
          ~s("^#{@major}-x86"),
          ~s("^2.*linux"),
          ~s("^2$"),
          ~s("^(2"),
          ~s("^[^0]"),
          ~s('atom'),
          ~s(42),
          # Passes the grammar (a digit range inside `[...]`) but fails
          # `Regex.compile/1` (descending range), exercising the
          # compile-failure branch `"^(2"` never reaches.
          ~s("^[9-0]"),
          # Top-level alternation: no branch always matches and `musl`
          # drops the `^` anchor.
          ~s("^3|musl"),
          ~s("^[0-9.]"),
          ~s("^\\\\d")
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
