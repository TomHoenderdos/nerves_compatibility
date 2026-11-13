defmodule NccWorker.Portability.ElixirVersionTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.ElixirVersion

  @built "1.19.5"
  @prefix "compile-time Elixir patch dependence: "

  defp ev(mfa, args \\ nil, opts \\ []) do
    arg =
      case args do
        {l, r} -> %{"left" => ~s("#{l}"), "right" => ~s("#{r}")}
        nil -> %{}
      end

    %{
      "mfa" => mfa,
      "arg" => arg,
      "module" => "Elixir.Pkg",
      "file" => "lib/pkg.ex",
      "line" => 4,
      "first" => "Elixir.Pkg",
      "first_kind" => Keyword.get(opts, :kind, "user"),
      "extent" => "frame"
    }
  end

  defp obs(owner, item), do: {owner, {:observe, "elixir_version", item}}
  defp read(opts \\ []), do: ev("System.version/0", nil, opts)
  defp match(req), do: ev("Version.match?/2", {@built, req})
  defp judge(decided, built \\ @built), do: ElixirVersion.judge(decided, built)

  test "a read compared at a minor boundary passes" do
    assert %{refusals: [], problems: []} =
             judge([obs("pkg", read()), obs("pkg", match(">= 1.19.0"))])

    assert %{refusals: []} = judge([obs("pkg", read()), obs("pkg", match("~> 1.18"))])

    assert %{refusals: []} =
             judge([obs("pkg", read()), obs("pkg", match(">= 1.18.0 and < 1.20.0"))])
  end

  test "a threshold above the built patch refuses" do
    assert %{refusals: [{"pkg", {:refuse, @prefix <> "Version.match?/2" <> rest}}]} =
             judge([obs("pkg", read()), obs("pkg", match(">= 1.19.6"))])

    assert rest == " (1.19.5, >= 1.19.6) in Pkg (lib/pkg.ex:4)"
  end

  test "an exact-patch requirement refuses, a minor-pinned one passes" do
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", match("== 1.19.5"))])
    assert %{refusals: []} = judge([obs("pkg", read()), obs("pkg", match("~> 1.19.0"))])
  end

  test "a read with no Version comparison refuses (a string compare)" do
    assert %{refusals: [{"pkg", {:refuse, reason}}]} = judge([obs("pkg", read())])
    assert reason =~ "System.version/0 read without a patch-invariant Version comparison"
  end

  test "two reads need two comparisons" do
    decided = [obs("pkg", read()), obs("pkg", read()), obs("pkg", match(">= 1.19.0"))]
    assert %{refusals: [{"pkg", _}]} = judge(decided)
  end

  test "Version.compare/2 against the built version is judged the same way" do
    ok = ev("Version.compare/2", {@built, "1.18.0"})
    bad = ev("Version.compare/2", {@built, "1.19.7"})
    flipped = ev("Version.compare/2", {"1.19.7", @built})

    assert %{refusals: []} = judge([obs("pkg", read()), obs("pkg", ok)])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", bad)])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", flipped)])
  end

  test "System.build_info/0 refuses; Version.match?/3 is never invariant" do
    assert %{refusals: [{"pkg", {:refuse, @prefix <> "System.build_info/0" <> _}}]} =
             judge([obs("pkg", ev("System.build_info/0"))])

    m3 = ev("Version.match?/3", {@built, ">= 1.0.0"})
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", m3)])
  end

  test "an argument that is not a literal string or does not parse refuses" do
    unquoted = %{ev("Version.match?/2") | "arg" => %{"left" => ~s("#{@built}"), "right" => nil}}
    bad_req = match("not a requirement")

    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", unquoted)])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", bad_req)])

    struct = %{ev("Version.match?/2") | "arg" => %{"left" => nil, "right" => ~s(">= 1.0.0")}}
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", struct)])
  end

  test "comparisons that do not involve the built version are not counted" do
    other = ev("Version.match?/2", {"1.0.0", ">= 0.1.0"})
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", other)])
    assert %{refusals: []} = judge([obs("pkg", other)])
  end

  test "each window is judged alone" do
    decided = [
      obs("dep", read()),
      obs("dep", match(">= 1.19.9")),
      obs("pkg", read()),
      obs("pkg", match(">= 1.19.0"))
    ]

    assert %{refusals: [{"dep", {:refuse, @prefix <> _}}]} = judge(decided)
  end

  test "the toolchain's own reads do not count; glue, none and a missing kind do" do
    assert %{refusals: [], problems: []} = judge([obs("pkg", read(kind: "toolchain"))])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read(kind: "glue"))])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read(kind: "none"))])
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", Map.delete(read(), "first_kind"))])
  end

  test "other observations are not judged here" do
    other = {"pkg", {:observe, "config_reads", %{"mfa" => "application:get_env/2"}}}
    assert %{refusals: [], problems: []} = judge([other, {"pkg", :ignore}])
  end

  test "a pre-release build is checked against itself and every final patch" do
    built = "1.20.0-rc.1"
    ok = ev("Version.match?/2", {built, ">= 1.20.0-rc.0"})
    bad = ev("Version.match?/2", {built, ">= 1.20.0"})
    assert %{refusals: []} = judge([obs("pkg", read()), obs("pkg", ok)], built)
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", bad)], built)
  end

  test "a build past the last listed patch is still checked against a later one" do
    built = "1.19.100"
    bad = ev("Version.match?/2", {built, ">= 1.19.101"})
    assert %{refusals: [{"pkg", _}]} = judge([obs("pkg", read()), obs("pkg", bad)], built)
  end

  test "reads to judge with no Elixir version in the trace cannot be judged" do
    assert %{refusals: [], problems: ["no Elixir version in the trace"]} =
             judge([obs("pkg", read())], nil)

    assert %{refusals: [], problems: ["no Elixir version in the trace"]} =
             judge([obs("pkg", read())], "not a version")

    assert %{refusals: [], problems: []} = judge([], nil)
  end

  test "System.build_info/0 refuses even with no Elixir version in the trace" do
    info = obs("pkg", ev("System.build_info/0"))

    assert %{refusals: [{"pkg", {:refuse, @prefix <> "System.build_info/0" <> _}}], problems: []} =
             judge([info], nil)

    assert %{refusals: [{"dep", _}], problems: ["no Elixir version in the trace"]} =
             judge([obs("dep", ev("System.build_info/0")), obs("pkg", read())], "not a version")
  end

  describe "a mix.exs line judged over the whole minor series (series)" do
    defp series(item), do: Map.put(item, "series", true)

    test "a requirement on a minor boundary passes for every patch" do
      for req <- [">= 1.19.0-dev", ">= 1.14.0", "< 1.20.0", "~> 1.15", "~> 1.19"] do
        assert %{refusals: []} =
                 judge([obs("dep", series(read())), obs("dep", series(match(req)))]),
               req
      end

      compare = series(ev("Version.compare/2", {@built, "1.20.0-dev"}))
      assert %{refusals: []} = judge([obs("dep", series(read())), obs("dep", compare)])
    end

    # Invariant from the built patch on, so a lib-code read passes, but not
    # over the whole series: the toolchain key is the minor.
    test "a requirement that cuts inside the minor refuses" do
      for req <- ["~> 1.19.3", ">= 1.19.2", "< 1.19.1", ">= 1.19.5"] do
        assert %{refusals: []} = judge([obs("dep", read()), obs("dep", match(req))]), req

        assert %{refusals: [{"dep", {:refuse, @prefix <> "Version.match?/2" <> _}}]} =
                 judge([obs("dep", series(read())), obs("dep", series(match(req)))]),
               req
      end
    end

    test "the read still needs its comparison" do
      assert %{refusals: [{"dep", {:refuse, reason}}]} = judge([obs("dep", series(read()))])
      assert reason =~ "System.version/0 read without a patch-invariant Version comparison"
    end
  end
end
