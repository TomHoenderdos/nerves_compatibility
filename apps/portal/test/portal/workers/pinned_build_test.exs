defmodule Portal.Workers.PinnedBuildTest do
  # A pinned build runs `ToolchainBuild`'s own path with the set as its input.
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

    def cleanup(_run_id), do: :ok
    def image_digest(_image), do: "sha256:toolchain-image"
  end

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    on_exit(fn -> Application.delete_env(:portal, :build_runner) end)
    :ok
  end

  defp pins(package) do
    deps = [%{"name" => "decimal", "hex" => "decimal", "version" => "2.3.0", "checksum" => @b}]

    hash =
      Compatibility.Pins.hash(%{
        package: package,
        version: "1.4.4",
        package_checksum: @a,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => @a, "deps" => deps}
  end

  defp args(package \\ "jason") do
    pins = pins(package)

    %{
      "package" => package,
      "version" => "1.4.4",
      "toolchain" => "1.19/28",
      "image" => "ncc-worker:elixir-1.19-otp-28",
      "builder_version" => 1,
      "target" => "pure_elixir",
      "pin_hash" => pins["hash"],
      "pins" => pins
    }
  end

  defp respond(exit_code) do
    Process.put(
      :stub_build_response,
      {:ok,
       %{
         exit_code: exit_code,
         result: if(exit_code == 0, do: %{"toolchain_build" => %{"status" => "pass"}}),
         files_dir: "/scratch/files",
         output_dir: "/scratch/out",
         log: ""
       }}
    )
  end

  test "the set goes to the worker as optional_deps \"pinned\", and the ingest is kind pinned" do
    respond(0)
    args = args()

    assert :ok = perform_job(PinnedBuild, args)
    assert_received {:build_args, build_args}
    assert build_args.mode == "toolchain"
    assert build_args.optional_deps == "pinned"
    assert build_args.pins == args["pins"]
    refute Map.has_key?(build_args, :world)

    assert [%Oban.Job{args: ingest}] = all_enqueued(worker: Ingest)
    assert ingest["kind"] == "pinned"
    assert ingest["pin_hash"] == args["pin_hash"]
    assert ingest["pins"] == args["pins"]
    refute Map.has_key?(ingest, "variant")
  end

  test "the deterministic sibling is asked for while the setting is on" do
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})
    respond(0)
    assert :ok = perform_job(PinnedBuild, args())
    assert_received {:build_args, %{deterministic: true}}
  end

  test "exit 11 writes a fail row under the pinned identity, never a toolchain build" do
    Package
    |> Ash.Changeset.for_create(:create, %{name: "pinpkg"})
    |> Ash.create!(domain: Catalog)

    respond(11)
    args = args("pinpkg")

    assert {:cancel, "lock policy violation"} = perform_job(PinnedBuild, args)

    assert [%Catalog.PinnedBuild{status: :fail, pin_hash: hash, target: "pure_elixir"}] =
             Catalog.PinnedBuild
             |> Ash.Query.filter(package.name == "pinpkg")
             |> Ash.read!(domain: Catalog)

    assert hash == args["pin_hash"]

    assert Catalog.ToolchainBuild
           |> Ash.Query.filter(package.name == "pinpkg")
           |> Ash.read!(domain: Catalog) == []
  end

  # Review M4: ToolchainBuild's exit 11 writes through the same row writer.
  test "exit 11 never replaces a served pass of the same identity" do
    package =
      Package
      |> Ash.Changeset.for_create(:create, %{name: "pinpass11"})
      |> Ash.create!(domain: Catalog)

    args = args("pinpass11")

    Catalog.PinnedBuild
    |> Ash.Changeset.for_create(:upsert, %{
      package_id: package.id,
      version: args["version"],
      pin_hash: args["pin_hash"],
      target: "pure_elixir",
      system_version: "",
      toolchain: args["toolchain"],
      builder_version: args["builder_version"],
      config_variant: "default",
      pins: args["pins"],
      status: :pass
    })
    |> Ash.create!(domain: Catalog)

    respond(11)
    assert {:cancel, "lock policy violation"} = perform_job(PinnedBuild, args)

    assert [%Catalog.PinnedBuild{status: :pass, attempted_at: %DateTime{}}] =
             Catalog.PinnedBuild
             |> Ash.Query.filter(package.name == "pinpass11")
             |> Ash.read!(domain: Catalog)
  end

  test "a set that does not validate or is not the job's is cancelled before anything runs" do
    bad = put_in(args(), ["pins", "deps"], [])
    assert {:cancel, _} = perform_job(PinnedBuild, bad)
    assert {:cancel, _} = perform_job(PinnedBuild, Map.put(args(), "pin_hash", @b))

    assert {:cancel, _} =
             perform_job(PinnedBuild, Map.put(args(), "target", "nerves_system_rpi4"))

    refute_received {:build_args, _}
  end

  test "a job inserted without a priority gets Portal.Pins' own, 3" do
    assert {:ok, %Oban.Job{priority: 3}} = args() |> PinnedBuild.new() |> Oban.insert()
  end

  test "NCC_INPUT carries the set" do
    pins = pins("jason")
    job = %{run_id: "r", image_name: "i", image_digest: "d", systems_filter: nil, pins: pins}
    assert Portal.Builder.worker_input(job)["pins"] == pins
    refute Map.has_key?(Portal.Builder.worker_input(Map.delete(job, :pins)), "pins")
  end

  # A firmware pinned build asks for its target's deterministic sibling as a
  # toolchain one does, while the setting is on.
  test "a firmware pinned build's args ask for the sibling while the setting is on" do
    args = %{
      "package" => "jason",
      "version" => "1.4.4",
      "target" => "nerves_system_rpi4",
      "system_version" => "2.1.2",
      "pins" => pins("jason")
    }

    assert %{deterministic: false} = Portal.Pins.FirmwareBuild.build_args(args, "r", "i", "d")
    {:ok, _} = Portal.Settings.save(%{deterministic_builds_enabled: true})
    assert %{deterministic: true} = Portal.Pins.FirmwareBuild.build_args(args, "r", "i", "d")
  end

  # Phase 2: a firmware pinned build names its one system's exact release.
  test "NCC_INPUT carries the system release override" do
    override = %{"nerves_system_rpi4" => "== 2.1.2"}

    job = %{
      run_id: "r",
      image_name: "i",
      image_digest: "d",
      systems_filter: ["nerves_system_rpi4"],
      systems_override: override
    }

    assert Portal.Builder.worker_input(job)["systems_override"] == override

    refute Map.has_key?(
             Portal.Builder.worker_input(%{job | systems_override: nil}),
             "systems_override"
           )
  end
end
