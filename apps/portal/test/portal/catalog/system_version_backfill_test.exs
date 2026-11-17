defmodule Portal.Catalog.SystemVersionBackfillTest do
  use Portal.DataCase, async: true

  alias Portal.Catalog.SystemVersionBackfill

  @rpi4 "nerves_system_rpi4"
  @trellis "nerves_system_trellis"

  # Hex's release timeline for the two systems, as `Portal.HexPm.release_times/1`
  # returns it.
  @releases %{
    @rpi4 => [
      %{version: "2.2.0", published_at: ~U[2026-10-16 17:48:45Z], retired: false},
      %{version: "2.2.1", published_at: ~U[2026-10-23 00:29:39Z], retired: false},
      %{version: "2.2.2", published_at: ~U[2026-11-10 20:17:26Z], retired: false}
    ],
    @trellis => [
      %{version: "0.6.0", published_at: ~U[2026-10-16 17:48:26Z], retired: false},
      %{version: "0.6.1", published_at: ~U[2026-10-23 00:29:04Z], retired: false},
      %{version: "0.6.2", published_at: ~U[2026-11-10 01:25:07Z], retired: false}
    ]
  }

  @closure %{"jason" => %{"version" => "1.4.4", "checksum" => "outer"}}

  defp releases(overrides \\ %{}) do
    table = Map.merge(@releases, overrides)

    fn name ->
      case Map.fetch(table, name) do
        {:ok, :unavailable} -> {:error, :hex_api_unavailable}
        {:ok, list} -> {:ok, list}
        :error -> {:error, :unknown_package}
      end
    end
  end

  defp package!(name) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_packages (id, name, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
        RETURNING id
        """,
        [name]
      )

    id
  end

  # A run of `package` finished at `finished_at` (ingested five minutes later),
  # with `deps_lock` as its closure.
  defp run!(finished_at, opts \\ []) do
    package_id = package!(Keyword.get(opts, :package, "circuits_gpio"))
    inserted_at = Keyword.get(opts, :inserted_at, NaiveDateTime.add(finished_at, 300))

    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_runs
          (id, run_id, package_id, version_tested, image_digest, overall_status,
           deps_lock, finished_at, inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, '2.1.3', 'sha256:x', 'pass', $3, $4, $5, $5)
        RETURNING id
        """,
        [
          "run-#{System.unique_integer([:positive])}",
          package_id,
          Keyword.get(opts, :deps_lock, @closure),
          finished_at,
          inserted_at
        ]
      )

    id
  end

  defp result!(run_id, system_pkg, opts \\ []) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        INSERT INTO catalog_system_results
          (id, run_id, system_pkg, system_version, status, deps_lock, carried_from_run_id,
           inserted_at, updated_at)
        VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6,
                now() AT TIME ZONE 'utc', now() AT TIME ZONE 'utc')
        RETURNING id
        """,
        [
          run_id,
          system_pkg,
          Keyword.get(opts, :version),
          Keyword.get(opts, :status, "pass"),
          Keyword.get(opts, :deps_lock),
          Keyword.get(opts, :carried_from)
        ]
      )

    Ecto.UUID.load!(id)
  end

  defp version_of(id) do
    %{rows: [[version]]} =
      Repo.query!("SELECT system_version FROM catalog_system_results WHERE id = $1", [
        Ecto.UUID.dump!(id)
      ])

    version
  end

  # A recorded resolution of `system_pkg` in the same release interval: what
  # the backfill corroborates its answer against.
  defp recorded!(system_pkg, version, finished_at \\ ~N[2026-10-28 09:00:00]) do
    finished_at |> run!() |> result!(system_pkg, version: version)
  end

  defp null_row!(system_pkg \\ @rpi4, opts \\ []) do
    finished_at = Keyword.get(opts, :finished_at, ~N[2026-10-27 10:00:00])

    finished_at
    |> run!(opts)
    |> result!(system_pkg, Keyword.take(opts, [:deps_lock, :status]))
  end

  test "counts a provable row, then fills it, recording what it did" do
    recorded!(@rpi4, "2.2.1")
    id = null_row!()

    assert {:dry_run, report} = SystemVersionBackfill.fill(releases: releases())
    assert report.candidates == 1
    assert report.provable == 1
    assert report.by_version == %{"#{@rpi4}@2.2.1" => 1}
    assert report.left_null == %{}
    assert version_of(id) == nil

    assert {:filled, 1, %{filled_at: %DateTime{} = filled_at}} =
             SystemVersionBackfill.fill(dry_run: false, releases: releases())

    assert version_of(id) == "2.2.1"

    assert [%{filled_at: ^filled_at, results: 1, by_version: %{"#{@rpi4}@2.2.1" => 1}}] =
             SystemVersionBackfill.backfills()

    # Idempotent: nothing is left to fill.
    assert {:filled, 0, _} = SystemVersionBackfill.fill(dry_run: false, releases: releases())
  end

  test "undo puts back only the rows that still carry the value it filled" do
    recorded!(@rpi4, "2.2.1")
    kept = null_row!()
    changed = null_row!()

    {:filled, 2, %{filled_at: filled_at}} =
      SystemVersionBackfill.fill(dry_run: false, releases: releases())

    Repo.query!("UPDATE catalog_system_results SET system_version = '9.9.9' WHERE id = $1", [
      Ecto.UUID.dump!(changed)
    ])

    assert {:restored, 1} = SystemVersionBackfill.undo(filled_at)
    assert version_of(kept) == nil
    assert version_of(changed) == "9.9.9"

    assert {:restored, 0} = SystemVersionBackfill.undo(filled_at)
  end

  test "a row it filled is not evidence for the rows it has not filled yet" do
    recorded = recorded!(@rpi4, "2.2.1")
    null_row!()
    null_row!()

    assert {:filled, 1, _} =
             SystemVersionBackfill.fill(dry_run: false, limit: 1, releases: releases())

    # The one recorded resolution goes; what is left is the row the backfill
    # wrote itself, which corroborates nothing.
    Repo.query!("DELETE FROM catalog_system_results WHERE id = $1", [Ecto.UUID.dump!(recorded)])

    assert {:dry_run, %{provable: 0, left_null: %{uncorroborated: 1}} = report} =
             SystemVersionBackfill.fill(releases: releases())

    assert report.corroboration["#{@rpi4}@2.2.1"] == %{agree: 0, disagree: 0}
  end

  test "fills at most `limit` rows per call" do
    recorded!(@rpi4, "2.2.1")
    for _ <- 1..3, do: null_row!()

    assert {:filled, 2, _} =
             SystemVersionBackfill.fill(dry_run: false, limit: 2, releases: releases())

    assert {:filled, 1, _} =
             SystemVersionBackfill.fill(dry_run: false, limit: 2, releases: releases())

    assert_raise ArgumentError, fn -> SystemVersionBackfill.fill(limit: 0) end
  end

  test "a carried copy is judged by the run that built it" do
    recorded!(@trellis, "0.6.1")
    builder = run!(~N[2026-10-27 15:51:00])
    source = result!(builder, @trellis)
    # Carried by a run ingested after 0.6.2 was published: the copy still
    # names the build made before it.
    carrier = run!(~N[2026-11-12 13:28:00])
    copy = result!(carrier, @trellis, carried_from: builder)

    assert {:filled, 2, _} = SystemVersionBackfill.fill(dry_run: false, releases: releases())
    assert version_of(source) == "0.6.1"
    assert version_of(copy) == "0.6.1"
  end

  describe "leaves a row NULL and counts it" do
    setup do
      recorded!(@rpi4, "2.2.1")
      :ok
    end

    test "when a release of the system was published while the build may have run" do
      id = null_row!(@rpi4, finished_at: ~N[2026-11-10 21:00:00])

      assert {:dry_run, %{provable: 0, left_null: %{release_in_window: 1}}} =
               SystemVersionBackfill.fill(releases: releases())

      assert {:filled, 0, _} = SystemVersionBackfill.fill(dry_run: false, releases: releases())
      assert version_of(id) == nil
    end

    test "when the build may have run within a day of a release" do
      null_row!(@rpi4, finished_at: ~N[2026-10-23 20:00:00])

      assert {:dry_run, %{left_null: %{release_in_window: 1}}} =
               SystemVersionBackfill.fill(releases: releases())
    end

    test "when the closure names a Nerves system or toolchain package" do
      null_row!(@rpi4, deps_lock: %{"nerves_system_br" => %{"version" => "1.35.2"}})

      null_row!(@rpi4,
        deps_lock: %{"nerves_toolchain_aarch64_nerves_linux_gnu" => %{"version" => "15.3.0"}}
      )

      assert {:dry_run, %{provable: 0, left_null: %{closure_names_nerves: 2}}} =
               SystemVersionBackfill.fill(releases: releases())
    end

    test "when the row's own optional-dependency lock names one" do
      null_row!(@rpi4) |> then(&set_own_lock(&1, %{"nerves_system_br" => %{}}))

      assert {:dry_run, %{left_null: %{closure_names_nerves: 1}}} =
               SystemVersionBackfill.fill(releases: releases())
    end

    test "when the run recorded no closure" do
      null_row!(@rpi4, deps_lock: nil)

      assert {:dry_run, %{left_null: %{no_closure: 1}}} =
               SystemVersionBackfill.fill(releases: releases())
    end

    test "when a recorded resolution in the same interval chose another version" do
      recorded!(@rpi4, "2.2.0", ~N[2026-10-30 09:00:00])
      null_row!()

      assert {:dry_run, %{provable: 0, left_null: %{contradicted: 1}} = report} =
               SystemVersionBackfill.fill(releases: releases())

      assert report.corroboration["#{@rpi4}@2.2.1"] == %{agree: 1, disagree: 1}
    end

    test "when no recorded resolution corroborates the version" do
      null_row!(@trellis)

      assert {:dry_run, %{left_null: %{uncorroborated: 1}}} =
               SystemVersionBackfill.fill(releases: releases())
    end

    test "when Hex cannot say when the system's releases were published" do
      null_row!(@rpi4)

      assert {:dry_run, %{left_null: %{hex_unavailable: 1}}} =
               SystemVersionBackfill.fill(releases: releases(%{@rpi4 => :unavailable}))
    end

    test "when the newest release is a prerelease or retired" do
      null_row!(@rpi4)

      pre = [
        %{version: "2.2.1", published_at: ~U[2026-10-20 00:00:00Z], retired: false},
        %{version: "2.3.0-rc.1", published_at: ~U[2026-10-23 00:00:00Z], retired: false}
      ]

      assert {:dry_run, %{left_null: %{newest_release_unusable: 1}}} =
               SystemVersionBackfill.fill(releases: releases(%{@rpi4 => pre}))

      retired = [%{version: "2.2.1", published_at: ~U[2026-10-23 00:29:39Z], retired: true}]

      assert {:dry_run, %{left_null: %{newest_release_unusable: 1}}} =
               SystemVersionBackfill.fill(releases: releases(%{@rpi4 => retired}))
    end
  end

  test "ignores rows that are not passing target results without a version" do
    recorded!(@rpi4, "2.2.1")
    null_row!(@rpi4, status: "fail")
    ~N[2026-10-27 10:00:00] |> run!() |> result!("host")
    ~N[2026-10-27 10:00:00] |> run!() |> result!(@rpi4, version: "2.2.1")

    assert {:dry_run, %{candidates: 0}} = SystemVersionBackfill.fill(releases: releases())
  end

  defp set_own_lock(id, lock) do
    Repo.query!("UPDATE catalog_system_results SET deps_lock = $1 WHERE id = $2", [
      lock,
      Ecto.UUID.dump!(id)
    ])
  end
end
