defmodule Portal.Catalog.BrowseTest do
  use Portal.DataCase, async: false

  import Portal.PackageListingFixtures

  alias Portal.Catalog.Browse
  alias Portal.Catalog.Ingestion

  defp ingest(name, run_id, finished_at, systems) do
    dir = Path.join(System.tmp_dir!(), "browse-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0", "description" => "about #{name}"},
          "finished_at" => finished_at,
          "systems" => systems
        },
        %{run_id: run_id, image_digest: "sha256:x", files_dir: dir, log: "l"}
      )
  end

  defp names({entries, _count}), do: Enum.map(entries, & &1.name)

  test "a catalog card carries what the index renders" do
    ingest("cardpkg", "cardpkg-1", "2026-07-05T10:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "pass", "system_version" => "1.0.0"},
      "nerves_system_x86_64" => %{"status" => "fail", "system_version" => "1.0.0"}
    })

    assert {[card], 1} = Browse.page("", 0, 60)

    assert card == %{
             name: "cardpkg",
             description: "about cardpkg",
             version: "v1.0.0",
             summary: "1/2 pass",
             summary_status: "fail",
             statuses: ["pass", "fail"],
             placeholder?: false
           }
  end

  test "a package with no run is not run" do
    package_fixture("norun")

    assert {[%{summary: "not run", summary_status: "skipped", statuses: []}], 1} =
             Browse.page("", 0, 60)
  end

  test "a card shows the newest of several runs, whatever order they arrived in" do
    ingest("multi", "multi-new", "2026-07-06T10:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "pass", "system_version" => "1.0.0"}
    })

    ingest("multi", "multi-old", "2026-07-01T10:00:00Z", %{
      "nerves_system_rpi4" => %{"status" => "fail", "system_version" => "1.0.0"}
    })

    assert {[%{summary: "1/1 pass", summary_status: "pass", statuses: ["pass"]}], 1} =
             Browse.page("", 0, 60)
  end

  test "placeholders keep their wording and yield to catalog packages" do
    request_fixture("queued_one")
    request_fixture("failed_one", %{status: :error})
    request_fixture("both")
    package_fixture("both")

    {entries, 3} = Browse.page("", 0, 60)

    assert [
             %{name: "both", placeholder?: false},
             %{
               name: "failed_one",
               placeholder?: true,
               description: "First scan failed.",
               summary: "build failed",
               summary_status: "error",
               version: nil,
               statuses: []
             },
             %{
               name: "queued_one",
               placeholder?: true,
               description: "Awaiting first scan.",
               summary: "in queue",
               summary_status: "queued"
             }
           ] = entries
  end

  test "catalog and placeholder rows interleave in byte order" do
    package_fixture("b_pkg")
    package_fixture("Zed")
    request_fixture("a_req")
    request_fixture("c_req")
    request_fixture("_under")

    # Byte order, as the old `Enum.sort_by(& &1.name)` had it: uppercase before
    # underscore before lowercase. A locale collation would put "Zed" last.
    assert names(Browse.page("", 0, 60)) == ["Zed", "_under", "a_req", "b_pkg", "c_req"]
  end

  test "paging continues where the previous page ended and counts the whole set" do
    for i <- 1..5, do: package_fixture("pkg#{i}")
    for i <- 6..9, do: request_fixture("pkg#{i}")

    assert {first, 9} = Browse.page("", 0, 4)
    assert {second, 9} = Browse.page("", 4, 4)
    assert {third, 9} = Browse.page("", 8, 4)

    assert Enum.map(first ++ second ++ third, & &1.name) == Enum.map(1..9, &"pkg#{&1}")
  end

  test "search is a lowercase substring match over both kinds of row" do
    package_fixture("circuits_gpio")
    package_fixture("jason")
    request_fixture("circuits_i2c")

    assert {entries, 2} = Browse.page("CIRC", 0, 60)
    assert Enum.map(entries, & &1.name) == ["circuits_gpio", "circuits_i2c"]
  end

  test "SQL wildcards in the term are literal text" do
    package_fixture("has_under")
    package_fixture("hasXunder")
    request_fixture("has%percent")
    request_fixture("hasXpercent")
    package_fixture("back\\slash")
    package_fixture("backXslash")

    assert names(Browse.page("_", 0, 60)) == ["has_under"]
    assert names(Browse.page("%", 0, 60)) == ["has%percent"]
    assert names(Browse.page("\\", 0, 60)) == ["back\\slash"]
    assert {[], 0} = Browse.page("absent", 0, 60)
  end
end
