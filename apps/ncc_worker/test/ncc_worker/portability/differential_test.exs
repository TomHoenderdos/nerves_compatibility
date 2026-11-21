defmodule NccWorker.Portability.DifferentialTest do
  # `Differential.hold/2` and `settle/6` with the variant builds, the digest
  # and the script check stubbed: what each outcome makes of a held verdict.
  # The real compiles are `NccWorker.Tracer.FixturesDifferentialTest`'s.
  use ExUnit.Case, async: true

  alias Compatibility.Portability, as: Reasons
  alias NccWorker.Portability.Differential

  @moduletag :tmp_dir

  @sched %{
    "mfa" => "erlang:system_info/1",
    "arg" => %{"key" => "schedulers_online"},
    "read" => "schedulers",
    "owner" => "pkg",
    "refusal" =>
      "compile-time host read: erlang:system_info/1 (schedulers_online) in Pkg.__MODULE__/1 (lib/pkg.ex:2)"
  }

  @plain %{
    "mfa" => "init:get_plain_arguments/0",
    "arg" => %{},
    "read" => "plain_args",
    "owner" => "outside",
    "refusal" =>
      "compile-time host read: init:get_plain_arguments/0 (dispatcher stack, first frame erl_eval)"
  }

  setup %{tmp_dir: dir} do
    root = Path.join(dir, "proj/_build/host")
    build = Path.join(root, "lib/pkg")
    File.mkdir_p!(Path.join(build, "ebin"))
    File.write!(Path.join(build, "ebin/pkg.app"), "{application,pkg,[]}.\n")
    File.write!(Path.join(build, "ebin/x.beam"), "same")

    pass = %{
      status: :pass,
      reason: nil,
      observations: %{"problems" => [], "trace_stats" => %{"judge_compile" => "finished"}},
      compile_env: [],
      compile_inputs: [%{"kind" => "os_type", "family" => "unix"}],
      built_priv: [],
      manager: "mix"
    }

    varied = %{
      reads: [@sched],
      build: build,
      trees: %{"pkg" => {:ok, %{"lib/pkg.ex" => "sha"}}},
      scripts: []
    }

    %{dir: dir, root: root, build: build, pass: pass, varied: varied}
  end

  defp held(ctx, reads \\ nil, scripts \\ []) do
    Differential.hold(ctx.pass, %{ctx.varied | reads: reads || ctx.varied.reads, scripts: scripts})
  end

  # A variant build that writes `files` (`rel => bytes`) into its own ebin
  # and returns `verdict`, reporting its opts.
  defp variant(
         files \\ %{"pkg.app" => "{application,pkg,[]}.\n", "x.beam" => "same"},
         verdict \\ :held
       ) do
    fn _project, "pkg", opts ->
      assert opts[:differential] == :variant
      assert opts[:priv_repro] == false
      assert opts[:mode] == :judge
      assert opts[:trees] == %{"pkg" => {:ok, %{"lib/pkg.ex" => "sha"}}}
      {"MIX_BUILD_PATH", path} = List.keyfind(opts[:env], "MIX_BUILD_PATH", 0)
      send(self(), {:variant, path, opts})

      for {rel, bytes} <- files do
        file = Path.join([path, "lib/pkg/ebin", rel])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, bytes)
      end

      case verdict do
        :held -> held_variant()
        other -> other
      end
    end
  end

  defp held_variant do
    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      differential: %{},
      observations: %{
        "problems" => [Differential.hold_problem()],
        "trace_stats" => %{"judge_compile" => "finished"}
      }
    }
  end

  defp settle(held, ctx, run, extra \\ []) do
    # `extra` first: Keyword.get/2 takes the first value.
    opts =
      extra ++
        [
          env: [{"MIX_BUILD_PATH", ctx.root}, {"HOME", "/home/nerves"}],
          differential: true,
          differential_gap_ms: 0
        ]

    digest = Keyword.get(extra, :digest, fn _ -> {:ok, "d"} end)
    Differential.settle(held, Path.join(ctx.dir, "proj"), "pkg", opts, run, digest)
  end

  test "a verdict without varied reads is left as it is", ctx do
    assert Differential.hold(ctx.pass, %{ctx.varied | reads: []}) == ctx.pass
    skip = %{ctx.pass | status: :skip, reason: "compile-time host read: x"}
    assert Differential.hold(skip, ctx.varied) == skip
  end

  test "a pass with varied reads is held until the variants decide", ctx do
    held = held(ctx)
    assert held.status == :skip
    assert held.reason == Reasons.could_not_judge()
    assert held.compile_inputs == nil and held.compile_env == nil
    assert held.observations["problems"] == [Differential.hold_problem()]
    assert held.observations["varied_reads"] == nil or is_list(held.observations["varied_reads"])
  end

  test "the same app in both variants passes, with what it held", ctx do
    v = settle(held(ctx), ctx, variant())

    assert %{status: :pass, reason: nil, compile_env: [], built_priv: []} = v
    assert v.compile_inputs == [%{"kind" => "os_type", "family" => "unix"}]
    assert v.observations["problems"] == []
    assert v.observations["trace_stats"]["differential"] == "same"
    refute Map.has_key?(v, :differential)

    assert %{"reads" => [read], "variants" => ["low", "high"]} = v.observations["differential"]
    assert read["read"] == "schedulers"

    assert_received {:variant, low, low_opts}
    assert_received {:variant, high, high_opts}
    # Each at a root of its own, of the first's length, removed afterwards.
    assert byte_size(low) == byte_size(ctx.root) and byte_size(high) == byte_size(ctx.root)
    assert low != high
    refute File.exists?(low) or File.exists?(high)

    env = fn opts, name -> opts[:env] |> List.keyfind(name, 0) |> elem(1) end
    assert env.(low_opts, "ERL_ZFLAGS") =~ "+S 1:1"
    # A prime, no power of two: parity and a power-of-two test differ from
    # `low`'s 1 and from a builder's usual power-of-two count (review B4).
    assert env.(high_opts, "ERL_ZFLAGS") =~ "+S 251:251"
    # HOME at either side of the first build's `/home/nerves`: shorter, and
    # longer.
    assert byte_size(env.(low_opts, "HOME")) < byte_size("/home/nerves")
    assert byte_size(env.(high_opts, "HOME")) > byte_size("/home/nerves")
    assert env.(high_opts, "HOME") != env.(low_opts, "HOME")
    assert low_opts[:plain_args] == []
    assert "test" in high_opts[:plain_args] and "compile" in high_opts[:plain_args]
  end

  test "a variant whose app differs refuses, naming the read", ctx do
    files = %{"pkg.app" => "{application,pkg,[{n,1}]}.\n", "x.beam" => "same"}
    v = settle(held(ctx), ctx, variant(files))

    assert v.status == :skip

    assert v.reason ==
             @sched["refusal"] <> "; a differential build differs: ebin/pkg.app: differs"

    assert v.observations["trace_stats"]["differential"] == "differs"
    assert v.compile_inputs == nil
    refute Map.has_key?(v, :differential)
  end

  test "a variant that refuses refuses, naming the read and its reason", ctx do
    refused = %{
      status: :skip,
      reason: "compile-time host read: inet:gethostname/0",
      observations: %{"problems" => [], "trace_stats" => %{"judge_compile" => "finished"}}
    }

    v = settle(held(ctx), ctx, variant(%{}, refused))

    assert v.reason ==
             @sched["refusal"] <>
               "; a differential build refused (compile-time host read: inet:gethostname/0)"

    assert v.observations["trace_stats"]["differential"] == "differs"
  end

  test "a variant that did not finish is transient could-not-judge", ctx do
    unfinished = %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      observations: %{
        "problems" => ["tracer: :timeout"],
        "trace_stats" => %{"judge_compile" => "not_finished", "tracer_error" => "timeout"}
      }
    }

    v = settle(held(ctx), ctx, variant(%{}, unfinished))
    assert v.reason == Reasons.could_not_judge()
    assert v.observations["trace_stats"]["differential"] == "not_finished"
    assert Enum.any?(v.observations["problems"], &(&1 =~ "differential build did not finish"))
    refute Differential.hold_problem() in v.observations["problems"]
  end

  test "a first build that changed while the variants ran cannot be judged", ctx do
    counter = :counters.new(1, [])

    digest = fn _ ->
      :counters.add(counter, 1, 1)
      {:ok, "d#{:counters.get(counter, 1)}"}
    end

    v = settle(held(ctx), ctx, variant(), digest: digest)
    assert v.reason == Reasons.could_not_judge()

    assert "the first build changed while the differential builds ran" in v.observations[
             "problems"
           ]
  end

  test "a variant build, a priv repro build and a verdict not held are left as they are", ctx do
    held = held(ctx)
    no_run = fn _, _, _ -> flunk("no variant build") end
    assert settle(held, ctx, no_run, differential: :variant) == held
    assert settle(held, ctx, no_run, priv_repro: false) == held
    assert settle(ctx.pass, ctx, no_run) == ctx.pass
  end

  test "own priv writes held for a second build are not settled together", ctx do
    priv_held =
      ctx.pass
      |> Map.merge(%{status: :skip, reason: Reasons.could_not_judge(), compile_env: nil})
      |> Map.put(:compile_inputs, nil)
      |> Map.put(:priv_repro, %{dir: "x"})
      |> Map.put(:observations, %{"problems" => ["own priv writes wait for a second build"]})

    v = Differential.hold(priv_held, ctx.varied)
    refute Map.has_key?(v, :priv_repro)
    assert v.reason == Reasons.could_not_judge()

    assert "varied host reads and own priv writes are not settled together" in v.observations[
             "problems"
           ]
  end

  test "plain arguments need the script check, which runs first", ctx do
    scripts = [{"gproc", "tarball"}]
    held = held(ctx, [@plain], scripts)

    check = fn [{"gproc", "tarball"}], opts ->
      assert opts[:env]
      send(self(), :script_check)
      {:ok, ["gproc"]}
    end

    v = settle(held, ctx, variant(), script_check: check)
    assert_received :script_check
    assert v.status == :pass
    assert v.observations["differential"]["scripts"] == ["gproc"]

    check = fn _, _ -> {:differs, "gproc", "erl_opts differs with \"test\""} end
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end, script_check: check)

    assert v.reason ==
             @plain["refusal"] <>
               "; gproc's rebar.config.script gives another config: erl_opts differs with \"test\""

    check = fn _, _ -> {:error, "eval failed"} end
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end, script_check: check)
    assert v.reason == Reasons.could_not_judge()
    assert "script check: eval failed" in v.observations["problems"]
  end

  test "a script check refusal names the plain-arguments read, whatever came first", ctx do
    held = held(ctx, [@sched, @plain], [{"gproc", "tarball"}])
    check = fn _, _ -> {:differs, "gproc", "erl_opts differs with \"test\""} end
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end, script_check: check)
    assert String.starts_with?(v.reason, @plain["refusal"] <> "; gproc's rebar.config.script")
  end

  test "plain arguments with no rebar.config.script to settle them refuse", ctx do
    held = held(ctx, [@plain], [])
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end)
    assert v.reason == @plain["refusal"]
    assert v.observations["trace_stats"]["differential"] == "differs"
  end

  test "a first build root too short for a same-length variant root still compares", ctx do
    v =
      settle(held(ctx), ctx, variant(),
        differential_root: Path.join(ctx.dir, String.duplicate("r", 200))
      )

    assert v.status == :pass
  end
end
