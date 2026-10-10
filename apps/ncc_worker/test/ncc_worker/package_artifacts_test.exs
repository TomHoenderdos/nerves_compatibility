defmodule NccWorker.PackageArtifactsTest do
  use ExUnit.Case, async: true

  alias NccWorker.PackageArtifacts

  setup do
    build = Path.join(System.tmp_dir!(), "pkg_artifacts_#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(build) end)
    {:ok, build: build}
  end

  defp touch(path, content \\ "x") do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "finds a runtime package inside the release", %{build: build} do
    touch(Path.join(build, "rel/app/lib/jason-1.4.4/ebin/jason.beam"))
    touch(Path.join(build, "lib/jason/ebin/jason.beam"))

    assert PackageArtifacts.lib_dir(build, "jason") ==
             {:ok, Path.join(build, "rel/app/lib/jason-1.4.4")}
  end

  # A build-time dependency (`runtime: false`, like nerves itself) is compiled
  # but never copied into the release. Its compiled output is still the thing
  # to hash, and its absence from the release is not a build failure.
  test "falls back to the compiled build-time package outside the release", %{build: build} do
    touch(Path.join(build, "rel/app/lib/jason-1.4.4/ebin/jason.beam"))
    touch(Path.join(build, "lib/nerves/ebin/nerves.beam"))

    assert PackageArtifacts.lib_dir(build, "nerves") == {:ok, Path.join(build, "lib/nerves")}
  end

  test "a package that was never compiled is still not found", %{build: build} do
    touch(Path.join(build, "rel/app/lib/jason-1.4.4/ebin/jason.beam"))

    assert PackageArtifacts.lib_dir(build, "nerves") == {:error, :package_not_found}
  end

  test "a release entry for a longer name does not match a shorter one", %{build: build} do
    touch(Path.join(build, "rel/app/lib/nerves_runtime-0.13.13/ebin/a.beam"))
    touch(Path.join(build, "lib/nerves/ebin/nerves.beam"))

    assert PackageArtifacts.lib_dir(build, "nerves") == {:ok, Path.join(build, "lib/nerves")}
  end

  describe "with_error/2" do
    # The stored log tail is all a reader of a failed build sees; a failure the
    # worker raises after the last build command has to say so there.
    test "appends the worker's reason to the log tail" do
      assert PackageArtifacts.with_error("Firmware built successfully!\n", ":package_not_found") ==
               "Firmware built successfully!\n\n** ncc_worker: :package_not_found\n"
    end

    test "leaves the tail alone when there is no reason" do
      assert PackageArtifacts.with_error("ok\n", nil) == "ok\n"
    end

    test "a reason that isn't a string is inspected, not interpolated" do
      assert PackageArtifacts.with_error("x\n", {:deps_get_failed, "boom"}) ==
               ~s[x\n\n** ncc_worker: {:deps_get_failed, "boom"}\n]
    end

    test "handles a missing tail" do
      assert PackageArtifacts.with_error(nil, "boom") == "** ncc_worker: boom\n"
    end
  end
end
