defmodule Portal.Workers.PinnedFirmwareBuildTest do
  # A pinned firmware build (lock-driven builds spec, phase 2): one target at
  # its exact release, on the local `:builds` queue, outside `Build` and Runs.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.Package
  alias Portal.Workers.{Ingest, PinnedBuild}

  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), {:build_args, args})
      Process.get(:stub_build_response)
    end

    def cleanup(run_id), do: send(self(), {:cleanup, run_id})
    def image_digest(_image), do: Process.get(:stub_digest, "sha256:firmware-image")
  end

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    :ok
  end

  defp pins(package) do
    deps = [
      %{"name" => "elixir_make", "hex" => "elixir_make", "version" => "0.8.4", "checksum" => @b}
    ]

    hash =
      Compatibility.Pins.hash(%{
        package: package,
        version: "1.8.0",
        package_checksum: @a,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => @a, "deps" => deps}
  end

  defp args(package \\ "muontrap") do
    pins = pins(package)

    %{
      "package" => package,
      "version" => "1.8.0",
      "toolchain" => "1.20/29",
      "builder_version" => 1,
      "target" => "nerves_system_rpi4",
      "system_version" => "2.1.2",
      "pin_hash" => pins["hash"],
      "pins" => pins
    }
  end

  defp respond(response), do: Process.put(:stub_build_response, response)

  defp exit_code(code, result \\ nil),
    do:
      respond(
        {:ok,
         %{
           exit_code: code,
           result: result,
           files_dir: "/scratch/files",
           output_dir: "/scratch/out",
           log: ""
         }}
      )

  defp package!(name) do
    Package
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!(domain: Catalog)
  end

  defp pinned_rows(name) do
    Catalog.PinnedBuild
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Catalog)
  end

  defp runs(name) do
    Catalog.Run
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Catalog)
  end

  test "the worker builds the one target at its exact release with the set, nothing else" do
    exit_code(0, %{"systems" => %{}})
    args = args()

    assert :ok = perform_job(PinnedBuild, args, queue: :builds)
    assert_received {:build_args, build_args}

    assert build_args.systems_filter == ["nerves_system_rpi4"]
    assert build_args.systems_override == %{"nerves_system_rpi4" => "== 2.1.2"}
    assert build_args.optional_deps == "pinned"
    assert build_args.pins == args["pins"]
    assert build_args.image_digest == "sha256:firmware-image"
    refute Map.has_key?(build_args, :mode)

    for key <- [:argus, :firmware_world, :world, :toolchain, :scan_request_id] do
      refute Map.has_key?(build_args, key), inspect(key)
    end
  end

  test "a finished build is ingested as kind pinned with its target and release" do
    exit_code(0, %{"systems" => %{}})
    args = args()

    assert :ok = perform_job(PinnedBuild, args, queue: :builds)
    refute_received {:cleanup, _}

    assert [%Oban.Job{args: ingest, queue: queue}] = all_enqueued(worker: Ingest)
    assert queue == Portal.NodeQueue.name()

    assert %{
             "kind" => "pinned",
             "package" => "muontrap",
             "version" => "1.8.0",
             "toolchain" => "1.20/29",
             "target" => "nerves_system_rpi4",
             "system_version" => "2.1.2",
             "image_digest" => "sha256:firmware-image"
           } = ingest

    assert ingest["pin_hash"] == args["pin_hash"]
    assert ingest["pins"] == args["pins"]
    assert ingest["builder_version"] == 1
  end

  test "exit 11 writes a fail row under the target and release, never a run" do
    package!("pinfw11")
    exit_code(11)

    assert {:cancel, "lock policy violation"} =
             perform_job(PinnedBuild, args("pinfw11"), queue: :builds)

    assert [%Catalog.PinnedBuild{status: :fail, target: "nerves_system_rpi4"} = row] =
             pinned_rows("pinfw11")

    assert row.system_version == "2.1.2"
    assert row.toolchain == "1.20/29"
    assert runs("pinfw11") == []
  end

  test "a build past the wall clock is a fail row, not a run, and is not retried" do
    package = package!("pinfwto")
    respond({:error, {:build_timeout, 7200, "ctr"}})

    assert {:cancel, _} = perform_job(PinnedBuild, args("pinfwto"), queue: :builds)
    assert_received {:cleanup, _}

    assert [%Catalog.PinnedBuild{status: :fail, reason: "build timed out after 7200s"}] =
             pinned_rows("pinfwto")

    assert runs("pinfwto") == []
    assert Ash.get!(Package, package.id, domain: Catalog).latest_version == nil
  end

  test "the last attempt of a retryable failure writes an error row" do
    package!("pinfwerr")
    exit_code(10)

    assert {:error, _} =
             perform_job(PinnedBuild, args("pinfwerr"),
               queue: :builds,
               attempt: 1,
               max_attempts: 2
             )

    assert pinned_rows("pinfwerr") == []

    assert {:error, _} =
             perform_job(PinnedBuild, args("pinfwerr"),
               queue: :builds,
               attempt: 2,
               max_attempts: 2
             )

    assert [%Catalog.PinnedBuild{status: :error}] = pinned_rows("pinfwerr")
  end

  test "a host that cannot build defers the job" do
    respond({:error, :egress_filter_missing})
    assert {:snooze, _} = perform_job(PinnedBuild, args(), queue: :builds)

    Process.put(:stub_digest, "sha256:" <> String.duplicate("0", 64))
    assert {:snooze, _} = perform_job(PinnedBuild, args(), queue: :builds)
  end

  test "an unknown system, or a release that is not one version, is cancelled before any build" do
    cases = [
      Map.put(args(), "target", "nerves_system_rpi3"),
      Map.put(args(), "system_version", "~> 2.1"),
      Map.put(args(), "system_version", "== 2.1.2"),
      Map.delete(args(), "system_version"),
      Map.put(args(), "target", "pure_elixir")
    ]

    for args <- cases do
      assert {:cancel, _} = perform_job(PinnedBuild, args, queue: :builds), inspect(args)
    end

    refute_received {:build_args, _}
  end
end
