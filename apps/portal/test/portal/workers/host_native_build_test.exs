defmodule Portal.Workers.HostNativeBuildTest do
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  import ExUnit.CaptureLog

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.HostNativeBuild, as: Row
  alias Portal.Catalog.Package
  alias Portal.Workers.{HostNativeBuild, Ingest}

  # Mimics `Portal.Builder` (`config :portal, :build_runner`).
  defmodule StubBuilder do
    def build(args, _opts \\ []) do
      send(self(), {:build_args, args})
      Process.get(:stub_build_response)
    end

    def cleanup(run_id) do
      send(self(), {:cleanup, run_id})
      :ok
    end

    def image_digest(_image), do: "sha256:hn-image"
  end

  @args %{
    "package" => "fx_nif",
    "version" => "1.0.0",
    "toolchain" => "1.20/29",
    "triple" => "x86_64-linux-gnu",
    "builder_version" => 1
  }

  setup do
    Application.put_env(:portal, :build_runner, StubBuilder)
    Application.put_env(:portal, Portal.HostNative, triple: "x86_64-linux-gnu")
    toolchains = Application.get_env(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.put(toolchains, :images, [%{toolchain: "1.20/29", image: "tc:1.20-29"}])
    )

    on_exit(fn ->
      Application.delete_env(:portal, :build_runner)
      Application.delete_env(:portal, Portal.HostNative)
      Application.put_env(:portal, Portal.Toolchains, toolchains)
    end)

    {:ok, _} = Portal.Settings.save(%{host_native_enabled: true})
    :ok
  end

  defp respond(exit_code) do
    result = if exit_code == 0, do: %{"host_native_build" => %{"status" => "pass"}}
    Process.put(:stub_build_response, {:ok, %{exit_code: exit_code, result: result, log: ""}})
  end

  defp rows(name) do
    Row
    |> Ash.Query.filter(package.name == ^name)
    |> Ash.read!(domain: Catalog)
  end

  test "a passing build is ingested on this node with the job's identity" do
    respond(0)
    assert :ok = perform_job(HostNativeBuild, @args)

    assert_received {:build_args, %{mode: "host_native", triple: "x86_64-linux-gnu"} = build}
    assert build.toolchain == %{elixir: "1.20", otp: "29"}
    assert build.image == "tc:1.20-29"

    assert [%{args: args, queue: queue}] = all_enqueued(worker: Ingest)
    assert queue == Portal.NodeQueue.name()

    assert %{"kind" => "host_native", "triple" => "x86_64-linux-gnu", "toolchain" => "1.20/29"} =
             args
  end

  test "a host refusal with the auto-pause running pauses this node's queue" do
    Portal.AutoPauseStub.start!()
    Process.put(:stub_build_response, {:error, :egress_filter_missing})

    capture_log(fn -> assert {:snooze, 60} = perform_job(HostNativeBuild, @args) end)

    assert_received {:auto_pause, :pause, "host_native_x86_64"}
    assert Portal.AutoPauseStub.held_check("host_native_x86_64") == :egress
  end

  test "nothing is built while the setting is off" do
    {:ok, _} = Portal.Settings.save(%{host_native_enabled: false})
    respond(0)
    assert {:cancel, "host-native builds are off"} = perform_job(HostNativeBuild, @args)
    refute_received {:build_args, _}
  end

  test "a node of another triple never builds the job" do
    respond(0)
    args = %{@args | "triple" => "aarch64-linux-gnu"}
    assert {:cancel, "this node builds" <> _} = perform_job(HostNativeBuild, args)
    refute_received {:build_args, _}
  end

  test "a lock policy violation writes a fail row" do
    Package
    |> Ash.Changeset.for_create(:create, %{name: "fx_nif"})
    |> Ash.create!(domain: Catalog)

    respond(11)

    assert {:cancel, "lock policy violation"} = perform_job(HostNativeBuild, @args)
    assert [%{status: :fail, triple: "x86_64-linux-gnu"}] = rows("fx_nif")
  end

  test "the last failed attempt writes an error row" do
    Package
    |> Ash.Changeset.for_create(:create, %{name: "fx_nif"})
    |> Ash.create!(domain: Catalog)

    respond(10)

    assert {:error, "worker/runner exit 10"} = perform_job(HostNativeBuild, @args, attempt: 2)
    assert [%{status: :error}] = rows("fx_nif")
  end
end
