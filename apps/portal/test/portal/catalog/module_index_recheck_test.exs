defmodule Portal.Catalog.ModuleIndexRecheckTest do
  # Round 5, R3-5a: after each complete run, the served rows whose judge
  # recorded a declared-absent probe are re-checked against the new index;
  # a row that now collides is withheld, tagged, with an undo.
  use Portal.DataCase, async: false

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
        registry: fn -> {:ok, %{"money" => "1.14.0", "ex_money" => "5.24.2"}} end,
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

  test "an incomplete run withholds nothing", %{opts: opts} do
    colliding = served!("bitcrowd_like", %{"declared_absent" => [@money]})
    failing = Keyword.put(opts, :tarball, fn _n, _v -> {:error, :hex_registry_unavailable} end)
    assert %{complete: false, withheld: nil} = ModuleIndex.refresh(failing)
    assert revoked(colliding) == {false, nil}
    assert %{skipped: :not_complete} = ModuleIndex.recheck(dry_run: true)
  end
end
