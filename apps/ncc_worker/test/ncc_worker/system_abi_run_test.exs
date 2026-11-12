defmodule NccWorker.SystemAbiRunTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias NccWorker.SystemAbiRun

  @moduletag :tmp_dir

  @fixtures Path.expand("../../../compatibility/test/fixtures/elf", __DIR__)

  @toolchain %{elixir: "1.20.3", erlang: "29", mix: "1.20.3", nerves_bootstrap: "1.17.3"}

  @lock """
  %{
    "nerves_system_rpi4": {:hex, :nerves_system_rpi4, "2.1.0", "i", [:mix], [{:nerves, "~> 1.11", [hex: :nerves, repo: "hexpm", optional: false]}, {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", [hex: :nerves_toolchain_aarch64_nerves_linux_gnu, repo: "hexpm", optional: false]}], "hexpm", "o"},
    "nerves_toolchain_aarch64_nerves_linux_gnu": {:hex, :nerves_toolchain_aarch64_nerves_linux_gnu, "15.3.0", "i", [:mix], [], "hexpm", "o"},
  }
  """

  setup %{tmp_dir: tmp} do
    out = Path.join(tmp, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    artifacts = Path.join(tmp, "artifacts")
    File.mkdir_p!(artifacts)

    paths = %{work_dir: Path.join(tmp, "work"), output_dir: out, logs_dir: Path.join(out, "logs")}
    %{paths: paths, artifacts: artifacts, tmp: tmp}
  end

  defp pair(system, version), do: %{"system" => system, "version" => version}

  defp input(pairs),
    do: %{
      run_id: "system_abi-7",
      image: %{name: "ncc-worker:local", digest: "sha256:x"},
      mode: "system_abi",
      system_abi: pairs
    }

  # Stands in for `Project.create/3`: an empty generated project.
  defp fake_project do
    me = self()

    fn work_dir, overrides, targets ->
      send(me, {:created, overrides, targets})
      dir = Path.join(work_dir, "proj")
      File.mkdir_p!(dir)
      {:ok, dir}
    end
  end

  # Stands in for `mix`: `deps.get` writes the lock, `nerves.artifact.get`
  # extracts the system's artifact into the farm the way Nerves does.
  defp fake_mix(artifacts, opts \\ []) do
    me = self()

    fn args, dir, env, _log ->
      {"MIX_TARGET", target} = List.keyfind(env, "MIX_TARGET", 0)
      send(me, {:mix, target, args})

      cond do
        {target, args} == opts[:fail] ->
          {:error, 1}

        args == ["deps.get"] ->
          File.write!(Path.join(dir, "mix.lock"), @lock)
          :ok

        args == ["nerves.artifact.get"] and not Keyword.get(opts, :no_artifact, false) ->
          extract(Path.join(artifacts, "nerves_system_#{target}-2.1.0"))
          :ok

        true ->
          :ok
      end
    end
  end

  defp extract(dir) do
    release = Path.join(dir, "staging/usr/lib/erlang/releases/28")
    File.mkdir_p!(release)
    File.write!(Path.join(release, "OTP_VERSION"), "28.0.2\n")
    File.mkdir_p!(Path.join(dir, "images"))
    File.write!(Path.join(dir, "images/rootfs.squashfs"), "")
  end

  # Stands in for unsquashfs: a rootfs with libz and, unless told not to, libc.
  defp tree_runner(opts \\ []) do
    fn _squashfs, dest, _timeout ->
      usr_lib = Path.join(dest, "usr/lib")
      File.mkdir_p!(usr_lib)
      File.cp!(Path.join(@fixtures, "libz_aarch64.so.1"), Path.join(usr_lib, "libz.so.1"))

      if Keyword.get(opts, :libc, true),
        do: File.cp!(Path.join(@fixtures, "nif_aarch64.so"), Path.join(usr_lib, "libc.so.6"))

      :ok
    end
  end

  defp run(input, ctx, extra) do
    opts =
      [
        paths: ctx.paths,
        toolchain: @toolchain,
        artifacts_dir: ctx.artifacts,
        tmp_dir: ctx.tmp,
        create_project: fake_project(),
        mix: fake_mix(ctx.artifacts),
        runner: tree_runner()
      ]
      |> Keyword.merge(extra)

    SystemAbiRun.run(input, opts)
  end

  test "reports a release's toolchain, full OTP version and library table", ctx do
    assert {:ok, result} = run(input([pair("nerves_system_rpi4", "2.1.0")]), ctx, [])

    assert_received {:created, %{"nerves_system_rpi4" => "== 2.1.0"}, ["rpi4"]}
    assert_received {:mix, "rpi4", ["deps.get"]}
    assert_received {:mix, "rpi4", ["nerves.artifact.get"]}

    assert result.scope == "system_abi"
    assert result.systems == %{}
    assert result.package == nil
    assert result.toolchain == @toolchain

    assert [entry] = result.system_abi
    {libs, entry} = Map.pop(entry, "system_libs")

    assert entry == %{
             "system" => "nerves_system_rpi4",
             "version" => "2.1.0",
             "toolchain" => %{
               "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
               "version" => "15.3.0"
             },
             "otp_full" => "28.0.2"
           }

    assert "libc.so.6" in Map.keys(libs)
    assert "libz.so.1" in Map.keys(libs)
  end

  test "a rootfs without libc is an error, never an empty table", ctx do
    capture_io(:stderr, fn ->
      assert {:ok, result} =
               run(input([pair("nerves_system_rpi4", "2.1.0")]), ctx,
                 runner: tree_runner(libc: false)
               )

      assert result.system_abi == [
               %{
                 "system" => "nerves_system_rpi4",
                 "version" => "2.1.0",
                 "error" => "no libc in rootfs"
               }
             ]
    end)
  end

  test "more than 8 pairs is an input error", ctx do
    pairs = for i <- 0..8, do: pair("nerves_system_rpi4", "2.1.#{i}")

    assert {:error, :too_many_pairs} = run(input(pairs), ctx, [])
    refute_received {:created, _, _}
  end

  test "the worker refuses too many pairs before it prepares anything", %{tmp: tmp} do
    pairs = for i <- 0..8, do: pair("nerves_system_rpi4", "2.1.#{i}")
    out = Path.join(tmp, "worker-out")
    input = Map.put(input(pairs), :paths, %{work_dir: Path.join(tmp, "w"), output_dir: out})

    assert {:error, :too_many_pairs} = NccWorker.Worker.run(input)
    refute File.exists?(out)
  end

  test "a malformed pair list is an input error", ctx do
    for bad <- [nil, "nerves_system_rpi4", [%{"system" => "nerves_system_rpi4"}], [1]] do
      assert {:error, :invalid_pairs} = run(input(bad), ctx, [])
    end
  end

  test "a failed deps.get fails that pair only and runs the next", ctx do
    pairs = [pair("nerves_system_bbb", "2.1.0"), pair("nerves_system_rpi4", "2.1.0")]
    mix = fake_mix(ctx.artifacts, fail: {"bbb", ["deps.get"]})

    assert {:ok, result} = run(input(pairs), ctx, mix: mix)

    assert [
             %{
               "system" => "nerves_system_bbb",
               "version" => "2.1.0",
               "error" => "deps.get failed"
             },
             %{"system" => "nerves_system_rpi4", "otp_full" => "28.0.2"}
           ] = result.system_abi

    assert map_size(hd(result.system_abi)) == 3
  end

  test "each pair gets its own project", ctx do
    pairs = [pair("nerves_system_bbb", "2.1.0"), pair("nerves_system_rpi4", "2.1.0")]

    assert {:ok, _result} = run(input(pairs), ctx, [])

    assert_received {:created, %{"nerves_system_bbb" => "== 2.1.0"}, ["bbb"]}
    assert_received {:created, %{"nerves_system_rpi4" => "== 2.1.0"}, ["rpi4"]}
  end

  test "a release whose artifact did not resolve", ctx do
    mix = fake_mix(ctx.artifacts, no_artifact: true)

    assert {:ok, %{system_abi: [entry]}} =
             run(input([pair("nerves_system_rpi4", "2.1.0")]), ctx, mix: mix)

    assert entry["error"] == "no artifact"
  end

  test "a failed nerves.artifact.get", ctx do
    mix = fake_mix(ctx.artifacts, fail: {"rpi4", ["nerves.artifact.get"]})

    assert {:ok, %{system_abi: [entry]}} =
             run(input([pair("nerves_system_rpi4", "2.1.0")]), ctx, mix: mix)

    assert entry["error"] == "nerves.artifact.get failed"
  end

  test "an unknown system or a version that is not one never reaches mix", ctx do
    pairs = [
      pair("nerves_system_unknown_board", "1.0.0"),
      pair("nerves_system_rpi4", ">= 0.0.0"),
      pair("nerves_system_rpi4", "2.1.0\"}, {:evil, \"1")
    ]

    assert {:ok, result} = run(input(pairs), ctx, [])

    assert Enum.map(result.system_abi, & &1["error"]) == [
             "unknown system",
             "invalid version",
             "invalid version"
           ]

    refute_received {:created, _, _}
  end
end
