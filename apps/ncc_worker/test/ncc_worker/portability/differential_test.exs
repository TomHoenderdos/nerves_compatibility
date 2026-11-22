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
      # A variant runs no relocation builds of its own (S4): a variant that
      # R2 refuses refuses the differential build.
      refute Keyword.has_key?(opts, :relocate)
      assert opts[:mode] == :judge
      assert opts[:trees] == %{"pkg" => {:ok, %{"lib/pkg.ex" => "sha"}}}
      {"MIX_BUILD_PATH", path} = List.keyfind(opts[:env], "MIX_BUILD_PATH", 0)
      send(self(), {:variant, path, opts})

      for {rel, bytes} <- files do
        file = Path.join([path, "lib/pkg/ebin", rel])
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, bytes)
      end

      # The count the variant's VM ran with, as the tracer's start line
      # records it: the one asked for, unless the test says otherwise.
      [_, asked] = Regex.run(~r/\+S (\d+):/, env_of(opts, "ERL_ZFLAGS"))

      case verdict do
        :held -> held_variant()
        other -> other
      end
      |> put_count(String.to_integer(asked))
    end
  end

  defp env_of(opts, name), do: opts[:env] |> List.keyfind(name, 0) |> elem(1)

  defp put_count(%{observations: %{"trace_stats" => %{"schedulers_online" => _}}} = v, _n), do: v

  defp put_count(%{observations: obs} = v, n) do
    stats = Map.put(obs["trace_stats"] || %{}, "schedulers_online", n)
    %{v | observations: Map.put(obs, "trace_stats", stats)}
  end

  defp put_count(v, _n), do: v

  # A variant held for its own varied reads, as `Differential.hold/2` holds
  # one: what it read (`merge`) is the first build's unless a test says so.
  defp held_variant(merge \\ %{}) do
    held =
      Map.merge(
        %{
          compile_inputs: [%{"kind" => "os_type", "family" => "unix"}],
          compile_env: [],
          reads: [@sched]
        },
        Map.take(merge, [:compile_inputs, :compile_env, :reads])
      )

    %{
      status: :skip,
      reason: Reasons.could_not_judge(),
      differential: held,
      observations: %{
        "env_reads" => Map.get(merge, :env_reads, []),
        "config_reads" => Map.get(merge, :config_reads, []),
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
          relocate: true,
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
    # Ruling 5: fresh roots, of random names, made empty and checked so
    # after the container's sweep (`fresh:`).
    assert low_opts[:fresh] == [low] and high_opts[:fresh] == [high]
    assert Path.basename(low) =~ ~r/\Av[0-9a-f]{12}low/
    assert Path.basename(high) =~ ~r/\Av[0-9a-f]{12}high/
    # Each at a root of its own, of the first's length, removed afterwards.
    assert byte_size(low) == byte_size(ctx.root) and byte_size(high) == byte_size(ctx.root)
    assert low != high
    refute File.exists?(low) or File.exists?(high)

    env = fn opts, name -> opts[:env] |> List.keyfind(name, 0) |> elem(1) end
    assert env.(low_opts, "ERL_ZFLAGS") =~ "+S 1:1"
    # Review R3: no busy-waiting schedulers in either variant.
    for opts <- [low_opts, high_opts],
        do: assert(env.(opts, "ERL_ZFLAGS") =~ "+sbwt none +sbwtdcpu none +sbwtdio none")

    # Even, divisible by 2, 3, 4, 5, 6, 8, 10, 12, 15 and 16, no power of
    # two: parity, a power-of-two test and those divisibilities differ from
    # `low`'s 1 (review B4, N3).
    assert env.(high_opts, "ERL_ZFLAGS") =~ "+S 240:240"
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

  # Review B1: a varied value that gates another read. The variant reads
  # what the first build never did; its value is no input the client
  # compares, so the build refuses (coordinator ruling: never add it with
  # the builder's value).
  test "a variant with a compile input the first build lacks refuses", ctx do
    gate = %{"kind" => "env", "name" => "FX_GATE", "set_by" => "host", "value" => "unset"}
    inputs = [%{"kind" => "os_type", "family" => "unix"}, gate]
    v = settle(held(ctx), ctx, variant(%{}, held_variant(%{compile_inputs: inputs})))

    assert v.status == :skip

    assert v.reason ==
             @sched["refusal"] <>
               "; a differential build (low) read what the first did not: env FX_GATE"

    assert v.observations["trace_stats"]["differential"] == "differs"
  end

  test "a variant with a config read the first build lacks refuses", ctx do
    env = [%{app: "pkg", path: ["gate"], value: "g3cFZXJyb3I"}]
    v = settle(held(ctx), ctx, variant(%{}, held_variant(%{compile_env: env})))

    assert v.reason =~
             "; a differential build (low) read what the first did not: config pkg [\"gate\"]"
  end

  test "a variant with an env or config read observed that the first lacks refuses", ctx do
    read = %{"name" => "FX_GATE", "all" => false, "slice_allowed" => true}
    v = settle(held(ctx), ctx, variant(%{}, held_variant(%{env_reads: [read]})))
    assert v.reason =~ "read what the first did not: env read FX_GATE"

    read = %{"arg" => %{"app" => "g3cFZXJyb3I", "key" => "g3cFZXJyb3J"}}
    v = settle(held(ctx), ctx, variant(%{}, held_variant(%{config_reads: [read]})))
    assert v.reason =~ "read what the first did not: config read"
  end

  test "a variant with a varied read the first build lacks refuses", ctx do
    home = %{
      "mfa" => "init:get_argument/1",
      "arg" => %{"name" => "home"},
      "read" => "home",
      "owner" => "pkg",
      "refusal" => "compile-time host read: init:get_argument/1 (home)"
    }

    v = settle(held(ctx), ctx, variant(%{}, held_variant(%{reads: [@sched, home]})))
    assert v.reason =~ "read what the first did not: home in pkg"
  end

  # A module body's read is made by `elixir_compiler_<n>`, numbered in the
  # order the parallel compiler happened to run the bodies, which another
  # scheduler count changes (super_worker 0.11.0): the site is its file and
  # line.
  test "a varied read at the same site in another module body is the same read", ctx do
    site = fn n ->
      Map.merge(@sched, %{"module" => "elixir_compiler_#{n}", "file" => "lib/pkg.ex", "line" => 2})
    end

    held = held(ctx, [site.(8)])
    same = %{"pkg.app" => "{application,pkg,[]}.\n", "x.beam" => "same"}
    v = settle(held, ctx, variant(same, held_variant(%{reads: [site.(7)]})))
    assert v.status == :pass, inspect(v.reason)

    moved = Map.put(site.(7), "line", 3)
    v = settle(held, ctx, variant(same, held_variant(%{reads: [moved]})))
    assert v.reason =~ "read what the first did not: schedulers in pkg"
  end

  # Only the varied value itself may differ: an env input of the same name
  # with another value (HOME, read by name) is the same input.
  test "the same inputs with other values pass", ctx do
    inputs = [%{"kind" => "os_type", "family" => "unix"}]

    pass = %{
      ctx.pass
      | compile_inputs:
          inputs ++ [%{"kind" => "env", "name" => "HOME", "set_by" => "host", "value" => "a"}]
    }

    held = Differential.hold(pass, ctx.varied)
    other = inputs ++ [%{"kind" => "env", "name" => "HOME", "set_by" => "host", "value" => "b"}]

    v =
      settle(
        held,
        ctx,
        variant(
          %{"pkg.app" => "{application,pkg,[]}.\n", "x.beam" => "same"},
          held_variant(%{compile_inputs: other})
        )
      )

    assert v.status == :pass, inspect(v.observations["problems"])
  end

  test "a first build whose read list hit its cap cannot tell, and cannot be judged", ctx do
    reads = for i <- 1..50, do: %{"name" => "V#{i}", "all" => false}
    pass = put_in(ctx.pass, [:observations, "env_reads"], reads)
    held = Differential.hold(pass, ctx.varied)
    extra = %{"name" => "FX_GATE", "all" => false}
    v = settle(held, ctx, variant(%{}, held_variant(%{env_reads: reads ++ [extra]})))
    assert v.reason == Reasons.could_not_judge()
    assert Enum.any?(v.observations["problems"], &(&1 =~ "env reads over their cap"))
  end

  # Review R3: a variant must have run with the count it asked for (the
  # tracer's start line, `trace_stats["schedulers_online"]`), else it
  # proves nothing and the build refuses.
  test "a variant that ran with another scheduler count than asked refuses", ctx do
    same = %{"pkg.app" => "{application,pkg,[]}.\n", "x.beam" => "same"}
    wrong = held_variant() |> put_in([:observations, "trace_stats", "schedulers_online"], 8)
    v = settle(held(ctx), ctx, variant(same, wrong))

    assert v.status == :skip

    assert v.reason ==
             @sched["refusal"] <> "; a differential build (low) ran with 8 schedulers, not 1"

    none = held_variant() |> put_in([:observations, "trace_stats", "schedulers_online"], nil)
    v = settle(held(ctx), ctx, variant(same, none))
    assert v.reason =~ "; a differential build (low) ran with nil schedulers, not 1"
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

  # Review N1, N2 (coordinator ruling): a plain-arguments read takes the
  # route only when every scripted release of the lock is a reviewed one
  # (`ReviewedScripts`); no script runs a second time.
  @reviewed %{app: "gproc", release: "gproc 1.2.0", status: :reviewed}

  test "plain arguments read by reviewed scripts alone pass with the variants", ctx do
    scripts = [
      @reviewed,
      %{app: "chatterbox", release: "ts_chatterbox 0.16.0", status: :reviewed}
    ]

    held = held(ctx, [@plain], scripts)
    same = %{"pkg.app" => "{application,pkg,[]}.\n", "x.beam" => "same"}
    v = settle(held, ctx, variant(same, held_variant(%{reads: [@plain]})))

    assert v.status == :pass, inspect(v.reason)
    assert v.observations["differential"]["scripts"] == ["gproc 1.2.0", "ts_chatterbox 0.16.0"]
  end

  test "one script that is not a reviewed one refuses, naming it, before any variant", ctx do
    no_run = fn _, _, _ -> flunk("no variant build") end

    for {entry, why} <- [
          {%{app: "fx", release: "fx 0.1.0", status: :unreviewed},
           "fx 0.1.0's rebar.config.script is not a reviewed one"},
          {%{app: "fx", release: nil, status: :unverified, why: "no verified tarball"},
           "fx's scripts cannot be verified: no verified tarball"}
        ] do
      v = settle(held(ctx, [@plain], [@reviewed, entry]), ctx, no_run)
      assert v.reason == @plain["refusal"] <> "; " <> why
      assert v.observations["trace_stats"]["differential"] == "differs"
    end
  end

  test "a script refusal names the plain-arguments read, whatever came first", ctx do
    held = held(ctx, [@sched, @plain], [%{app: "fx", release: "fx 0.1.0", status: :unreviewed}])
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end)
    assert String.starts_with?(v.reason, @plain["refusal"] <> "; fx 0.1.0's rebar.config.script")
  end

  test "plain arguments with no rebar.config.script to have read them refuse", ctx do
    held = held(ctx, [@plain], [])
    v = settle(held, ctx, fn _, _, _ -> flunk("no variant build") end)
    assert v.reason == @plain["refusal"] <> "; no rebar.config.script of the lock read them"
    assert v.observations["trace_stats"]["differential"] == "differs"
  end

  # The variant's dirs are made exclusively: one that exists is never used
  # (a stale build of the package there would compare the first with
  # itself), and never removed. `differential_name:` fixes the random part.
  test "a variant dir or root that exists already cannot be judged, and is left alone", ctx do
    base = Path.join(ctx.dir, "base")
    File.mkdir_p!(base)
    run = fn _, _, _ -> flunk("no variant build") end
    fixed = [differential_root: base, differential_name: fn -> "fixed" end]
    pad = byte_size(ctx.root) - byte_size(base) - 1 - byte_size("vfixedlow")

    for taken <- [
          Path.join(base, "ncc-dvfixedlow"),
          Path.join(base, "vfixedlow" <> String.duplicate("b", pad))
        ] do
      File.mkdir_p!(taken)
      File.write!(Path.join(taken, "stale"), "x")

      v = settle(held(ctx), ctx, run, fixed)
      assert v.reason == Reasons.could_not_judge()
      assert Enum.any?(v.observations["problems"], &(&1 =~ "not fresh")), inspect(v.observations)
      assert v.observations["trace_stats"]["differential"] == "not_judged"
      assert File.read!(Path.join(taken, "stale")) == "x"
      File.rm_rf!(taken)
    end
  end

  test "a first build root too short for a same-length variant root still compares", ctx do
    base = Path.join(ctx.dir, String.duplicate("r", 200))
    File.mkdir_p!(base)
    v = settle(held(ctx), ctx, variant(), differential_root: base)

    assert v.status == :pass
  end
end
