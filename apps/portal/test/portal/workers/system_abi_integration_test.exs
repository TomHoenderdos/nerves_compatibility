defmodule Portal.Workers.SystemAbiIntegrationTest do
  @moduledoc """
  End-to-end test of the worker's `system_abi` mode: `Portal.Builder.build/2`
  runs the real worker container (`ncc-worker:local` unless
  `NCC_DOCKER_IMAGE` names another) for one release of `nerves_system_rpi4`,
  and the `system_abi` entry of its `result.json` carries the release's
  toolchain, full OTP version and library table, which
  `Portal.Catalog.SystemAbi.observe_all/1` records.

  Excluded from `mix test` by default; `make test-integration` runs it.
  Requires a running Docker daemon, `make build`, and network access to
  Hex.pm and the Nerves system artifact host.
  """
  use Portal.DataCase, async: false

  alias Portal.Builder
  alias Portal.Catalog.SystemAbi

  @moduletag :integration
  @moduletag timeout: :timer.minutes(30)

  @pair %{"system" => "nerves_system_rpi4", "version" => "2.2.2"}

  setup do
    assert match?({_, 0}, System.cmd("docker", ["version"], stderr_to_stdout: true)),
           "docker daemon is not running"

    assert match?(
             {_, 0},
             System.cmd("docker", ["image", "inspect", Builder.docker_image()],
               stderr_to_stdout: true
             )
           ),
           "#{Builder.docker_image()} not built: run make build"

    run_id = "system_abi-it-#{System.unique_integer([:positive])}"
    on_exit(fn -> Builder.cleanup(run_id) end)
    {:ok, run_id: run_id}
  end

  test "reads a release's toolchain, OTP and libraries", %{run_id: run_id} do
    assert {:ok, %{exit_code: 0, result: result, log: log}} =
             Builder.build(%{run_id: run_id, mode: "system_abi", system_abi: [@pair]})

    assert result["scope"] == "system_abi", log
    assert [entry] = result["system_abi"]
    assert entry["system"] == "nerves_system_rpi4"
    assert entry["version"] == "2.2.2"
    refute Map.has_key?(entry, "error"), inspect(entry["error"])

    assert %{"package" => "nerves_toolchain_" <> _, "version" => toolchain_version} =
             entry["toolchain"]

    assert toolchain_version =~ ~r/\A\d+\.\d+\.\d+\z/
    assert entry["otp_full"] =~ ~r/\A\d+(\.\d+)+\z/
    assert %{"libc.so.6" => glibc} = entry["system_libs"]
    assert "GLIBC_2.17" in glibc

    IO.puts(
      "system_abi entry: " <>
        inspect(
          %{
            entry
            | "system_libs" =>
                Map.new(entry["system_libs"], fn {soname, versions} ->
                  {soname, length(versions)}
                end)
          },
          limit: :infinity
        )
    )

    SystemAbi.observe_all([entry])
    row = Repo.get_by!(SystemAbi, system_pkg: "nerves_system_rpi4", version: "2.2.2")
    assert row.source == "lock"
    assert row.otp == entry["otp_full"]
    assert row.libs["libc.so.6"] == Enum.sort(Enum.uniq(glibc))
  end
end
