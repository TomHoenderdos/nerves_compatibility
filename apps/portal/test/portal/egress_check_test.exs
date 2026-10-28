defmodule Portal.EgressCheckTest do
  use ExUnit.Case, async: true

  alias Portal.EgressCheck

  @v4 %{"address" => "100.64.0.1", "port" => 5432}
  @v6 %{"address" => "fd00::1", "port" => 5432}

  describe "parse_targets/1" do
    test "reads v4 and bracketed v6 host:port pairs" do
      assert {:ok, [@v4, @v6]} =
               EgressCheck.parse_targets("100.64.0.1:5432, [fd00::1]:5432")
    end

    test "refuses names, missing or out-of-range ports, unbracketed v6 and nothing at all" do
      for raw <- [
            "db.internal:5432",
            "100.64.0.1",
            "100.64.0.1:0",
            "100.64.0.1:70000",
            "fd00::1:5432",
            "",
            " , "
          ] do
        assert match?({:error, _}, EgressCheck.parse_targets(raw)), "accepted #{inspect(raw)}"
      end

      assert {:error, message} = EgressCheck.parse_targets(nil)
      assert message =~ "NCC_EGRESS_PROBE"
    end
  end

  defp passing_result(outcomes) do
    %{
      "egress_probe" => outcomes,
      "systems" => %{"host" => %{"status" => "pass"}, "pure_elixir" => %{"status" => "pass"}}
    }
  end

  describe "run/2" do
    defp deps(overrides) do
      test = self()

      Map.merge(
        %{
          preflight: fn -> :ok end,
          bare: fn _target -> "timeout" end,
          build: fn args ->
            send(test, {:build, args})
            outcomes = Enum.map(args.egress_probe, &Map.put(&1, "outcome", "timeout"))
            {:ok, %{exit_code: 0, result: passing_result(outcomes)}}
          end,
          cleanup: fn run_id ->
            send(test, {:cleanup, run_id})
            :ok
          end
        },
        overrides
      )
    end

    test "passes when the filter is loaded and nothing gets through" do
      report = EgressCheck.run([@v4, @v6], deps(%{}))

      assert report.ok?
      assert report.preflight == :ok
      assert Enum.map(report.bare, & &1["outcome"]) == ["timeout", "timeout"]

      assert_received {:build,
                       %{package: "jason", version: "1.4.4", egress_probe: [@v4, @v6], run_id: id}}

      assert_received {:cleanup, ^id}
    end

    test "a target the bare container reached fails the check" do
      bare = fn
        %{"address" => "100.64.0.1"} -> "connected"
        _target -> "unreachable"
      end

      refute EgressCheck.run([@v4, @v6], deps(%{bare: bare})).ok?
    end

    test "refused means a reset came back, so it fails the check" do
      refute EgressCheck.run([@v4], deps(%{bare: fn _ -> "refused" end})).ok?
    end

    test "a target the build reached fails the check" do
      build = fn args ->
        {:ok,
         %{
           exit_code: 0,
           result: passing_result([Map.put(hd(args.egress_probe), "outcome", "connected")])
         }}
      end

      refute EgressCheck.run([@v4], deps(%{build: build})).ok?
    end

    test "a missing filter fails the check even when nothing connects" do
      refute EgressCheck.run(
               [@v4],
               deps(%{preflight: fn -> {:error, :egress_filter_missing} end})
             ).ok?
    end

    test "a build without an egress_probe fails the check and still cleans up" do
      report =
        EgressCheck.run([@v4], deps(%{build: fn _ -> {:ok, %{exit_code: 10, result: nil}} end}))

      refute report.ok?
      assert {:error, _} = report.build
      assert_received {:cleanup, _run_id}
    end

    # The worker probes before deps.get, so every target can read blocked on
    # a host whose filter also breaks DNS or 443 for honest builds.
    test "a build that failed fails the check even when every target is blocked" do
      blocked = fn args -> Enum.map(args.egress_probe, &Map.put(&1, "outcome", "timeout")) end

      for {exit_code, systems} <- [
            {10, %{"host" => %{"status" => "pass"}}},
            {0, %{"host" => %{"status" => "fail"}}},
            {0, %{"host" => %{"status" => "pass"}, "pure_elixir" => %{"status" => "error"}}},
            {0, %{"pure_elixir" => %{"status" => "pass"}}},
            {0, %{}},
            {0, nil}
          ] do
        build = fn args ->
          result = %{"egress_probe" => blocked.(args), "systems" => systems}
          {:ok, %{exit_code: exit_code, result: result}}
        end

        report = EgressCheck.run([@v4], deps(%{build: build}))

        refute report.ok?, "passed with exit #{exit_code} and #{inspect(systems)}"
        assert {:error, _reason} = report.build_result
        assert Enum.map(report.build, & &1["outcome"]) == ["timeout"]
        assert EgressCheck.format(report) =~ "egress check FAILED"
      end
    end

    test "the report says the build passed" do
      report = EgressCheck.run([@v4], deps(%{}))

      assert report.build_result == :pass
      assert EgressCheck.format(report) =~ "build jason 1.4.4: exit 0, every system pass"
    end
  end

  test "bare_outcome/1 classifies what the probe inside the container answered" do
    assert EgressCheck.bare_outcome({"ncc-egress-probe-exit=0\n", 0}) == "connected"
    assert EgressCheck.bare_outcome({"ncc-egress-probe-exit=124\n", 124}) == "timeout"

    assert EgressCheck.bare_outcome(
             {"bash: connect: Connection refused\nncc-egress-probe-exit=1\n", 1}
           ) == "refused"

    assert EgressCheck.bare_outcome(
             {"bash: connect: Network is unreachable\nncc-egress-probe-exit=1\n", 1}
           ) == "unreachable"

    assert EgressCheck.bare_outcome(
             {"bash: connect: No route to host\nncc-egress-probe-exit=1\n", 1}
           ) == "unreachable"
  end

  # Without the probe's own exit line the container never ran it: docker
  # failed, and whatever docker said is no evidence of a drop.
  test "bare_outcome/1 never reads a docker failure as blocked" do
    for answer <- [
          {"Unable to find image 'x'\n", 125},
          {"", 124},
          {"docker: Error response from daemon: network is unreachable\n", 125},
          {"Cannot connect to the Docker daemon\n", 1},
          {"", 0},
          {"ncc-egress-probe-exit=124\n", 125}
        ] do
      outcome = EgressCheck.bare_outcome(answer)
      assert "error: " <> _ = outcome
      refute EgressCheck.blocked?(outcome), "#{inspect(answer)} read as #{outcome}"
    end
  end

  test "blocked?/1 accepts only a drop or a missing route" do
    assert EgressCheck.blocked?("timeout")
    assert EgressCheck.blocked?("unreachable")
    refute EgressCheck.blocked?("connected")
    refute EgressCheck.blocked?("refused")
    refute EgressCheck.blocked?("invalid_target")
  end

  test "format/1 names every target and the verdict" do
    report = %{
      preflight: :ok,
      bare: [Map.put(@v4, "outcome", "timeout")],
      build: [Map.put(@v4, "outcome", "connected")],
      build_result: :pass,
      ok?: false
    }

    text = EgressCheck.format(report)
    assert text =~ "preflight: :ok"
    assert text =~ "bare container -> 100.64.0.1:5432: timeout"
    assert text =~ "build jason 1.4.4 -> 100.64.0.1:5432: connected"
    assert text =~ "egress check FAILED"
  end
end

defmodule Portal.EgressCheck.BareProbeRuntimeTest do
  # Not async: swaps `docker` on PATH and the builder's app env.
  use ExUnit.Case, async: false

  alias Portal.EgressCheck

  @target %{"address" => "100.64.0.1", "port" => 5432}

  # A fake `docker` that records its argv NUL-separated, since the probe script
  # passed with `-c` spans several lines.
  setup do
    tmp = Path.join(System.tmp_dir!(), "bare-probe-#{System.unique_integer([:positive])}")
    bin = Path.join(tmp, "bin")
    log = Path.join(tmp, "argv")
    File.mkdir_p!(bin)

    docker = Path.join(bin, "docker")
    File.write!(docker, "#!/bin/sh\nprintf '%s\\0' \"$@\" > '#{log}'\nexit 0\n")
    File.chmod!(docker, 0o755)

    old_path = System.get_env("PATH")
    previous = Application.get_env(:portal, Portal.Builder, [])
    System.put_env("PATH", bin <> ":" <> old_path)

    on_exit(fn ->
      System.put_env("PATH", old_path)
      Application.put_env(:portal, Portal.Builder, previous)
      File.rm_rf(tmp)
    end)

    {:ok, log: log, previous: previous}
  end

  defp probe_argv(log, runtime, previous) do
    Application.put_env(
      :portal,
      Portal.Builder,
      Keyword.merge(previous, docker_image: "ncc-worker:local", runtime: runtime)
    )

    EgressCheck.bare_probe(@target)
    log |> File.read!() |> String.split(<<0>>, trim: true)
  end

  # The bare probe is the control half of the egress check. Under a different
  # runtime than builds use, it would measure a network path no build takes.
  test "the bare probe runs under runsc when builds do", %{log: log, previous: previous} do
    argv = probe_argv(log, "runsc", previous)

    assert ["run" | _] = argv
    assert Enum.count(argv, &String.starts_with?(&1, "--runtime")) == 1
    runtime_at = Enum.find_index(argv, &(&1 == "--runtime=runsc"))
    image_at = Enum.find_index(argv, &(&1 == "ncc-worker:local"))
    assert runtime_at, "expected --runtime=runsc in #{inspect(argv)}"
    assert runtime_at < image_at, "--runtime must come before the image, not in its command"
  end

  test "the bare probe passes no runtime flag when none is configured", %{
    log: log,
    previous: previous
  } do
    argv = probe_argv(log, nil, previous)

    assert ["run" | _] = argv
    refute Enum.any?(argv, &String.starts_with?(&1, "--runtime"))
  end
end
