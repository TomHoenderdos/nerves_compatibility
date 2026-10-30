defmodule Portal.EgressCheckTest do
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv
  alias Portal.EgressCheck

  @v4 %{"address" => "100.64.0.1", "port" => 5432}
  @v6 %{"address" => "fd00::1", "port" => 5432}

  # gVisor's netstack is another network path than runc's: the probe checks
  # the filter on the one builds take.
  test "bare_args/1 probes the target under the builds' runtime, with the target as arguments" do
    args = EgressCheck.bare_args(@v4)

    assert ["run", "--rm", "--pull=never" | _] = args
    assert Argv.runtime_flag() in args
    assert "--cap-drop=ALL" in args
    # The builders' docker-ncc authz policy refuses a container without a
    # memory limit or with a writable root.
    assert "--read-only" in args
    assert args |> Enum.chunk_every(2, 1) |> Enum.member?(["--memory", "256m"])
    assert Enum.take(args, -2) == ["100.64.0.1", "5432"]
  end

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
