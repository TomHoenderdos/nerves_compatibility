defmodule Compatibility.Builder.ArgvTest do
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv

  @fixture Path.expand("../../fixtures/argv/post_hardening.exs", __DIR__)

  setup_all do
    {fixture, _binding} = Code.eval_file(@fixture)
    fixture
  end

  test "builds exactly the argv the parity fixture pins", %{input: input, argv: argv} do
    assert Argv.build(input) == argv
  end

  test "leaves out the limits and the CPU env when nothing caps the build", %{input: input} do
    argv = input |> Map.drop([:cpus, :memory, :build_concurrency]) |> Argv.build()

    refute "--cpus" in argv
    refute "--memory" in argv

    refute Enum.any?(
             argv,
             &String.starts_with?(&1, [
               "ERL_FLAGS=",
               "ELIXIR_ERL_OPTIONS=",
               "NCC_SQUASHFS_PROCESSORS=",
               "NCC_BUILD_CONCURRENCY="
             ])
           )
  end

  test "no build cache means neither the mount nor its env", %{input: input} do
    argv = Argv.build(put_in(input, [:paths, :build_cache], nil))

    refute Enum.any?(argv, &String.contains?(&1, "build-cache"))
  end

  # A fractional quota still needs one scheduler to make progress.
  test "a fractional CPU cap passes through and still gets one scheduler", %{input: input} do
    argv = Argv.build(%{input | cpus: "0.5"})

    assert ["--cpus", "0.5" | _] = Enum.drop_while(argv, &(&1 != "--cpus"))
    assert "NCC_SQUASHFS_PROCESSORS=1" in argv
  end

  # Config may hand over numbers rather than strings.
  test "renders numeric limits", %{input: input} do
    argv = Argv.build(%{input | cpus: 3, build_concurrency: 2})

    assert ["--cpus", "3" | _] = Enum.drop_while(argv, &(&1 != "--cpus"))
    assert "NCC_SQUASHFS_PROCESSORS=3" in argv
    assert "NCC_BUILD_CONCURRENCY=2" in argv
  end

  test "a spec without a required path raises", %{input: input} do
    assert_raise KeyError, fn ->
      Argv.build(%{input | paths: Map.delete(input.paths, :tmp)})
    end
  end
end
