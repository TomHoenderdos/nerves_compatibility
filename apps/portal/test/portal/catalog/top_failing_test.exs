defmodule Portal.Catalog.TopFailingTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.TopFailing
  alias Portal.Catalog.Ingestion
  alias Portal.Catalog.Package

  require Ash.Query

  @compile_error "== Compilation error in file lib/x.ex ==\n** (CompileError) boom"

  defp ingest(name, finished_at, systems) do
    dir = Path.join(System.tmp_dir!(), "top-failing-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, run} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => name, "version" => "1.0.0", "description" => "about #{name}"},
          "finished_at" => finished_at,
          "systems" => systems
        },
        %{
          run_id: "#{name}-#{System.unique_integer([:positive])}",
          image_digest: "sha256:x",
          files_dir: dir,
          log: "l"
        }
      )

    run
  end

  defp failing(name, finished_at \\ "2026-07-05T10:00:00Z") do
    ingest(name, finished_at, %{"nerves_system_rpi4" => fail()})
  end

  defp pass, do: %{"status" => "pass", "system_version" => "1.0.0"}
  defp fail, do: %{"status" => "fail", "system_version" => "1.0.0", "log_tail" => @compile_error}
  defp error, do: %{"status" => "error", "system_version" => "1.0.0", "log_tail" => "oom"}
  defp skipped, do: %{"status" => "skipped", "system_version" => "1.0.0"}

  defp downloads(name, recent, all) do
    Package
    |> Ash.Query.for_read(:read)
    |> Ash.Query.filter(name == ^name)
    |> Ash.read_one!(domain: Portal.Catalog)
    |> Ash.Changeset.for_update(:update_hex_meta, %{
      hex_downloads_recent: recent,
      hex_downloads_all: all
    })
    |> Ash.update!(domain: Portal.Catalog)
  end

  defp names(rows), do: Enum.map(rows, & &1.name)

  describe "which packages are listed" do
    test "a package whose latest run has a failing or erroring target is listed; passing and skipped-only are not" do
      ingest("all_pass", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => pass()
      })

      ingest("only_skipped", "2026-07-05T10:00:00Z", %{"nerves_system_rpi4" => skipped()})

      ingest("pass_and_skip", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => skipped()
      })

      ingest("one_fail", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => fail()
      })

      ingest("one_error", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => error()
      })

      assert Enum.sort(names(TopFailing.list([]))) == ["one_error", "one_fail"]
    end

    test "a failing run superseded by a newer passing run is not listed, whatever order they arrived in" do
      ingest("fixed", "2026-07-06T10:00:00Z", %{"nerves_system_rpi4" => pass()})
      ingest("fixed", "2026-07-01T10:00:00Z", %{"nerves_system_rpi4" => fail()})

      assert TopFailing.list([]) == []
    end

    test "a passing run superseded by a newer failing run is listed" do
      ingest("regressed", "2026-07-01T10:00:00Z", %{"nerves_system_rpi4" => pass()})
      ingest("regressed", "2026-07-06T10:00:00Z", %{"nerves_system_rpi4" => fail()})

      assert names(TopFailing.list([])) == ["regressed"]
    end

    test "a package is listed once even when several targets fail" do
      ingest("multi", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => fail(),
        "nerves_system_rpi3" => fail(),
        "nerves_system_x86_64" => error()
      })

      assert names(TopFailing.list([])) == ["multi"]
    end
  end

  describe "row contents" do
    test "a row names the failing targets only, counts them against all targets, and carries package data" do
      ingest("shape", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => fail(),
        "nerves_system_bbb" => skipped()
      })

      downloads("shape", 1_234, 99_999)

      assert [row] = TopFailing.list([])

      assert row.name == "shape"
      assert row.description == "about shape"
      assert row.latest_version == "1.0.0"
      assert row.version_tested == "1.0.0"
      assert %DateTime{} = row.last_run_at
      assert DateTime.compare(row.last_run_at, ~U[2026-07-05 10:00:00Z]) == :eq
      assert row.downloads_recent == 1_234
      assert row.downloads_all == 99_999
      assert row.status == :fail
      assert row.failing_count == 1
      assert row.total_targets == 3

      assert row.failing_targets == [
               %{
                 system: "nerves_system_x86_64@1.0.0",
                 status: :fail,
                 failure_category: "Compilation error"
               }
             ]
    end

    test "status is :error when any failing target errored, :fail when all failed" do
      ingest("mixed", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => fail(),
        "nerves_system_x86_64" => error()
      })

      ingest("plain", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => fail(),
        "nerves_system_x86_64" => fail()
      })

      by_name = Map.new(TopFailing.list([]), &{&1.name, &1})

      assert by_name["mixed"].status == :error
      assert by_name["mixed"].failing_count == 2

      assert Enum.sort(Enum.map(by_name["mixed"].failing_targets, & &1.status)) == [
               :error,
               :fail
             ]

      assert by_name["plain"].status == :fail
    end

    test "a package without download data still appears, with nil counts" do
      failing("no_data")

      assert [%{name: "no_data", downloads_recent: nil, downloads_all: nil}] =
               TopFailing.list([])
    end
  end

  describe "ordering" do
    setup do
      # Recent and all-time disagree: `old_giant` was huge, `rising` is used now.
      failing("old_giant")
      downloads("old_giant", 10, 9_000_000)
      failing("rising")
      downloads("rising", 50_000, 60_000)
      failing("middling")
      downloads("middling", 1_000, 100_000)
      :ok
    end

    test "sort: :recent orders by 90-day downloads, highest first" do
      assert names(TopFailing.list(sort: :recent)) == ["rising", "middling", "old_giant"]
    end

    test "sort: :all orders by all-time downloads, highest first" do
      assert names(TopFailing.list(sort: :all)) == ["old_giant", "middling", "rising"]
    end

    test "the default sort is :recent" do
      assert names(TopFailing.list([])) == names(TopFailing.list(sort: :recent))
      assert hd(names(TopFailing.list([]))) == "rising"
    end

    test "packages without download data sort last under either sort, never first" do
      # Named to sort first alphabetically, so only NULLS LAST keeps it at the end.
      failing("aaa_unknown")

      assert List.last(names(TopFailing.list(sort: :recent))) == "aaa_unknown"
      assert List.last(names(TopFailing.list(sort: :all))) == "aaa_unknown"
    end

    test "equal download counts fall back to name ascending" do
      failing("tie_b")
      downloads("tie_b", 50_000, 1)
      failing("tie_a")
      downloads("tie_a", 50_000, 1)

      assert Enum.take(names(TopFailing.list(sort: :recent)), 3) == ["rising", "tie_a", "tie_b"]
    end
  end

  describe "limit" do
    test "limit caps the number of rows, keeping the top of the order" do
      for {name, n} <- [{"l_one", 1}, {"l_two", 2}, {"l_three", 3}] do
        failing(name)
        downloads(name, n, n)
      end

      assert names(TopFailing.list(limit: 2)) == ["l_three", "l_two"]
    end

    test "a limit below 1 is clamped to 1, not an empty or unbounded list" do
      failing("z_one")
      failing("z_two")

      assert length(TopFailing.list(limit: 0)) == 1
      assert length(TopFailing.list(limit: -5)) == 1
    end

    @tag timeout: :timer.minutes(5)
    test "default limit is 50 and an oversized limit is clamped to 200" do
      for i <- 1..201, do: failing("bulk_#{String.pad_leading("#{i}", 3, "0")}")

      assert length(TopFailing.list([])) == 50
      assert length(TopFailing.list(limit: 1000)) == 200
      assert length(TopFailing.list(limit: 200)) == 200
    end
  end

  describe "system filter" do
    test "system: keeps only packages failing on that target" do
      ingest("fails_on_rpi4", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => fail(),
        "nerves_system_x86_64" => pass()
      })

      ingest("errors_on_rpi4", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => error()
      })

      ingest("passes_on_rpi4", "2026-07-05T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => fail()
      })

      ingest("not_on_rpi4", "2026-07-05T10:00:00Z", %{"nerves_system_bbb" => fail()})

      rows = TopFailing.list(system: "nerves_system_rpi4")

      assert Enum.sort(names(rows)) == ["errors_on_rpi4", "fails_on_rpi4"]

      for row <- rows do
        assert Enum.any?(
                 row.failing_targets,
                 &String.starts_with?(&1.system, "nerves_system_rpi4@")
               )
      end

      assert Enum.sort(names(TopFailing.list([]))) ==
               ["errors_on_rpi4", "fails_on_rpi4", "not_on_rpi4", "passes_on_rpi4"]
    end

    test "system: does not match a target whose old run failed there but whose latest run passes" do
      ingest("healed", "2026-07-01T10:00:00Z", %{"nerves_system_rpi4" => fail()})

      ingest("healed", "2026-07-06T10:00:00Z", %{
        "nerves_system_rpi4" => pass(),
        "nerves_system_x86_64" => fail()
      })

      assert TopFailing.list(system: "nerves_system_rpi4") == []
      assert names(TopFailing.list(system: "nerves_system_x86_64")) == ["healed"]
    end
  end

  describe "opts_from_params/1" do
    # A raw "500" passed straight to `list/1` would hit the non-integer
    # fallback and silently become 50.
    test "a numeric limit string becomes an integer, then list/1 clamps it" do
      assert TopFailing.opts_from_params(%{"limit" => "500"})[:limit] == 500
      assert TopFailing.opts_from_params(%{"limit" => "7"})[:limit] == 7
    end

    test "junk params are dropped so list/1 uses its defaults" do
      assert TopFailing.opts_from_params(%{"limit" => "5x", "sort" => "bogus", "system" => ""}) ==
               [sort: :recent]
    end

    test "sort=all and a system name come through" do
      assert TopFailing.opts_from_params(%{"sort" => "all", "system" => "nerves_system_rpi4"}) ==
               [sort: :all, system: "nerves_system_rpi4"]
    end
  end
end
