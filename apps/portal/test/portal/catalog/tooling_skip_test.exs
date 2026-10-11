defmodule Portal.Catalog.ToolingSkipTest do
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog.{Package, Run, ToolingSkip}

  describe "tooling?/1" do
    test "matches the core tools, systems, toolchains and kiosk systems" do
      for name <-
            ~w(nerves nerves_bootstrap nerves_systems nerves_system_rpi4 nerves_system_br
               nerves_toolchain_ctng nerves_toolchain_aarch64_nerves_linux_gnu
               kiosk_system_rpi5) do
        assert ToolingSkip.tooling?(name), name
      end
    end

    # The libraries people put on devices are what the site exists to check.
    test "leaves Nerves libraries alone" do
      for name <- ~w(nerves_runtime nerves_pack nerves_time nerves_ssh vintage_net jason) do
        refute ToolingSkip.tooling?(name), name
      end
    end
  end

  describe "record/3" do
    test "records a skipped run the catalog reads like any other" do
      assert {:ok, run} = ToolingSkip.record("nerves_system_rpi4", "2.1.2", nil)
      assert run.overall_status == :skipped
      assert run.run_id == "tooling-nerves_system_rpi4-2.1.2"

      %{packages: %{"nerves_system_rpi4" => package}} =
        Portal.Catalog.latest_by_pkg_json("nerves_system_rpi4")

      assert package.native_components["compatibility_basis"] == "nerves_tooling"
      assert [system] = Map.values(package.systems)
      assert system.system_pkg == "nerves_tooling"
      assert system.status == "skipped"
    end

    test "is idempotent per version" do
      assert {:ok, first} = ToolingSkip.record("nerves", "2.0.0", nil)
      assert {:ok, second} = ToolingSkip.record("nerves", "2.0.0", nil)
      assert first.id == second.id
    end

    # The package upsert overwrites the description, and this path has none.
    test "keeps the description already on file" do
      Package
      |> Ash.Changeset.for_create(:create, %{name: "nerves", description: "Craft firmware"})
      |> Ash.create!(domain: Portal.Catalog)

      assert {:ok, _run} = ToolingSkip.record("nerves", "2.0.0", nil)

      assert {:ok, %{description: "Craft firmware"}} =
               Package
               |> Ash.Query.filter(name == "nerves")
               |> Ash.read_one(domain: Portal.Catalog)
    end
  end

  describe "record_existing/0" do
    test "supersedes the failed runs of tooling packages and nothing else" do
      for name <- ["nerves", "jason"] do
        package =
          Package
          |> Ash.Changeset.for_create(:create, %{name: name, latest_version: "1.0.0"})
          |> Ash.create!(domain: Portal.Catalog)

        Run
        |> Ash.Changeset.for_create(:create, %{
          run_id: "#{name}-real",
          package_id: package.id,
          version_tested: "1.0.0",
          image_digest: "sha256:real",
          overall_status: :fail,
          finished_at: DateTime.add(DateTime.utc_now(), -3600)
        })
        |> Ash.create!(domain: Portal.Catalog)
      end

      assert ToolingSkip.record_existing() == ["nerves"]

      %{packages: %{"nerves" => nerves}} = Portal.Catalog.latest_by_pkg_json("nerves")
      assert [%{system_pkg: "nerves_tooling"}] = Map.values(nerves.systems)

      refute Run
             |> Ash.Query.filter(run_id == "tooling-jason-1.0.0")
             |> Ash.exists?(domain: Portal.Catalog)
    end
  end
end
