defmodule NccWorker.SystemAbiTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias NccWorker.{JsonWriter, SystemAbi}

  @fixtures Path.expand("../../../compatibility/test/fixtures/elf", __DIR__)

  @lock %{
    nerves_system_rpi4:
      {:hex, :nerves_system_rpi4, "2.2.2", "x", [:mix],
       [
         {:nerves, "~> 1.11", [hex_repo: "hexpm"]},
         {:nerves_toolchain_aarch64_nerves_linux_gnu, "~> 15.3.0", [hex_repo: "hexpm"]}
       ], "hexpm", "y"},
    nerves_toolchain_aarch64_nerves_linux_gnu:
      {:hex, :nerves_toolchain_aarch64_nerves_linux_gnu, "15.3.1", "a", [:mix], [], "hexpm", "b"}
  }

  @libz_keys ["libz.so", "libz.so.1", "libz.so.1.3.2"]

  describe "toolchain/2" do
    test "the locked version of the system's toolchain dependency" do
      assert SystemAbi.toolchain(@lock, "nerves_system_rpi4") == %{
               "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
               "version" => "15.3.1"
             }
    end

    test "nil for a system the lock does not have" do
      assert SystemAbi.toolchain(@lock, "nerves_system_bbb") == nil
    end

    test "reads a lock keyed by string, as DepsLock reads one" do
      lock = Map.new(@lock, fn {k, v} -> {Atom.to_string(k), v} end)

      assert %{"version" => "15.3.1"} = SystemAbi.toolchain(lock, "nerves_system_rpi4")
    end
  end

  describe "otp/1" do
    @describetag :tmp_dir

    test "the system's full OTP version", %{tmp_dir: dir} do
      release = Path.join(dir, "staging/usr/lib/erlang/releases/29")
      File.mkdir_p!(release)
      File.write!(Path.join(release, "OTP_VERSION"), "29.1.2\n")

      assert SystemAbi.otp(dir) == "29.1.2"
    end

    test "nil without one", %{tmp_dir: dir} do
      assert SystemAbi.otp(dir) == nil
    end
  end

  describe "artifact_dir/3" do
    test "names the entry as the Nerves cache does" do
      for {name, version} <- [
            {"nerves_system_bbb", "2.31.2"},
            {"nerves_system_qemu_aarch64", "0.5.2"},
            {"nerves_system_rpi0_2", "2.2.2"}
          ] do
        assert SystemAbi.artifact_dir("/a", name, version) == "/a/#{name}-#{version}"
      end
    end
  end

  describe "rootfs_libs/2" do
    @describetag :tmp_dir

    test "keys each library by soname, file name and every link to it", %{tmp_dir: dir} do
      artifact = artifact(dir)
      libs = SystemAbi.rootfs_libs(artifact, runner: tree_runner(libc: true), tmp_dir: dir)

      assert Map.keys(libs) |> Enum.sort() == ["libc.so.6" | @libz_keys]

      for key <- @libz_keys do
        assert length(libs[key]) == 16
        assert Enum.all?(libs[key], &String.starts_with?(&1, "ZLIB_"))
      end

      assert Path.wildcard(Path.join(dir, "ncc-rootfs-*")) == []
    end

    test "a merged /usr gives the same keys once", %{tmp_dir: dir} do
      runner = tree_runner(libc: true, merged: true)
      libs = SystemAbi.rootfs_libs(artifact(dir), runner: runner, tmp_dir: dir)

      assert Map.keys(libs) |> Enum.sort() == ["libc.so.6" | @libz_keys]
    end

    test "nil without a libc: the extraction was partial", %{tmp_dir: dir} do
      runner = tree_runner(libc: false)

      assert capture_io(:stderr, fn ->
               assert SystemAbi.rootfs_libs(artifact(dir), runner: runner, tmp_dir: dir) == nil
             end) =~ ":no_libc"
    end

    test "nil when the runner fails", %{tmp_dir: dir} do
      runner = fn _squashfs, _dest -> {:error, :boom} end

      assert capture_io(:stderr, fn ->
               assert SystemAbi.rootfs_libs(artifact(dir), runner: runner, tmp_dir: dir) == nil
             end) =~ ":boom"

      assert Path.wildcard(Path.join(dir, "ncc-rootfs-*")) == []
    end

    test "nil without unsquashfs", %{tmp_dir: dir} do
      assert capture_io(:stderr, fn ->
               assert SystemAbi.rootfs_libs(artifact(dir),
                        unsquashfs: "/nonexistent",
                        tmp_dir: dir
                      ) ==
                        nil
             end) =~ ":no_unsquashfs"
    end

    test "nil without a squashfs", %{tmp_dir: dir} do
      assert SystemAbi.rootfs_libs(dir, runner: tree_runner(libc: true), tmp_dir: dir) == nil
    end
  end

  describe "put/4" do
    @describetag :tmp_dir

    setup %{tmp_dir: dir} do
      artifacts = Path.join(dir, "artifacts")
      artifact = artifact(Path.join(artifacts, "nerves_system_rpi4-2.2.2"))
      release = Path.join(artifact, "staging/usr/lib/erlang/releases/29")
      File.mkdir_p!(release)
      File.write!(Path.join(release, "OTP_VERSION"), "29.1.2\n")

      opts = [artifacts_dir: artifacts, runner: tree_runner(libc: true), tmp_dir: dir]
      %{opts: opts}
    end

    test "adds the three facts to a passing target only", %{opts: opts} do
      systems = %{
        "nerves_system_rpi4" => %{status: :pass, system_version: "2.2.2"},
        "nerves_system_bbb" => %{status: :fail, system_version: "2.31.2"}
      }

      out = SystemAbi.put(systems, @lock, [], opts)
      rpi4 = out["nerves_system_rpi4"]

      assert rpi4.toolchain == %{
               "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
               "version" => "15.3.1"
             }

      assert rpi4.otp_full == "29.1.2"
      assert Map.has_key?(rpi4.system_libs, "libz.so.1")
      assert rpi4.status == :pass
      assert out["nerves_system_bbb"] == systems["nerves_system_bbb"]
    end

    test "leaves the library table out for a release the portal knows", %{opts: opts} do
      systems = %{"nerves_system_rpi4" => %{status: :pass, system_version: "2.2.2"}}

      rpi4 =
        SystemAbi.put(systems, @lock, ["nerves_system_rpi4@2.2.2"], opts)["nerves_system_rpi4"]

      assert rpi4.otp_full == "29.1.2"
      refute Map.has_key?(rpi4, :system_libs)
    end

    test "leaves out what it cannot learn and never raises", %{opts: opts} do
      systems = %{"nerves_system_rpi4" => %{status: :pass, system_version: "2.2.2"}}
      raising = Keyword.put(opts, :runner, fn _, _ -> raise "boom" end)

      {rpi4, log} =
        with_io(:stderr, fn -> SystemAbi.put(systems, %{}, [], raising)["nerves_system_rpi4"] end)

      assert rpi4 == %{status: :pass, system_version: "2.2.2", otp_full: "29.1.2"}
      assert log =~ "system_libs left out: boom"
    end

    test "a release the run has no artifact for gets only its toolchain", %{opts: opts} do
      systems = %{"nerves_system_rpi4" => %{status: :pass, system_version: "9.9.9"}}

      assert %{toolchain: %{"version" => "15.3.1"}} =
               rpi4 = SystemAbi.put(systems, @lock, [], opts)["nerves_system_rpi4"]

      refute Map.has_key?(rpi4, :otp_full) or Map.has_key?(rpi4, :system_libs)
    end
  end

  describe "result.json" do
    @describetag :tmp_dir

    test "writes the three keys when present and leaves them out otherwise", %{tmp_dir: dir} do
      abi = %{
        toolchain: %{
          "package" => "nerves_toolchain_aarch64_nerves_linux_gnu",
          "version" => "15.3.1"
        },
        otp_full: "29.1.2",
        system_libs: %{"libz.so.1" => ["ZLIB_1.2.0"]}
      }

      result = %{
        run_id: "r-abi",
        package: %{name: "circuits_gpio", version: "2.1.3"},
        image: %{name: "ncc-worker:local", digest: "sha256:x"},
        toolchain: %{elixir: "1.20.3", erlang: "29", mix: "1.20.3", nerves_bootstrap: "1.17.3"},
        systems: %{
          "nerves_system_rpi4" => Map.merge(system(), abi),
          "nerves_system_bbb" => system()
        },
        finished_at: "2026-11-12T10:00:00Z"
      }

      assert :ok = JsonWriter.write_result(dir, result)

      systems =
        dir |> Path.join("result.json") |> File.read!() |> JSON.decode!() |> Map.get("systems")

      assert systems["nerves_system_rpi4"]["toolchain"] == abi.toolchain
      assert systems["nerves_system_rpi4"]["otp_full"] == "29.1.2"
      assert systems["nerves_system_rpi4"]["system_libs"] == %{"libz.so.1" => ["ZLIB_1.2.0"]}

      for key <- ["toolchain", "otp_full", "system_libs"],
          do: refute(Map.has_key?(systems["nerves_system_bbb"], key))
    end
  end

  defp system do
    %{
      status: :pass,
      duration_sec: 1.0,
      firmware_size_bytes: 1,
      log_tail: "",
      system_version: "2.2.2",
      error: nil
    }
  end

  # An artifact dir with a squashfs to extract; the runner never reads it.
  defp artifact(dir) do
    images = Path.join(dir, "images")
    File.mkdir_p!(images)
    File.write!(Path.join(images, "rootfs.squashfs"), "")
    dir
  end

  # Stands in for unsquashfs: the tree it would extract from a rootfs.
  defp tree_runner(opts) do
    fn _squashfs, dest ->
      usr_lib = Path.join(dest, "usr/lib")
      File.mkdir_p!(usr_lib)
      File.cp!(Path.join(@fixtures, "libz_aarch64.so.1"), Path.join(usr_lib, "libz.so.1.3.2"))
      File.ln_s!("libz.so.1.3.2", Path.join(usr_lib, "libz.so.1"))
      File.ln_s!("libz.so.1.3.2", Path.join(usr_lib, "libz.so"))

      if opts[:libc],
        do: File.cp!(Path.join(@fixtures, "nif_aarch64.so"), Path.join(usr_lib, "libc.so.6"))

      if opts[:merged] do
        File.ln_s!("usr/lib", Path.join(dest, "lib"))
      else
        File.mkdir_p!(Path.join(dest, "lib"))
        File.write!(Path.join(dest, "lib/notes.txt"), "not a library")
      end

      :ok
    end
  end
end
