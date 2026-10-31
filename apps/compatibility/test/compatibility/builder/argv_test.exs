defmodule Compatibility.Builder.ArgvTest do
  use ExUnit.Case, async: true

  alias Compatibility.Builder.Argv

  @fixture Path.expand("../../fixtures/argv/post_isolation.exs", __DIR__)

  setup_all do
    {fixture, _binding} = Code.eval_file(@fixture)
    fixture
  end

  test "builds exactly the argv the parity fixture pins", %{input: input, argv: argv} do
    assert Argv.build(input) == argv
  end

  # Untrusted package code runs in the gVisor sentry, never on the host
  # kernel directly, and there is no other runtime to fall back to.
  test "always runs the container under runsc", %{input: input} do
    for spec <- [input, %{input | nerves_cache_mode: :warm}, Map.drop(input, [:cpus])] do
      argv = Argv.build(spec)

      assert ["--pids-limit", "4096", "--runtime=runsc" | _] =
               Enum.drop_while(argv, &(&1 != "--pids-limit"))

      assert Enum.count(argv, &String.starts_with?(&1, "--runtime")) == 1
    end
  end

  test "leaves out the CPU cap and its env when nothing caps the CPUs", %{input: input} do
    argv = input |> Map.drop([:cpus, :build_concurrency]) |> Argv.build()

    refute "--cpus" in argv
    assert ["--memory", "4g" | _] = Enum.drop_while(argv, &(&1 != "--memory"))

    refute Enum.any?(
             argv,
             &String.starts_with?(&1, [
               "ERL_FLAGS=",
               "ELIXIR_ERL_OPTIONS=",
               "NCC_SQUASHFS_PROCESSORS=",
               "MAKEFLAGS=",
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
    assert "MAKEFLAGS=-j1" in argv
  end

  # Config may hand over numbers rather than strings.
  test "renders numeric limits", %{input: input} do
    argv = Argv.build(%{input | cpus: 3, build_concurrency: 2})

    assert ["--cpus", "3" | _] = Enum.drop_while(argv, &(&1 != "--cpus"))
    assert "NCC_SQUASHFS_PROCESSORS=3" in argv
    assert "MAKEFLAGS=-j3" in argv
    assert "NCC_BUILD_CONCURRENCY=2" in argv
  end

  # docker-ncc's authz policy denies a container without one, and under
  # gVisor's kvm platform, which enforces no pids limit, it is the only bound
  # on a fork bomb. No caller may start a container without it.
  test "a spec without a memory limit raises", %{input: input} do
    for spec <- [Map.delete(input, :memory), %{input | memory: nil}, %{input | memory: ""}] do
      assert_raise ArgumentError, ~r/memory/, fn -> Argv.build(spec) end
    end
  end

  test "a malformed memory limit raises", %{input: input} do
    for memory <- ["4 g", "-1g", "lots", "0", "0.0g", "4x"] do
      assert_raise ArgumentError, ~r/memory/, fn -> Argv.build(%{input | memory: memory}) end
    end
  end

  # docker reads 0 as no limit at all.
  test "memory_limit?/1 accepts a positive size as docker reads one" do
    for ok <- [
          "4g",
          "512m",
          "8G",
          "4gb",
          "4GiB",
          "1.5g",
          "1048576",
          "100k",
          "6000000b",
          4_294_967_296
        ] do
      assert Argv.memory_limit?(ok), inspect(ok)
    end

    for bad <- [nil, "", " ", "4 g", "-1g", "0", "0g", "0.0", 0, -1, 1.5, "lots", "4x", :atom] do
      refute Argv.memory_limit?(bad), inspect(bad)
    end
  end

  test "a spec without a required path raises", %{input: input} do
    assert_raise KeyError, fn ->
      Argv.build(%{input | paths: Map.delete(input.paths, :tmp)})
    end
  end

  test "a comma in a mount path raises", %{input: input} do
    assert_raise ArgumentError, fn ->
      Argv.build(put_in(input, [:paths, :work], "/scratch/run,evil/work"))
    end
  end

  test "an image starting with a dash raises", %{input: input} do
    assert_raise ArgumentError, fn ->
      Argv.build(%{input | image: "-x"})
    end
  end

  test "memory and build_concurrency without cpus", %{input: input} do
    argv =
      input
      |> Map.drop([:cpus])
      |> Map.put(:build_concurrency, "2")
      |> Argv.build()

    assert "--memory" in argv
    refute "--cpus" in argv
    assert "NCC_BUILD_CONCURRENCY=2" in argv

    refute Enum.any?(
             argv,
             &String.starts_with?(&1, ["ERL_FLAGS=", "ELIXIR_ERL_OPTIONS="])
           )
  end

  # Isolation spec, section 1: a build only ever reads the Nerves cache; the
  # warm run is its one writer.
  test "a build mounts the Nerves cache read-only at /nerves-cache", %{input: input} do
    argv = Argv.build(input)

    assert "type=bind,source=/srv/ncc/nerves-cache,target=/nerves-cache,readonly" in argv
    refute "NCC_NERVES_CACHE_RW=1" in argv
    refute Enum.any?(argv, &String.contains?(&1, "/home/nerves/.nerves"))
  end

  test "a warm run mounts it read-write and sets no fallback env", %{input: input} do
    argv = Argv.build(%{input | nerves_cache_mode: :warm})

    assert "type=bind,source=/srv/ncc/nerves-cache,target=/nerves-cache" in argv
    refute "NCC_NERVES_CACHE_RW=1" in argv
  end

  # The one-release rollback: read-write as before, and the worker is told so
  # it skips the per-run symlink farm.
  test "the read-write fallback mounts it read-write and tells the worker", %{input: input} do
    argv = Argv.build(%{input | nerves_cache_mode: :rw})

    assert "type=bind,source=/srv/ncc/nerves-cache,target=/nerves-cache" in argv
    index = Enum.find_index(argv, &(&1 == "NCC_NERVES_CACHE_RW=1"))
    assert index, "expected -e NCC_NERVES_CACHE_RW=1"
    assert Enum.at(argv, index - 1) == "-e"
  end

  test "a spec without a Nerves cache mode raises", %{input: input} do
    assert_raise KeyError, fn -> Argv.build(Map.delete(input, :nerves_cache_mode)) end
  end

  test "an unknown Nerves cache mode raises rather than mounting read-write", %{input: input} do
    assert_raise FunctionClauseError, fn -> Argv.build(%{input | nerves_cache_mode: :bogus}) end
  end

  # A build runs untrusted package code, so it only ever reads the shared Hex
  # cache; the host-side promotion (`Compatibility.HexCache`) is its writer.
  test "a build mounts the Hex cache read-only at /hex-cache", %{input: input} do
    argv = Argv.build(input)

    assert "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache,readonly" in argv
    refute "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache" in argv
    refute "NCC_HEX_CACHE_RW=1" in argv
  end

  test "an explicit read-only Hex cache mode is the default", %{input: input} do
    assert Argv.build(Map.put(input, :hex_cache_mode, :readonly)) == Argv.build(input)
  end

  # The one-release rollback: read-write as before, and the worker is told so
  # it uses the mounted cache as its HEX_HOME again.
  test "the Hex cache read-write fallback mounts it read-write and tells the worker", %{
    input: input
  } do
    argv = Argv.build(Map.put(input, :hex_cache_mode, :rw))

    assert "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache" in argv
    refute "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache,readonly" in argv
    index = Enum.find_index(argv, &(&1 == "NCC_HEX_CACHE_RW=1"))
    assert index, "expected -e NCC_HEX_CACHE_RW=1"
    assert Enum.at(argv, index - 1) == "-e"
  end

  # An image from before the seeded HEX_HOME writes /hex-cache/packages
  # itself; read-only it would fail every deps.get. It keeps the old mount,
  # and the rollback env means nothing to it.
  test "an unseeded image keeps the read-write mount without the rollback env", %{
    input: input
  } do
    argv = Argv.build(Map.put(input, :hex_cache_mode, :legacy))

    assert "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache" in argv
    refute "type=bind,source=/srv/ncc/hex-cache,target=/hex-cache,readonly" in argv
    refute "NCC_HEX_CACHE_RW=1" in argv
  end

  test "hex_cache_mode/2 reads the image label, the rollback first" do
    assert Argv.hex_cache_label() == "ncc.hex-cache"
    assert Argv.hex_cache_mode("seeded", false) == :readonly
    assert Argv.hex_cache_mode("seeded", true) == :rw
    assert Argv.hex_cache_mode(nil, false) == :legacy
    assert Argv.hex_cache_mode("", false) == :legacy
    assert Argv.hex_cache_mode("<no value>", false) == :legacy
    assert Argv.hex_cache_mode(nil, true) == :rw
  end

  test "an unknown Hex cache mode raises rather than mounting read-write", %{input: input} do
    assert_raise FunctionClauseError, fn ->
      Argv.build(Map.put(input, :hex_cache_mode, :bogus))
    end
  end

  # Shared with `Portal.Builder.safe_name/1` and the agent's scratch layout.
  test "safe_name/1 and container_name/1 are the one run-id transform" do
    assert Argv.safe_name("rb-jason-1.4.4-1700000000000") == "rb-jason-1.4.4-1700000000000"
    assert Argv.safe_name("a/b c") == "a_b_c"
    assert Argv.safe_name("../x") == ".._x"
    assert Argv.container_name("x y") == "ncc-x_y"
    for bad <- ["", ".", ".."], do: assert_raise(ArgumentError, fn -> Argv.safe_name(bad) end)
  end
end
