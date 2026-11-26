defmodule Portal.Catalog.ModuleIndexRecheckTest do
  # Round 5, R3-5a: after each complete run, the served rows whose judge
  # recorded a declared-absent probe are re-checked against the new index;
  # a row that now collides is withheld, tagged, with an undo.
  use Portal.DataCase, async: false
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Catalog.{Ingestion, ModuleIndex}

  @money %{
    "kind" => "module_absent",
    "module" => "Elixir.Money",
    "declared" => ["ex_money"],
    "declared_apps" => ["ex_money"],
    "via" => "Code.ensure_loaded?/1"
  }

  defp served!(name, observations, lock \\ %{}) do
    {:ok, id} = Ingestion.ensure_package_id(name)

    %{rows: [[row_id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_toolchain_builds
          (id, package_id, version, toolchain, builder_version, variant, config_variant, status,
           compile_observations, deps_lock, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, '1.0.0', '1.20/29', 1, 'with', 'default', 'pass', $2, $3, now(), now())
        RETURNING id
        """,
        [Ecto.UUID.dump!(id), observations, lock]
      )

    row_id
  end

  defp revoked(id) do
    %{rows: [[at, reason]]} =
      Repo.query!(
        "SELECT revoked_at, revoked_reason FROM catalog_toolchain_builds WHERE id = $1",
        [id]
      )

    {at != nil, reason}
  end

  setup do
    now = NaiveDateTime.utc_now()

    Repo.insert_all("catalog_packages", [
      %{
        name: "money",
        hex_latest_version: nil,
        hex_downloads_recent: 398_436,
        inserted_at: now,
        updated_at: now
      },
      %{
        name: "ex_money",
        hex_latest_version: nil,
        hex_downloads_recent: 302_825,
        inserted_at: now,
        updated_at: now
      }
    ])

    stub = fn mod ->
      gz = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}.tar.gz")

      :ok =
        :erl_tar.create(String.to_charlist(gz), [{~c"lib/m.ex", "defmodule #{mod} do\nend\n"}], [
          :compressed
        ])

      bytes = File.read!(gz)
      tar = Path.join(System.tmp_dir!(), "rc-#{System.unique_integer([:positive])}.tar")

      :ok =
        :erl_tar.create(String.to_charlist(tar), [
          {~c"VERSION", "3"},
          {~c"contents.tar.gz", bytes}
        ])

      File.read!(tar)
    end

    tarballs = %{"money" => stub.("Money"), "ex_money" => stub.("Money")}
    sha = &(:sha256 |> :crypto.hash(&1) |> Base.encode16(case: :lower))

    %{
      opts: [
        registry: fn ->
          {:ok, %{"money" => {"1.14.0", "1.14.0"}, "ex_money" => {"5.24.2", "5.24.2"}}}
        end,
        tarball: fn n, _v -> {:ok, tarballs[n]} end,
        outer_checksum: fn n, _v -> {:ok, sha.(tarballs[n])} end
      ]
    }
  end

  test "a complete run withholds a served row that now collides, and the undo restores it",
       %{opts: opts} do
    colliding = served!("bitcrowd_like", %{"declared_absent" => [@money]})

    locked =
      served!("with_money", %{"declared_absent" => [@money]}, %{
        "money" => %{"version" => "1.14.0"}
      })

    plain = served!("plain", %{})

    assert %{complete: true, withheld: 1, generation: generation} = ModuleIndex.refresh(opts)
    assert {true, reason} = revoked(colliding)
    assert reason == ModuleIndex.withheld_reason(generation)
    assert revoked(locked) == {false, nil}
    assert revoked(plain) == {false, nil}

    # A dry run counts the rows that carry a record and what it would take.
    assert %{withheld: 0, checked: 1} = ModuleIndex.recheck(dry_run: true)

    assert ModuleIndex.undo_recheck(generation)["toolchain_build"] == 1
    assert revoked(colliding) == {false, nil}
  end

  # S10 round 5 (review U5, U6): a probe input is client 0.10's to decide
  # against each user's lock, by the batch's release index; the recheck
  # neither reads nor withholds a row for it, nor for a record it carries.
  test "a served probe input is not rechecked, nor a record it carries", %{opts: opts} do
    probe = fn definers ->
      %{
        "kind" => "probe",
        "of" => "module",
        "name" => "Elixir.Money",
        "answer" => "absent",
        "definers" => definers
      }
    end

    input_only = served_with_inputs!("stale_probe", [probe.(["ex_money"])])

    covered =
      served!("covered_record", %{"declared_absent" => [@money]})
      |> tap(&set_inputs!(&1, [probe.(["ex_money"])]))

    assert %{complete: true, withheld: 0} = ModuleIndex.refresh(opts)
    assert revoked(input_only) == {false, nil}
    assert revoked(covered) == {false, nil}
    # Only the row with a record is read, and it does not collide.
    assert %{checked: 1, withheld: 0} = ModuleIndex.recheck(dry_run: true)
  end

  defp served_with_inputs!(name, inputs),
    do: name |> served!(%{}) |> tap(&set_inputs!(&1, inputs))

  defp set_inputs!(id, inputs),
    do:
      Repo.query!("UPDATE catalog_toolchain_builds SET compile_inputs = $2 WHERE id = $1", [
        id,
        inputs
      ])

  # Round 6, R5-5: a build refused only because the index was not complete
  # is no final skip: after each complete run its toolchain build is queued
  # again, once.
  test "a complete run queues again the builds refused while it was not complete",
       %{opts: opts} do
    {:ok, id} = Ingestion.ensure_package_id("waiting_pkg")
    image = hd(Portal.Toolchains.images())

    not_complete =
      "compile-time probe of a dependency outside the closure: Elixir.Money via " <>
        "Code.ensure_loaded?/1 (module index not complete)"

    for {variant, reason} <- [{"with", not_complete}, {"without", "calls System.cmd/3"}] do
      Repo.query!(
        """
        INSERT INTO catalog_toolchain_builds
          (id, package_id, version, toolchain, builder_version, variant, config_variant, status,
           reason, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, '1.0.0', $2, $3, $4, 'default', 'skipped', $5, now(), now())
        """,
        [
          Ecto.UUID.dump!(id),
          image.toolchain,
          Portal.Toolchains.builder_version(),
          variant,
          reason
        ]
      )
    end

    assert %{complete: true, requeued: 1} = ModuleIndex.refresh(opts)

    assert_enqueued(
      worker: Portal.Workers.ToolchainBuild,
      args: %{
        package: "waiting_pkg",
        version: "1.0.0",
        variant: "with",
        reason: "module_index_complete"
      }
    )

    refute_enqueued(worker: Portal.Workers.ToolchainBuild, args: %{variant: "without"})
    # The job is unique: a second complete run does not queue it twice.
    assert %{complete: true} = ModuleIndex.refresh(opts)
    assert length(all_enqueued(worker: Portal.Workers.ToolchainBuild)) == 1
  end

  # S10 round 4: every kind a module probe or record reaches at ingest. A
  # pinned build refused that way is queued again from its own pins; a held
  # pure_elixir result is judged again in place, and published when it
  # passes.
  test "a complete run queues the pinned builds and re-judges the held results it refused",
       %{opts: opts} do
    not_complete =
      "compile-time probe of a dependency outside the closure: Elixir.Money via " <>
        "Code.ensure_loaded?/1 (module index not complete)"

    image = hd(Portal.Toolchains.images())
    {:ok, pkg} = Ingestion.ensure_package_id("pinned_waiting")
    pins = %{"hash" => "h1", "deps" => []}

    for {target, system_version, hash} <- [
          {"pure_elixir", "", "h1"},
          {"nerves_system_rpi4", "1.31.0", "h2"}
        ] do
      Repo.query!(
        """
        INSERT INTO catalog_pinned_builds
          (id, package_id, version, pin_hash, target, system_version, toolchain, builder_version,
           config_variant, pins, status, reason, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, '1.0.0', $2, $3, $4, $5, $6, 'default', $7, 'skipped', $8,
                now(), now())
        """,
        [
          Ecto.UUID.dump!(pkg),
          hash,
          target,
          system_version,
          image.toolchain,
          Portal.Toolchains.builder_version(),
          %{pins | "hash" => hash},
          not_complete
        ]
      )
    end

    {:ok, pe} = Ingestion.ensure_package_id("pe_waiting")

    %{rows: [[run_id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_runs (id, run_id, package_id, version_tested, overall_status, image_digest,
                                  inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'r-pew', $1, '1.0.0', 'pass', 'sha256:x', now(), now())
        RETURNING id
        """,
        [Ecto.UUID.dump!(pe)]
      )

    # One whose record names only ex_money's own module, one that collides.
    own = %{@money | "module" => "Elixir.Cldr.Money"}

    ids =
      for record <- [own, @money] do
        %{rows: [[sr]]} =
          Repo.query!(
            """
            INSERT INTO catalog_system_results (id, run_id, system_pkg, status, declared_absent,
                                                unpublished_at, unpublished_reason, inserted_at, updated_at)
            VALUES (gen_random_uuid(), $1, 'pure_elixir', 'pass', $2, now(), $3, now(), now())
            RETURNING id
            """,
            [run_id, [record], not_complete]
          )

        sr
      end

    assert %{complete: true, requeued: 3} = ModuleIndex.refresh(opts)

    assert_enqueued(
      worker: Portal.Workers.PinnedBuild,
      args: %{"package" => "pinned_waiting", "target" => "pure_elixir", "image" => image.image}
    )

    assert_enqueued(
      worker: Portal.Workers.PinnedBuild,
      args: %{
        "package" => "pinned_waiting",
        "target" => "nerves_system_rpi4",
        "system_version" => "1.31.0"
      }
    )

    held = fn id ->
      Repo.query!(
        "SELECT unpublished_at IS NOT NULL, unpublished_reason FROM catalog_system_results WHERE id = $1",
        [id]
      ).rows
    end

    [published, collides] = ids
    assert held.(published) == [[false, nil]]
    assert [[true, reason]] = held.(collides)
    assert reason =~ "also defined by money"
  end

  # S10 review U7: a host-native build refused for an incomplete index is a
  # `fail` row; it is queued again, not left as a final verdict.
  test "a complete run queues the host-native builds it refused", %{opts: opts} do
    {:ok, pkg} = Ingestion.ensure_package_id("hn_waiting")

    Repo.query!(
      """
      INSERT INTO catalog_host_native_builds
        (id, package_id, version, toolchain, triple, builder_version, status, reason,
         inserted_at, updated_at)
      VALUES (gen_random_uuid(), $1, '1.0.0', '1.20/29', 'x86_64-linux-gnu', $2, 'fail', $3,
              now(), now())
      """,
      [
        Ecto.UUID.dump!(pkg),
        Portal.HostNative.builder_version(),
        "refused at ingest: compile-time probe of a dependency outside the closure: " <>
          "Elixir.Money via Code.ensure_loaded?/1 (module index not complete)"
      ]
    )

    assert %{complete: true, requeued: 1} = ModuleIndex.refresh(opts)

    assert_enqueued(
      worker: Portal.Workers.HostNativeBuild,
      args: %{"package" => "hn_waiting", "triple" => "x86_64-linux-gnu"}
    )
  end

  # R5-6: a served pure_elixir result with a record is re-checked too, and
  # withheld as unpublished with the generation's reason.
  test "a served pure_elixir result that now collides is withheld, and the undo restores it",
       %{opts: opts} do
    {:ok, id} = Ingestion.ensure_package_id("pe_like")

    %{rows: [[run_id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_runs (id, run_id, package_id, version_tested, overall_status, image_digest,
                                  inserted_at, updated_at)
        VALUES (gen_random_uuid(), 'r-pe', $1, '1.0.0', 'pass', 'sha256:x', now(), now())
        RETURNING id
        """,
        [Ecto.UUID.dump!(id)]
      )

    %{rows: [[sr]]} =
      Repo.query!(
        """
        INSERT INTO catalog_system_results (id, run_id, system_pkg, status, declared_absent,
                                            inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, 'pure_elixir', 'pass', $2, now(), now())
        RETURNING id
        """,
        [run_id, [@money]]
      )

    assert %{complete: true, withheld: 1, generation: generation} = ModuleIndex.refresh(opts)

    %{rows: [[at, reason]]} =
      Repo.query!(
        "SELECT unpublished_at, unpublished_reason FROM catalog_system_results WHERE id = $1",
        [sr]
      )

    assert at != nil
    assert reason == ModuleIndex.withheld_reason(generation)
    assert ModuleIndex.undo_recheck(generation)["system_result"] == 1

    assert Repo.query!("SELECT unpublished_at FROM catalog_system_results WHERE id = $1", [sr]).rows ==
             [[nil]]
  end

  # Round 6, R5-7: the undo clears only its own withholding; a dry run
  # writes nothing.
  test "the undo leaves a host-native revocation made by something else alone, and a dry run writes nothing",
       %{opts: opts} do
    {:ok, id} = Ingestion.ensure_package_id("hn_like")

    insert_hn = fn revoked_at ->
      %{rows: [[row]]} =
        Repo.query!(
          """
          INSERT INTO catalog_host_native_builds
            (id, package_id, version, toolchain, triple, builder_version, status, compile_observations,
             deps_lock, revoked_at, inserted_at, updated_at)
          VALUES (gen_random_uuid(), $1, '1.0.0', '1.20/29', 'aarch64-linux-gnu', 1, 'pass', $2, '{}',
                  $3, now(), now())
          RETURNING id
          """,
          [Ecto.UUID.dump!(id), %{"declared_absent" => [@money]}, revoked_at]
        )

      row
    end

    ours = insert_hn.(nil)
    assert %{complete: true, withheld: 1, generation: generation} = ModuleIndex.refresh(opts)

    # Something else revokes ours again after the undo; a second recheck
    # entry for the same row must not let the undo clear it.
    assert ModuleIndex.undo_recheck(generation)["host_native_build"] == 1
    other_at = ~U[2026-11-21 12:00:00.000000Z]

    Repo.query!("UPDATE catalog_host_native_builds SET revoked_at = $2 WHERE id = $1", [
      ours,
      other_at
    ])

    assert ModuleIndex.undo_recheck(generation)["host_native_build"] == 0

    assert Repo.query!("SELECT revoked_at FROM catalog_host_native_builds WHERE id = $1", [ours]).rows ==
             [[DateTime.to_naive(other_at)]]

    before =
      Repo.query!("SELECT withheld FROM catalog_module_index_runs WHERE generation = $1", [
        generation
      ]).rows

    assert %{withheld: 0} = ModuleIndex.recheck(dry_run: true, generation: generation)

    assert Repo.query!("SELECT withheld FROM catalog_module_index_runs WHERE generation = $1", [
             generation
           ]).rows ==
             before
  end

  test "an incomplete run withholds nothing", %{opts: opts} do
    colliding = served!("bitcrowd_like", %{"declared_absent" => [@money]})
    failing = Keyword.put(opts, :tarball, fn _n, _v -> {:error, :hex_registry_unavailable} end)
    assert %{complete: false, withheld: nil} = ModuleIndex.refresh(failing)
    assert revoked(colliding) == {false, nil}
    assert %{skipped: :not_complete} = ModuleIndex.recheck(dry_run: true)
  end
end
