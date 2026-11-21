defmodule Portal.Catalog.ManifestRelocatedTest do
  # S4: a relocated toolchain build (`Portal.Precompiled.Relocated`) is
  # listed only under a version's `relocated` object, which no client before
  # 0.9.0 reads, and only while `relocated_enabled` is on.
  use Portal.DataCase, async: false

  alias Portal.Catalog

  import Portal.PrecompiledFixtures, only: [ingest_toolchain_build: 3]

  @regular ~w(builds builds_with_inputs builds_closure builds_host_native)

  defp on!, do: {:ok, _} = Portal.Settings.save(%{relocated_enabled: true})
  defp off!, do: {:ok, _} = Portal.Settings.save(%{relocated_enabled: false})

  defp manifest(name), do: Catalog.precompiled_manifest_v2(name)

  defp record(name), do: Portal.Test.RelocationFixtures.record(name)

  # The relocated build's beam (beside its `.app`).
  defp beam_sha(row) do
    [%{"sha256" => sha}] =
      Enum.filter(row.relocated_file_manifest["ebin"], &String.ends_with?(&1["path"], ".beam"))

    sha
  end

  defp all_shas(row) do
    for key <- ["ebin", "priv"],
        %{"sha256" => sha} <- row.relocated_file_manifest[key] || [],
        do: sha
  end

  # No regular list of any version, nor any deterministic one, holds a
  # relocated entry: a client before 0.9.0 would install its bytes as they
  # are, with the builder's path in them.
  defp assert_contract!(nil), do: :ok

  defp assert_contract!(%{"versions" => versions}) do
    for {_v, version} <- versions,
        lists <- [version, version["deterministic"] || %{}],
        key <- @regular,
        build <- List.wrap(lists[key]) do
      refute Map.has_key?(build, "relocation"), inspect({key, build["target"]})
    end

    :ok
  end

  setup do
    name = "fine_#{System.unique_integer([:positive])}"
    row = ingest_toolchain_build(name, "0.2.0", compile_env_rule: 1, relocation: record(name))
    plain = ingest_toolchain_build("jason", "1.4.4", compile_env_rule: 1)
    %{name: name, row: row, plain: plain}
  end

  test "setting on: listed only under relocated, beside an empty builds", %{name: name, row: row} do
    on!()
    m = manifest(name)
    assert_contract!(m)
    v = m["versions"]["0.2.0"]
    assert v["builds"] == []
    assert %{"builds" => [entry]} = v["relocated"]
    assert entry["target"] == "pure_elixir"
    assert entry["relocation"] == record(name)
    assert entry["build"]["run_id"] == row.run_id
    assert Enum.map(entry["ebin"], & &1["path"]) == ["ebin/#{name}.beam", "ebin/#{name}.app"]
    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
  end

  # The umbrella re-review's Q1: a dependent that passed because a
  # dependency was held carries the record with no file to rewrite, and is
  # gated as a relocated build: never in a regular list or format 1, only
  # under `relocated` while the setting is on.
  test "a dependent's relocated pass is listed only under relocated, only while on" do
    dep = "fine_dep_#{System.unique_integer([:positive])}"

    row =
      ingest_toolchain_build(dep, "0.2.0",
        compile_env_rule: 1,
        relocation: Portal.Test.RelocationFixtures.dependent_record()
      )

    assert row.relocation_run_id == row.run_id
    assert row.file_manifest == nil

    off!()
    assert no_client_sees?(dep, row)

    on!()
    m = manifest(dep)
    assert_contract!(m)
    assert m["versions"]["0.2.0"]["builds"] == []

    assert %{"builds" => [%{"relocation" => %{"files" => []}}]} =
             m["versions"]["0.2.0"]["relocated"]

    assert Catalog.precompiled_manifest(dep) == nil
    PortalWeb.ApiSpecAssertions.assert_api_schema(m, "ManifestV2")
  end

  # The ruling on Q1: with relocation in builds on and serving off, no row
  # it makes reaches any client, through any route.
  test "relocate_builds_enabled on and relocated_enabled off: no new row reaches a client", %{
    name: name,
    row: row
  } do
    {:ok, _} = Portal.Settings.save(%{relocate_builds_enabled: true, relocated_enabled: false})
    dep = "fine_dep_#{System.unique_integer([:positive])}"

    dependent =
      ingest_toolchain_build(dep, "0.2.0",
        compile_env_rule: 1,
        relocation: Portal.Test.RelocationFixtures.dependent_record()
      )

    assert no_client_sees?(name, row)
    assert no_client_sees?(dep, dependent)
  end

  # Neither manifest format, the files route nor the batch's package list
  # lists the row or serves a file of it.
  defp no_client_sees?(name, row) do
    v2 = manifest(name)
    v1 = Catalog.precompiled_manifest(name)

    assert v2 == nil or not Map.has_key?(v2["versions"], "0.2.0"), inspect(v2)
    assert v1 == nil or not Map.has_key?(v1["versions"] || %{}, "0.2.0"), inspect(v1)
    refute Enum.any?(all_shas(row), &Catalog.published_sha256?/1)
    refute name in Catalog.packages_with_precompiled_files()
    true
  end

  test "setting off: no relocated object, and the version is not listed", %{name: name} do
    off!()
    m = manifest(name)
    assert m == nil or not Map.has_key?(m["versions"], "0.2.0")
  end

  test "setting off or on, a package without relocated builds renders the same bytes" do
    off!()
    off_bytes = Jason.encode!(manifest("jason"))
    on!()
    assert Jason.encode!(manifest("jason")) == off_bytes
  end

  test "a revoked relocated build is listed nowhere", %{name: name, row: row} do
    on!()

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET revoked_at = now() WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    m = manifest(name)
    assert m == nil or not Map.has_key?(m["versions"], "0.2.0")
  end

  # An older release's rebuild replaces run_id (and its worker refuses the
  # build) and leaves the record: it counts for nothing.
  test "an old release's rebuild leaves a stale record that renders nothing", %{
    name: name,
    row: row
  } do
    on!()

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run', status = 'skipped' WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    m = manifest(name)
    assert_contract!(m)
    assert m == nil or not Map.has_key?(m["versions"], "0.2.0")
  end

  # A stale record (an older release rewrote run_id and left the columns
  # it does not know): the row's files are in `relocated_file_manifest`,
  # which nothing but a counted record lists, so it is listed nowhere.
  test "a stale record beside an old release's pass is listed nowhere", %{name: name, row: row} do
    on!()

    Portal.Repo.query!(
      "UPDATE catalog_toolchain_builds SET run_id = 'old-release-run' WHERE id = $1",
      [Ecto.UUID.dump!(row.id)]
    )

    m = manifest(name)
    assert_contract!(m)
    assert m == nil or not Map.has_key?(m["versions"], "0.2.0")
    refute Catalog.published_sha256?(beam_sha(row))
  end

  test "the package's own name on the withheld list withholds its relocated build", %{name: name} do
    on!()
    assert %{"builds" => [_]} = manifest(name)["versions"]["0.2.0"]["relocated"]

    old = Application.get_env(:portal, Portal.Precompiled.Withheld)
    on_exit(fn -> restore_withheld(old) end)
    Application.put_env(:portal, Portal.Precompiled.Withheld, packages: [name])

    m = manifest(name)
    assert m == nil or not Map.has_key?(m["versions"], "0.2.0")
  end

  # Closure drift keeps the build a rebuild replaced as an earlier build:
  # one that was relocated keeps its record and is listed under relocated.
  test "an earlier relocated build keeps its record and is listed under relocated", %{
    name: name,
    row: row
  } do
    on!()
    lock = %{"decimal" => %{"version" => "2.1.2", "checksum" => "def"}}

    _rebuilt =
      ingest_toolchain_build(name, "0.2.0",
        compile_env_rule: 1,
        relocation: record(name),
        deps_lock: lock,
        finished_at: "2026-10-25T10:00:00Z"
      )

    m = manifest(name)
    assert_contract!(m)
    entries = m["versions"]["0.2.0"]["relocated"]["builds"]
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1["relocation"] == record(name)))
    assert row.deps_lock in Enum.map(entries, & &1["build"]["deps"])
  end

  describe "files route and fingerprints" do
    test "a relocated build's files are served while the setting is on and the mark is the row's",
         %{name: name, row: row} do
      sha = beam_sha(row)
      off!()
      refute Catalog.published_sha256?(sha)
      refute name in Catalog.packages_with_precompiled_files()
      on!()
      assert Catalog.published_sha256?(sha)
      assert name in Catalog.packages_with_precompiled_files()

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET revoked_at = now() WHERE id = $1",
        [Ecto.UUID.dump!(row.id)]
      )

      refute Catalog.published_sha256?(sha)
    end

    test "the setting turned on and off again changes the relocated package's fingerprint only",
         %{name: name} do
      off!()
      before = Catalog.precompiled_fingerprints()
      on!()
      off!()
      now = Catalog.precompiled_fingerprints()
      changed = for {n, fp} <- now, before[n] != fp, do: n
      assert name in changed
      refute "jason" in changed
    end

    test "flipping the setting on changes the relocated package's fingerprint", %{name: name} do
      off!()
      before = Catalog.precompiled_fingerprints()[name]
      on!()
      refute Catalog.precompiled_fingerprints()[name] == before
    end

    test "a row's relocation columns are in its fingerprint", %{name: name, row: row} do
      before = Catalog.precompiled_fingerprints()[name]

      Portal.Repo.query!(
        "UPDATE catalog_toolchain_builds SET relocation = jsonb_set(relocation, '{deps}', '\"/w/deps\"') WHERE id = $1",
        [Ecto.UUID.dump!(row.id)]
      )

      refute Catalog.precompiled_fingerprints()[name] == before
    end
  end

  defp restore_withheld(nil), do: Application.delete_env(:portal, Portal.Precompiled.Withheld)
  defp restore_withheld(old), do: Application.put_env(:portal, Portal.Precompiled.Withheld, old)
end
