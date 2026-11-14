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

  # What the build records for a regex the major does not decide: the
  # regex string and whether it matched the builder's arch string.
  defp recorded(regex),
    do: %{
      "kind" => "platform_define",
      "regex" => regex,
      "matched" => :re.run(Rebar.arch(), regex, [{:capture, :none}]) == :match
    }

  test "the arch string is rebar_utils:get_arch/0's" do
    major = :erlang.system_info(:otp_release) |> List.to_string()
    file = Path.join([:code.root_dir(), "releases", major, "OTP_VERSION"])
    full = file |> File.read!() |> String.trim_trailing("\n") |> String.trim_trailing("**")
    sys = :erlang.system_info(:system_architecture) |> List.to_string()
    words = Integer.to_string(8 * :erlang.system_info({:wordsize, :external}))
    assert Rebar.arch() == "#{full}-#{sys}-#{words}"
  end

  test "a branch that might match depending on what follows the major is recorded, not refused" do
    for {source, regex} <- [
          {~s("^#{@major}\\\\.1"), "^#{@major}\\.1"},
          {~s("^#{@major}-x86"), "^#{@major}-x86"},
          {~s("^#{@major}\\\\."), "^#{@major}\\."},
          {~s("^2[7-9]\\\\."), "^2[7-9]\\."},
          {~s("^3|musl"), "^3|musl"},
          {~s("19"), "19"},
          {~s("18|19"), "18|19"},
          {~s{"(R12|R13|R14|R15|R16|17)"}, "(R12|R13|R14|R15|R16|17)"},
          # hackney 4.x
          {~s("R14"), "R14"},
          {~s("^2+?"), "^2+?"},
          {~s("^2{"), "^2{"},
          {~s("^2{x}"), "^2{x}"},
          {~s("^1[8|9]"), "^1[8|9]"},
          {~s{"^1|(?#x)^2"}, "^1|(?#x)^2"},
          {~s{"(*UTF)^2"}, "(*UTF)^2"},
          {~s("^3||^2x"), "^3||^2x"},
          {~s("^1\\\\Q|^2"), "^1\\Q|^2"},
          {~s("^1|^2\\\\c|"), "^1|^2\\c|"},
          {~s("alpine"), "alpine"},
          {~s("darwin2[5-9]"), "darwin2[5-9]"},
          {~s("^2.*linux"), "^2.*linux"},
          {~s("^2$"), "^2$"},
          {~s("^[^0]"), "^[^0]"},
          {~s("^[0-9.]"), "^[0-9.]"},
          {~s("^\\\\d"), "^\\d"},
          {~s(<<"musl">>), "musl"}
        ] do
      assert check(define(source)) == {:inputs, [recorded(regex)]}, source
    end

    # The builder's own arch string matches its own pieces.
    sys = :erlang.system_info(:system_architecture) |> List.to_string()
    assert {:inputs, [%{"matched" => true}]} = check(define(inspect(sys)))
    assert {:inputs, [%{"matched" => false}]} = check(define(~s("R14")))

    # Several, each once, in order; decided ones are not recorded.
    assert check(
             define(~s("musl")) <> define(~s("^2")) <> define(~s("R14")) <> define(~s("musl"))
           ) ==
             {:inputs, [recorded("musl"), recorded("R14")]}
  end

  test "a regex re cannot compile, or that is not ASCII, records config_unrecorded" do
    for source <- [~s("^(2"), ~s("^[9-0]"), ~s("\\x{e9}")] do
      assert check(define(source)) == {:inputs, [%{"kind" => "config_unrecorded"}]}, source
    end
  end

  test "a define that is not a regex string, or not a define tuple, keeps refusing" do
    for regex <- [~s('atom'), ~s(42), ~s({x})] do
      assert check(define(regex)) == @refusal, regex
    end

    assert check(~s({erl_opts, [{platform_define, "^2"}]}.\n)) == @refusal
    assert check(define(~s('atom')) <> define(~s("musl"))) == @refusal
  end

  test "a define a rebar3 parent's overrides inject is held to the same rule" do
    good = ~s({overrides, [{add, [{erl_opts, [{platform_define, "^2", 'X'}]}]}]}.\n)
    other = ~s({overrides, [{add, [{erl_opts, [{platform_define, "musl", 'X'}]}]}]}.\n)
    bad = ~s({overrides, [{add, [{erl_opts, [{platform_define, 42, 'X'}]}]}]}.\n)
    assert check("{erl_opts, []}.\n", [good]) == :ok
    assert check("{erl_opts, []}.\n", [other]) == {:inputs, [recorded("musl")]}
    assert check("{erl_opts, []}.\n", [bad]) == @refusal
  end
end
