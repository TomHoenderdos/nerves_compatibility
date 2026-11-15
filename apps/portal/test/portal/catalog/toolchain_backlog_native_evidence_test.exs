defmodule Portal.Catalog.ToolchainBacklogNativeEvidenceTest do
  # The toolchain backlog's pure-BEAM gate (`@pure_beam_clause`): a package
  # the mix.exs grep tags with a NIF or port language is still nominated when
  # its firmware builds say it builds nothing native: some passing target
  # build of its own with no ELF priv file (`native = false`) and none that
  # has one. rustler_precompiled (`nif_language: rust` from its own app name
  # and its optional rustler dependency) builds no native file on any Nerves
  # target. The backlog only decides what is tried; the worker's judge
  # decides what is served.
  # Not async: swaps the `Portal.Toolchains` application env.
  use Portal.DataCase, async: false

  require Ash.Query

  alias Portal.Catalog
  alias Portal.Catalog.{Ingestion, Run, SystemResult}

  @rust %{"nif_language" => "rust", "port_languages" => []}
  @port %{"nif_language" => nil, "port_languages" => ["c"]}

  setup do
    previous = Application.fetch_env!(:portal, Portal.Toolchains)

    Application.put_env(
      :portal,
      Portal.Toolchains,
      Keyword.merge(previous,
        builder_version: 1,
        images: [%{toolchain: "1.19/28", image: "ncc-worker:elixir-1.19-otp-28"}]
      )
    )

    on_exit(fn -> Application.put_env(:portal, Portal.Toolchains, previous) end)
    :ok
  end

  # A run of `name` 1.0.0 with a passing host compile and the given target
  # results, `{system_pkg, status, native}` (`native` as the ELF facts
  # record it; `:unset` leaves it null).
  defp run!(name, native_components, targets, version \\ "1.0.0") do
    systems =
      Map.new([
        {"host", %{"status" => "pass"}} | for({s, st, _} <- targets, do: {s, %{"status" => st}})
      ])

    run_id = "run-#{name}-#{System.unique_integer([:positive])}"

    {:ok, _run} =
      Ingestion.ingest(
        %{
          "package" => %{
            "name" => name,
            "version" => version,
            "native_components" => native_components
          },
          "finished_at" => "2026-10-20T10:00:00Z",
          "systems" => systems
        },
        %{
          run_id: run_id,
          image_digest: "sha256:x",
          files_dir: System.tmp_dir!(),
          package: name,
          version: version
        }
      )

    run = Run |> Ash.Query.filter(run_id == ^run_id) |> Ash.read_one!(domain: Catalog)

    for {system_pkg, _status, native} <- targets, native != :unset do
      SystemResult
      |> Ash.Query.filter(run_id == ^run.id and system_pkg == ^system_pkg)
      |> Ash.read_one!(domain: Catalog)
      |> Ash.Changeset.for_update(:store_elf_facts, %{
        native: native,
        portable: true,
        elf_needs: %{}
      })
      |> Ash.update!(domain: Catalog)
    end

    run
  end

  defp names,
    do: Catalog.toolchain_backlog("1.19/28", 1, 100) |> Enum.map(& &1.package) |> Enum.uniq()

  test "a grep-tagged package with beam-only firmware builds is nominated" do
    run!("rustler_precompiled", @rust, [{"nerves_system_rpi4", "pass", false}])

    run!("portish", @port, [
      {"nerves_system_rpi4", "pass", false},
      {"nerves_system_bbb", "pass", false}
    ])

    assert Enum.sort(names()) == ["portish", "rustler_precompiled"]
  end

  test "one passing firmware build with a native file keeps it out" do
    run!("tokenizers", @rust, [
      {"nerves_system_rpi4", "pass", false},
      {"nerves_system_bbb", "pass", true}
    ])

    # In another version's run too.
    run!("evision", @rust, [{"nerves_system_rpi4", "pass", false}], "1.0.0")
    run!("evision", @rust, [{"nerves_system_rpi4", "pass", true}], "1.1.0")
    assert names() == []
  end

  test "no firmware evidence keeps the grep's answer" do
    # Only a host compile, a target whose facts were never read, a failing
    # target, and a passing one without priv facts.
    run!("hostonly", @rust, [])
    run!("unread", @rust, [{"nerves_system_rpi4", "pass", :unset}])
    run!("failing", @rust, [{"nerves_system_rpi4", "fail", false}])
    assert names() == []
  end

  test "a revoked run is no evidence" do
    run = run!("revoked", @rust, [{"nerves_system_rpi4", "pass", false}])
    run |> Ash.Changeset.for_update(:revoke, %{}) |> Ash.update!(domain: Catalog)
    # A later run of its own with a passing host compile and no targets.
    run!("revoked", @rust, [])
    assert names() == []
  end

  test "a pure package is nominated as before" do
    run!("plain", %{"nif_language" => nil, "port_languages" => []}, [])
    assert names() == ["plain"]
  end
end
