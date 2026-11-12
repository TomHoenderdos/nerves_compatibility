defmodule Portal.BuilderKnownSystemAbiTest do
  # A build is told which system releases already have a library table, so
  # its targets on them skip reading the rootfs again.
  use Portal.DataCase, async: false

  alias Portal.Builder
  alias Portal.Catalog.SystemAbi

  @job %{
    run_id: "r1",
    image_name: "ncc-worker",
    image_digest: "sha256:x",
    package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
    systems_filter: nil
  }

  defp observe!(version, libs) do
    {:ok, _row} =
      SystemAbi.observe(%{
        system_pkg: "nerves_system_rpi4",
        version: version,
        source: "lock",
        toolchain_pkg: "nerves_toolchain_aarch64_nerves_linux_gnu",
        toolchain_version: "15.3.1",
        otp: "28.1.2",
        libs: libs
      })
  end

  test "a package build's input names every release with libraries, and only those" do
    observe!("2.2.2", %{"libc.so.6" => ["GLIBC_2.17"]})
    observe!("2.3.0", nil)

    input = Builder.worker_input(Builder.with_known_system_abi(@job))
    assert input["known_system_abi"] == ["nerves_system_rpi4@2.2.2"]
  end

  test "a run that builds no target gets no list" do
    observe!("2.2.2", %{"libc.so.6" => ["GLIBC_2.17"]})

    for mode <- ["warm_nerves", "system_abi", "toolchain", "argus_only"] do
      job = Builder.with_known_system_abi(Map.put(@job, :mode, mode))
      refute Map.has_key?(Builder.worker_input(job), "known_system_abi"), mode
    end
  end

  test "a system_abi run's input carries its pairs and no package" do
    pairs = [%{"system" => "nerves_system_rpi4", "version" => "2.3.0"}]

    input =
      Builder.worker_input(
        Map.merge(@job, %{package: nil, mode: "system_abi", system_abi: pairs})
      )

    assert input["mode"] == "system_abi"
    assert input["system_abi"] == pairs
    refute Map.has_key?(input, "package")
  end
end
