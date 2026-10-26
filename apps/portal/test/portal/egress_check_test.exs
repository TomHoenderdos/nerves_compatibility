defmodule Portal.EgressCheckTest do
  use ExUnit.Case, async: true

  alias Portal.EgressCheck

  @v4 %{"address" => "100.126.79.115", "port" => 5432}
  @v6 %{"address" => "fd7a:115c:a1e0::1", "port" => 5432}

  describe "parse_targets/1" do
    test "reads v4 and bracketed v6 host:port pairs" do
      assert {:ok, [@v4, @v6]} =
               EgressCheck.parse_targets("100.126.79.115:5432, [fd7a:115c:a1e0::1]:5432")
    end

    test "refuses names, missing or out-of-range ports, unbracketed v6 and nothing at all" do
      for raw <- [
            "db.internal:5432",
            "100.126.79.115",
            "100.126.79.115:0",
            "100.126.79.115:70000",
            "fd7a::1:5432",
            "",
            " , "
          ] do
        assert match?({:error, _}, EgressCheck.parse_targets(raw)), "accepted #{inspect(raw)}"
      end

      assert {:error, message} = EgressCheck.parse_targets(nil)
      assert message =~ "NCC_EGRESS_PROBE"
    end
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
            {:ok, %{exit_code: 0, result: %{"egress_probe" => outcomes}}}
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
        %{"address" => "100.126.79.115"} -> "connected"
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
           result: %{"egress_probe" => [Map.put(hd(args.egress_probe), "outcome", "connected")]}
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
  end

  test "bare_outcome/1 classifies what docker and bash answered" do
    assert EgressCheck.bare_outcome({"", 0}) == "connected"
    assert EgressCheck.bare_outcome({"", 124}) == "timeout"
    assert EgressCheck.bare_outcome({"bash: connect: Connection refused\n", 1}) == "refused"

    assert EgressCheck.bare_outcome({"bash: connect: Network is unreachable\n", 1}) ==
             "unreachable"

    assert EgressCheck.bare_outcome({"bash: connect: No route to host\n", 1}) == "unreachable"

    assert "error: Unable to find image" <> _ =
             EgressCheck.bare_outcome({"Unable to find image 'x'\n", 125})
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
      ok?: false
    }

    text = EgressCheck.format(report)
    assert text =~ "preflight: :ok"
    assert text =~ "bare container -> 100.126.79.115:5432: timeout"
    assert text =~ "build jason 1.4.4 -> 100.126.79.115:5432: connected"
    assert text =~ "egress check FAILED"
  end
end
