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

    # The Elixir install's byte order, not the VM's: no client checks it.
    assert %{refusals: [{"dep", {:refuse, @prefix <> "System.compiled_endianness/0" <> _}}]} =
             judge([obs("dep", ev("System.compiled_endianness/0"))])

    assert %{refusals: [{"pkg", _}], problems: []} =
             judge([obs("pkg", ev("System.compiled_endianness/0"))], "not a version")

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

  describe "the reviewed toolshed 0.5.0 read" do
    @toolshed_sum "44a39f384d813d1991c4637eca23f62e9f91135e496c868c400b42ed01eb51d2"

    defp toolshed_read(overrides \\ %{}) do
      Map.merge(
        %{
          "mfa" => "System.version/0",
          "arg" => %{},
          "module" => "elixir_compiler_9",
          "file" => "lib/toolshed.ex",
          "line" => 13,
          "first" => "elixir_compiler_9",
          "first_kind" => "user",
          "extent" => "frame"
        },
        overrides
      )
    end

    defp release(version \\ "0.5.0", sum \\ @toolshed_sum),
      do: %{"toolshed" => %{name: "toolshed", version: version, checksum: sum}}

    defp verified, do: %{"toolshed" => {:ok, %{"lib/toolshed.ex" => "x"}}}

    defp reviewed(releases \\ release(), trees \\ verified()),
      do: ElixirVersion.reviewed_apps(releases, trees)

    defp judge_toolshed(items, built \\ @built, apps \\ reviewed()),
      do: ElixirVersion.judge(Enum.map(items, &obs("toolshed", &1)), built, apps)

    test "passes on every patch and pre-release of 1.19 and 1.20" do
      assert Map.keys(reviewed()) == ["toolshed"]

      for minor <- ["1.19", "1.20"], p <- [0, 5, 9, 10, 99], suffix <- ["", "-rc.0", "-dev"] do
        built = "#{minor}.#{p}#{suffix}"
        assert %{refusals: [], problems: []} = judge_toolshed([toolshed_read()], built), built
      end
    end

    test "any other checksum, version or an unverified tree refuses" do
      for apps <- [
            reviewed(release("0.5.0", String.duplicate("0", 64))),
            reviewed(release("0.4.2")),
            reviewed(release(), %{"toolshed" => {:unverified, "no verified tarball"}}),
            reviewed(release(), %{"toolshed" => {:differs, "modified file lib/toolshed.ex"}}),
            reviewed(release(), %{}),
            %{}
          ] do
        assert apps == %{}

        assert %{refusals: [{"toolshed", {:refuse, reason}}]} =
                 judge_toolshed([toolshed_read()], @built, apps)

        assert reason =~ "System.version/0 read without a patch-invariant Version comparison"
      end
    end

    test "another app, file, line or frame kind refuses" do
      other = ElixirVersion.judge([obs("pkg", toolshed_read())], @built, reviewed())
      assert %{refusals: [{"pkg", _}]} = other

      for overrides <- [
            %{"file" => "lib/toolshed/cmd.ex"},
            %{"line" => 14},
            %{"first_kind" => "none"},
            %{"module" => "Elixir.Toolshed"},
            %{"mfa" => "System.build_info/0"}
          ] do
        assert %{refusals: [{"toolshed", _}]} =
                 judge_toolshed([toolshed_read(overrides)]),
               inspect(overrides)
      end
    end

    test "a second read in the window refuses" do
      assert %{refusals: [{"toolshed", _}]} =
               judge_toolshed([toolshed_read(), toolshed_read()])

      assert %{refusals: [{"toolshed", _}]} =
               judge_toolshed([toolshed_read(), toolshed_read(%{"line" => 40})])
    end

    # `>= "1.16"` is decided by the "x.y." prefix every patch of a minor
    # shares, so it cannot flip inside one; the judge still evaluates it
    # over the built minor, and a trace with no usable version is not judged.
    test "a trace with no usable Elixir version is not judged" do
      assert %{refusals: [], problems: ["no Elixir version in the trace"]} =
               judge_toolshed([toolshed_read()], "not a version")
    end

    test "every other observation of the window is still judged" do
      bad = ev("Version.match?/2", {@built, ">= 1.19.6"})

      assert %{refusals: [{"toolshed", {:refuse, @prefix <> "Version.match?/2" <> _}}]} =
               judge_toolshed([toolshed_read(), bad])
    end
  end

  # The System.version/0 reads of six releases whose beams do not depend on
  # the patch, as the real traces of 1.19.5 and 1.20.5 name them. Each reads
  # the version through `Version.parse!/1` (a struct the count rule cannot
  # take, rightly: croma and serum keep such a struct in a module attribute
  # their functions bake) or through its fields.
  describe "the reviewed reads of toml, dialyxir, benchee, timex, moar and wallaby" do
    @struct ~s("\#{major => 1,minor => 19,build => nil,'__struct__' => 'Elixir.Version',pre => [],patch => 5}")
    @v1_17 ~s("\#{major => 1,minor => 17,build => nil,'__struct__' => 'Elixir.Version',pre => [],patch => 0}")
    @rc ~s("\#{major => 1,minor => 5,build => nil,'__struct__' => 'Elixir.Version',pre => [<<\"rc\">>,1],patch => 0}")

    @releases %{
      "toml" => {"0.7.0", "0690246a2478c1defd100b0c9b89b4ea280a22be9a7b313a8a058a2408a2fa70"},
      "dialyxir" => {"1.4.9", "1c049c22b47680f4fff78ed0b0fe377073a762e96af153fdfe28bf00131de76d"},
      "benchee" => {"1.5.1", "a539301f8dfd4efc5c5123bfb9d47ebde20092a863a5b5b16c2a60d2243dfce7"},
      "timex" => {"3.1.25", "218b5ac7fd7e6a6ced68d91e9d57de3ab79c5e57b0c677ed3f024ccbb0021391"},
      "moar" => {"5.0.1", "f0448ac83d02ebd46b134faa22d6102f4a963f8bf285411dec94b3863a366a78"},
      "wallaby" => {"0.31.0", "a3e7a5f13c1db49d32c17dafe8d4654fe556987efd12d422673b902455871c50"}
    }

    defp site(mfa, file, line, kind, arg \\ %{}) do
      %{
        "mfa" => mfa,
        "arg" => arg,
        "module" => "elixir_compiler_7",
        "file" => file,
        "line" => line,
        "first" => "elixir_compiler_7",
        "first_kind" => kind,
        "extent" => "frame"
      }
    end

    defp version_read(file, line, kind \\ "user"),
      do: site("System.version/0", file, line, kind)

    # The observations each release's own window holds, as traced.
    defp traced("toml") do
      [
        version_read("lib/provider.ex", 49),
        site("Version.match?/2", "lib/provider.ex", 49, "user", %{
          "left" => @struct,
          "right" => ~s(">= 1.9.0")
        })
      ]
    end

    defp traced("dialyxir") do
      [
        version_read("lib/dialyxir/project.ex", 467),
        version_read("lib/mix/tasks/dialyzer.ex", 350),
        site("Version.match?/2", "lib/mix/tasks/dialyzer.ex", 350, "user", %{
          "left" => ~s("#{@built}"),
          "right" => ~s(">= 1.15.0")
        })
      ]
    end

    # benchee's `defmacrop compatible_stacktrace` runs through erl_eval while
    # `start_runner/2` (line 56) expands it: glue first, its module body the
    # user frame.
    defp traced("benchee") do
      [
        version_read("lib/benchee/benchmark/collect/memory.ex", 56, "glue"),
        site("Version.match?/2", "lib/benchee/benchmark/collect/memory.ex", 56, "glue", %{
          "left" => @struct,
          "right" => ~s("~> 1.7")
        }),
        version_read("lib/benchee/profile.ex", 31),
        site("Version.match?/2", "lib/benchee/profile.ex", 31, "user", %{
          "left" => ~s("#{@built}"),
          "right" => ~s(">= 1.17.0")
        })
      ]
    end

    defp traced("timex") do
      [
        version_read("lib/datetime/inspect.ex", 15),
        site("Version.compare/2", "lib/datetime/inspect.ex", 15, "user", %{
          "left" => @struct,
          "right" => @rc
        })
      ]
    end

    # moar's `defmacrop at_time`, expanded by erl_eval in `at/2` (line 70).
    defp traced("moar") do
      [
        version_read("lib/datetime.ex", 70, "glue"),
        site("Version.compare/2", "lib/datetime.ex", 70, "glue", %{
          "left" => @struct,
          "right" => @v1_17
        }),
        version_read("lib/file.ex", 31),
        site("Version.compare/2", "lib/file.ex", 31, "user", %{
          "left" => ~s("#{@built}"),
          "right" => ~s("1.16.0")
        })
      ]
    end

    # `Version.parse!(System.version()).minor`: no Version call at all.
    defp traced("wallaby"), do: [version_read("lib/wallaby/selenium.ex", 382)]

    defp locked(app, overrides \\ []) do
      {version, sum} = @releases[app]
      version = Keyword.get(overrides, :version, version)
      sum = Keyword.get(overrides, :checksum, sum)
      %{app => %{name: app, version: version, checksum: sum}}
    end

    defp tree(app), do: %{app => {:ok, %{"mix.exs" => "x"}}}

    defp judge_app(app, items, built \\ @built, reviewed \\ nil) do
      reviewed = reviewed || ElixirVersion.reviewed_apps(locked(app), tree(app))
      ElixirVersion.judge(Enum.map(items, &obs(app, &1)), built, reviewed)
    end

    test "each release's own reads pass on every patch and pre-release of 1.19 and 1.20" do
      for {app, _} <- @releases,
          minor <- ["1.19", "1.20"],
          p <- [0, 3, 5, 99],
          suffix <- ["", "-rc.0", "-dev"] do
        built = "#{minor}.#{p}#{suffix}"

        assert %{refusals: [], problems: []} = judge_app(app, traced(app), built),
               "#{app} #{built}"
      end
    end

    test "without the reviewed release the same reads still refuse" do
      for {app, _} <- @releases do
        none = ElixirVersion.reviewed_apps(%{}, %{})

        wrong_sum =
          ElixirVersion.reviewed_apps(locked(app, checksum: String.duplicate("0", 64)), tree(app))

        other_version = ElixirVersion.reviewed_apps(locked(app, version: "0.0.1"), tree(app))
        changed = ElixirVersion.reviewed_apps(locked(app), %{app => {:differs, "modified file"}})

        for reviewed <- [none, wrong_sum, other_version, changed] do
          assert reviewed == %{}

          assert %{refusals: [{^app, {:refuse, reason}}]} =
                   judge_app(app, traced(app), @built, reviewed)

          assert reason =~ "System.version/0 read without a patch-invariant Version comparison"
        end
      end
    end

    # The shape alone is never enough: a fork with the same file and line
    # (gsmlg_toml, tomler) or croma's struct compare refuse as before.
    test "the same observations in another app refuse" do
      reviewed = ElixirVersion.reviewed_apps(locked("toml"), tree("toml"))

      for app <- ["gsmlg_toml", "tomler", "croma"] do
        assert %{refusals: [{^app, _}]} =
                 ElixirVersion.judge(Enum.map(traced("toml"), &obs(app, &1)), @built, reviewed)
      end
    end

    test "a read at any other site, a repeated or a missing site refuses" do
      extra = version_read("lib/toml.ex", 10)

      for app <- Map.keys(@releases) do
        assert %{refusals: [{^app, _}]} = judge_app(app, traced(app) ++ [extra]), app

        [first | _] = Enum.filter(traced(app), &(&1["mfa"] == "System.version/0"))
        assert %{refusals: [{^app, _}]} = judge_app(app, traced(app) ++ [first]), app
      end

      # With its plain `Version.match?/2` site gone, the window is not the
      # reviewed one, and the struct site is judged by the count rule alone.
      for {app, plain} <- [
            {"dialyxir", "lib/mix/tasks/dialyzer.ex"},
            {"benchee", "lib/benchee/profile.ex"}
          ] do
        items = Enum.reject(traced(app), &(&1["file"] == plain))
        assert %{refusals: [{^app, _}]} = judge_app(app, items), app
      end
    end

    test "a site read from another frame kind or outside a module body refuses" do
      for app <- Map.keys(@releases) do
        items = traced(app)
        read = Enum.find(items, &(&1["mfa"] == "System.version/0"))

        for overrides <- [
              %{"first_kind" => "none"},
              %{"first_kind" => if(read["first_kind"] == "glue", do: "user", else: "glue")},
              %{"module" => "Elixir.Toml.Provider"},
              %{"line" => read["line"] + 1},
              %{"file" => "lib/other.ex"}
            ] do
          changed =
            List.replace_at(
              items,
              Enum.find_index(items, &(&1 == read)),
              Map.merge(read, overrides)
            )

          assert %{refusals: [{^app, _}]} = judge_app(app, changed),
                 "#{app} #{inspect(overrides)}"
        end
      end
    end

    # benchee's `>= 1.17.0` and dialyxir's `>= 1.15.0` cut a minor's
    # pre-releases from its finals: on that minor they are not invariant.
    test "a reviewed comparison is evaluated again over the built minor" do
      assert %{refusals: [{"benchee", _}]} = judge_app("benchee", traced("benchee"), "1.17.3")
      assert %{refusals: [{"dialyxir", _}]} = judge_app("dialyxir", traced("dialyxir"), "1.15.2")
      assert %{refusals: []} = judge_app("dialyxir", traced("dialyxir"), "1.16.2")
    end

    test "every other comparison of the window is still judged" do
      bad = ev("Version.match?/2", {@built, ">= 1.19.6"})

      for app <- Map.keys(@releases) do
        assert %{refusals: [{^app, {:refuse, @prefix <> "Version.match?/2" <> _}}]} =
                 judge_app(app, traced(app) ++ [bad]),
               app
      end
    end
  end
end
