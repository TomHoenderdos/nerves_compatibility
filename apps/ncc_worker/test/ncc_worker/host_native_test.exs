defmodule NccWorker.HostNativeTest do
  use ExUnit.Case, async: true

  alias NccWorker.HostNative

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.20.5", erlang: "28", mix: "1.20.5", nerves_bootstrap: "absent"}
  @facts [otp_full: "28.5.0.2", nif_version: "2.17", glibc: "2.36"]
  @pass %{
    status: :pass,
    reason: nil,
    observations: %{"trace_stats" => %{"judge_compile" => "finished"}},
    compile_env: [],
    compile_inputs: [%{"kind" => "mix_target", "value" => "host"}],
    manager: "mix"
  }
  @nif "priv/gpio_nif.so"

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)

  defp tar(path, entries, opts) do
    :ok = :erl_tar.create(String.to_charlist(path), entries, opts)
    File.read!(path)
  end

  # The project a host-native run leaves: the package's host build (a
  # fixture's, whose priv holds an aarch64 glibc NIF), its sources, the lock
  # naming its tarball's real checksum, and that tarball in `home`.
  defp project(dir, fixture, contents \\ %{}) do
    project = Path.join(dir, "proj")
    File.mkdir_p!(Path.join([project, "deps", "sample", "lib"]))
    built = Path.join([project, "_build/host/lib/sample"])
    File.mkdir_p!(Path.dirname(built))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), built)
    [app] = Path.wildcard(Path.join(built, "ebin/*.app"))
    File.rename!(app, Path.join(built, "ebin/sample.app"))

    entries = for {p, b} <- Map.put_new(contents, "lib/sample.ex", "x"), do: {to_charlist(p), b}
    gz = tar(Path.join(dir, "contents.tar.gz"), entries, [:compressed])
    home = Path.join(dir, "hex")
    File.mkdir_p!(Path.join(home, "packages/hexpm"))
    outer = [{~c"VERSION", "3"}, {~c"CHECKSUM", "0"}, {~c"contents.tar.gz", gz}]
    tarball = tar(Path.join(home, "packages/hexpm/sample-1.0.0.tar"), outer, [])

    File.write!(Path.join(project, "mix.lock"), """
    %{
      "sample": {:hex, :sample, "1.0.0", "inner", [:mix], [], "hexpm", "#{sha(tarball)}"},
    }
    """)

    %{project: project, home: home, nif: File.read(Path.join(built, @nif))}
  end

  # rustler_precompiled's cache: the fixture's NIF in an upstream archive.
  defp archive(dir) do
    nif = File.read!(Path.join([__DIR__, "..", "fixture", "circuits_gpio-2.1.3", @nif]))
    cache = Path.join(dir, "cache/rustler_precompiled/precompiled_nifs")
    File.mkdir_p!(cache)
    name = "libsample-v1.0.0-nif-2.17-aarch64-unknown-linux-gnu.so.tar.gz"
    archive = tar(Path.join(cache, name), [{~c"libsample.so", nif}], [:compressed])
    {cache, name, archive}
  end

  defp build(ctx, triple, verdict \\ @pass, opts \\ []) do
    opts = Keyword.merge([triple: triple, hex_home: ctx.home, cache_dirs: []] ++ @facts, opts)
    HostNative.build(ctx.project, "sample", %{status: :pass}, @toolchain, verdict, opts)
  end

  describe "own_triple/2" do
    test "the builder's own triple, when the job names it or none" do
      assert HostNative.own_triple(%{}, ~c"x86_64-pc-linux-gnu") == {:ok, "x86_64-linux-gnu"}

      assert HostNative.own_triple(%{triple: "x86_64-linux-gnu"}, ~c"x86_64-pc-linux-gnu") ==
               {:ok, "x86_64-linux-gnu"}

      assert HostNative.own_triple(%{triple: "aarch64-linux-gnu"}, ~c"x86_64-pc-linux-gnu") ==
               {:error, {:host_native_triple, "x86_64-linux-gnu", "aarch64-linux-gnu"}}

      assert HostNative.own_triple(%{}, ~c"aarch64-apple-darwin24.6.0") ==
               {:error, {:no_host_native_triple, "aarch64-apple-darwin24.6.0"}}
    end
  end

  describe "build/6" do
    # Nothing checks what a compile in the run assumed of the builder's
    # CPU (`-march=native`, `-mavx2`, `-mcpu=native` in a Makefile), its run
    # paths, or what its Makefile downloaded without a checksum: only an
    # upstream file a checksum file pins is the one a user's own compile
    # would load.
    test "a NIF the package compiled in the run is refused", %{tmp_dir: dir} do
      ctx = project(dir, "circuits_gpio-2.1.3")

      assert %{status: "skipped", file_manifest: nil, native_files: nil, origins: nil} =
               build = build(ctx, "aarch64-linux-gnu")

      assert build.reason ==
               "native file compiled in the run, not a checksum-pinned download: " <> @nif

      refute Map.has_key?(build, :archives)
    end

    test "a NIF of another machine is refused", %{tmp_dir: dir} do
      ctx = project(dir, "circuits_gpio-2.1.3")

      assert %{status: "skipped", file_manifest: nil, native_files: nil} =
               build = build(ctx, "x86_64-linux-gnu")

      assert build.reason == "ships a native file x86_64-linux-gnu cannot load (#{@nif})"
    end

    test "a package without a native file is not a host-native build", %{tmp_dir: dir} do
      ctx = project(dir, "circular_buffer-1.0.0")
      assert %{status: "skipped", reason: "ships no native file"} = build(ctx, "x86_64-linux-gnu")
    end

    test "the trace's refusal wins", %{tmp_dir: dir} do
      ctx = project(dir, "circuits_gpio-2.1.3")
      refused = %{@pass | status: :skip, reason: "compile-time host read: os:version/0"}

      assert %{status: "skipped", reason: "compile-time host read: os:version/0"} =
               build(ctx, "aarch64-linux-gnu", refused)
    end

    test "a downloader's NIF passes only as a member of an archive its checksum file pins",
         %{tmp_dir: dir} do
      {cache, name, archive} = archive(dir)
      checksum = ~s(%{"#{name}" => "sha256:#{sha(archive)}"}\n)

      ctx =
        project(dir, "circuits_gpio-2.1.3", %{"checksum-Elixir.Sample.Native.exs" => checksum})

      build = build(ctx, "aarch64-linux-gnu", @pass, cache_dirs: [Path.join(dir, "cache")])
      assert %{status: "pass", reason: nil, triple: "aarch64-linux-gnu", libc: "glibc"} = build
      assert %{otp: "28", otp_full: "28.5.0.2", nif_version: "2.17", glibc: "2.36"} = build
      assert build.compile_inputs == @pass.compile_inputs
      assert is_integer(build.judge_revision)

      assert [%{"path" => @nif, "machine" => "aarch64", "class" => 64} = native] =
               build.native_files

      assert {:ok, nif} = ctx.nif
      assert native["sha256"] == sha(nif)
      assert "libc.so.6" in native["needed"]
      assert Enum.any?(build.file_manifest["priv"], &(&1["path"] == @nif))
      assert Enum.any?(build.file_manifest["ebin"], &(&1["path"] == "ebin/sample.app"))

      assert build.origins == [
               %{
                 "path" => @nif,
                 "checksum_file" => "checksum-Elixir.Sample.Native.exs",
                 "archive" => name,
                 "archive_sha256" => sha(archive)
               }
             ]

      assert build.archives == [
               {Path.join(cache, name), %{"sha256" => sha(archive), "size" => byte_size(archive)}}
             ]

      # The archive is nowhere the run's compile could have left it.
      assert %{status: "skipped", reason: reason} = build(ctx, "aarch64-linux-gnu", @pass)
      assert reason == "native file not verified against the package's checksum file: " <> @nif
    end

    # The ELF rules and the origin check read priv; a native file the
    # build left in ebin escapes both, and a beam can load_nif it from there.
    test "a native file outside priv is refused", %{tmp_dir: dir} do
      {_cache, name, archive} = archive(dir)
      checksum = ~s(%{"#{name}" => "sha256:#{sha(archive)}"}\n)
      ctx = project(dir, "circuits_gpio-2.1.3", %{"checksum.exs" => checksum})
      {:ok, nif} = ctx.nif
      File.write!(Path.join([ctx.project, "_build/host/lib/sample/ebin/libextra.so"]), nif)

      assert %{status: "skipped", reason: reason, file_manifest: nil} =
               build(ctx, "aarch64-linux-gnu", @pass, cache_dirs: [Path.join(dir, "cache")])

      assert reason == "ships a native file outside priv (ebin/libextra.so)"
    end

    test "an archive whose bytes are not the listed ones verifies nothing", %{tmp_dir: dir} do
      {_cache, name, _archive} = archive(dir)
      checksum = ~s(%{"#{name}" => "sha256:#{sha("other")}"}\n)
      ctx = project(dir, "circuits_gpio-2.1.3", %{"checksum.exs" => checksum})

      assert %{status: "skipped", reason: "native file not verified" <> _} =
               build(ctx, "aarch64-linux-gnu", @pass, cache_dirs: [Path.join(dir, "cache")])
    end

    test "a checksum file that is not plain data refuses every native file", %{tmp_dir: dir} do
      ctx = project(dir, "circuits_gpio-2.1.3", %{"checksum.exs" => "System.halt()"})

      assert %{
               status: "skipped",
               reason: "ships native files whose checksum file could not be read"
             } =
               build(ctx, "aarch64-linux-gnu")
    end

    test "a failed host compile is an error", %{tmp_dir: dir} do
      ctx = project(dir, "circuits_gpio-2.1.3")
      opts = [triple: "aarch64-linux-gnu"] ++ @facts
      host = %{status: :fail, error: "mix exited 1"}

      assert %{status: "error", reason: "host compile failed: mix exited 1"} =
               HostNative.build(ctx.project, "sample", host, @toolchain, @pass, opts)
    end
  end

  describe "the run" do
    test "the traced compile is judged as host-native; files and archives are archived; " <>
           "result.json carries the build",
         %{tmp_dir: dir} do
      {cache, name, archive} = archive(dir)
      checksum = ~s(%{"#{name}" => "sha256:#{sha(archive)}"}\n)

      ctx =
        project(dir, "circuits_gpio-2.1.3", %{"checksum-Elixir.Sample.Native.exs" => checksum})

      test_pid = self()

      trace = fn _project, "sample", _paths, opts ->
        send(test_pid, {:trace_opts, Keyword.take(opts, [:target, :host_native])})
        %{host: %{status: :pass, error: nil}, verdict: @pass}
      end

      input = %{
        run_id: "hn-1",
        package: %{name: "sample", version: "1.0.0"},
        image: %{name: "ncc-worker-toolchain:1.20-29", digest: "sha256:abc"},
        triple: "aarch64-linux-gnu"
      }

      paths = %{work_dir: dir, output_dir: Path.join(dir, "out")}
      File.mkdir_p!(Path.join(paths.output_dir, "logs"))

      assert {:ok, result} =
               NccWorker.Worker.host_native_project(
                 ctx.project,
                 input,
                 paths,
                 @toolchain,
                 "aarch64-linux-gnu",
                 host_trace: trace,
                 optional_deps: fn _, _ ->
                   send(test_pid, :optional_deps_resolved)
                   {[], []}
                 end,
                 facts: Map.new(@facts),
                 hex_home: ctx.home,
                 cache_dirs: [Path.join(dir, "cache")]
               )

      assert_received {:trace_opts, [target: "host", host_native: true]}
      # No optional dependency is added: a client matches a build only in an
      # env whose closure is exactly the build's, and a NIF package's optional
      # dependency is rustler (tokenizers, rustler_precompiled), which almost
      # no application locks. A build with it would miss for all of them.
      refute_received :optional_deps_resolved
      assert %{optional_deps: %{added: [], reason: "not_requested"}} = result
      assert %{scope: "host_native", systems: %{}, host_native_build: build} = result
      assert %{status: "pass", triple: "aarch64-linux-gnu"} = build
      refute Map.has_key?(build, :archives)
      assert [{path, %{"sha256" => sum}}] = result.host_native_archives
      assert path == Path.join(cache, name) and sum == sha(archive)

      files = Path.join(dir, "files")

      assert {:ok, %{files_archived: n}} =
               NccWorker.FileArchiver.archive_manifest_files(files, result, dir)

      assert n == length(build.file_manifest["ebin"]) + 2
      assert File.read!(Path.join(files, sum)) == archive
      assert File.exists?(Path.join(files, hd(build.native_files)["sha256"]))

      assert :ok = NccWorker.JsonWriter.write_result(paths.output_dir, result)
      json = paths.output_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert %{"scope" => "host_native", "host_native_build" => written} = json
      assert %{"status" => "pass", "origins" => [%{"archive" => ^name}]} = written
      refute Map.has_key?(json, "host_native_archives")
    end
  end
end
