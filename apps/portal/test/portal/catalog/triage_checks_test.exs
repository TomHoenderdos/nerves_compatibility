defmodule Portal.Catalog.TriageChecksTest do
  use Portal.DataCase, async: false

  import Portal.Test.ArgusFixtures

  alias Portal.Catalog
  alias Portal.Catalog.FindingTriage

  @admin %{username: "tom"}
  @every_status [:new, :confirmed, :false_positive, :reported, :ignored]

  defp row(package, title) do
    %{triage: t} =
      %{status: @every_status, include_stale: true}
      |> Catalog.triage_list()
      |> Enum.find(&(&1.triage.package_name == package and &1.triage.title == title))

    t
  end

  defp titles(rows), do: Enum.map(rows, &{&1.triage.package_name, &1.triage.title})

  describe "triage_checks/1" do
    setup do
      ingest("1.0.0", ok([finding(), finding(%{"detail" => "two"})]), 1, "alpha")

      ingest(
        "1.0.0",
        ok([finding(), finding(%{"title" => "Other", "severity" => "error"})]),
        1,
        "beta"
      )

      :ok
    end

    test "groups by analysis, title and severity with counts and a status breakdown" do
      Catalog.triage!(
        row("beta", "Catch-all rescue swallows exceptions").id,
        %{status: "confirmed"},
        @admin
      )

      assert [catch_all, other] = Catalog.triage_checks(%{})

      assert %{
               analysis: "failure",
               title: "Catch-all rescue swallows exceptions",
               severity: "warning",
               count: 3,
               packages: 2,
               by_status: %{new: 2, confirmed: 1, false_positive: 0}
             } = catch_all

      assert %{title: "Other", count: 1, packages: 1} = other
    end

    test "applies the filters" do
      assert [%{count: 2, packages: 1}] = Catalog.triage_checks(%{package: "alph"})
      assert [%{title: "Other"}] = Catalog.triage_checks(%{severity: ["error"]})

      Catalog.triage!(
        row("alpha", "Catch-all rescue swallows exceptions").id,
        %{status: "ignored"},
        @admin
      )

      assert [%{count: 2}, _] = Catalog.triage_checks(%{})

      assert [%{count: 1, by_status: %{ignored: 1}}] =
               Catalog.triage_checks(%{status: [:ignored]})
    end

    test "excludes stale findings unless asked" do
      ingest("1.1.0", ok([finding()]), 2, "alpha")

      assert [%{count: 2}, _] = Catalog.triage_checks(%{})
      assert [%{count: 3}, _] = Catalog.triage_checks(%{include_stale: true})
    end

    test "reports the highest numeric confidence" do
      ingest(
        "1.1.0",
        ok([
          finding(%{"confidence" => 0.4}),
          finding(%{"detail" => "two", "confidence" => 0.9})
        ]),
        2,
        "alpha"
      )

      ingest(
        "1.1.0",
        ok([
          finding(%{"confidence" => "high"}),
          finding(%{"title" => "Other", "severity" => "error"})
        ]),
        2,
        "beta"
      )

      assert [%{confidence: 0.9}, %{confidence: nil}] = Catalog.triage_checks(%{})
    end
  end

  describe "sorting" do
    setup do
      ingest(
        "1.0.0",
        ok([
          finding(%{
            "severity" => "info",
            "analysis" => "zeta",
            "title" => "I",
            "confidence" => 0.2
          }),
          finding(%{
            "severity" => "error",
            "analysis" => "beta",
            "title" => "E",
            "confidence" => "n/a"
          })
        ]),
        1,
        "mmm"
      )

      ingest(
        "1.0.0",
        ok([
          finding(%{
            "severity" => "warning",
            "analysis" => "alpha",
            "title" => "W",
            "confidence" => 0.7
          }),
          finding(%{
            "severity" => "warning",
            "analysis" => "alpha",
            "title" => "W2",
            "detail" => "2"
          })
        ]),
        1,
        "aaa"
      )

      :ok
    end

    test "severity, then package" do
      assert [{"mmm", "E"}, {"aaa", "W"}, {"aaa", "W2"}, {"mmm", "I"}] =
               titles(Catalog.triage_list(%{sort: :severity}))
    end

    test "severity is the default for the list" do
      assert titles(Catalog.triage_list(%{})) == titles(Catalog.triage_list(%{sort: :severity}))
    end

    test "package" do
      assert [{"aaa", _}, {"aaa", _}, {"mmm", "E"}, {"mmm", "I"}] =
               titles(Catalog.triage_list(%{sort: :package}))
    end

    test "analysis" do
      assert [{_, "W"}, {_, "W2"}, {_, "E"}, {_, "I"}] =
               titles(Catalog.triage_list(%{sort: :analysis}))
    end

    test "confidence, numeric first and descending" do
      assert [{_, "W"}, {_, "I"} | rest] = titles(Catalog.triage_list(%{sort: :confidence}))
      assert Enum.sort(rest) == [{"aaa", "W2"}, {"mmm", "E"}]
    end

    test "newest" do
      Catalog.triage!(row("mmm", "I").id, %{status: "confirmed"}, @admin)
      Catalog.triage!(row("aaa", "W2").id, %{status: "confirmed"}, @admin)

      assert [{"aaa", "W2"}, {"mmm", "I"} | _] = titles(Catalog.triage_list(%{sort: :newest}))
    end

    test "checks by count, the default" do
      ingest(
        "1.0.0",
        ok([finding(%{"severity" => "info", "analysis" => "zeta", "title" => "I"})]),
        1,
        "zzz"
      )

      assert [%{title: "I", count: 2} | _] = Catalog.triage_checks(%{})
      assert [%{title: "I"} | _] = Catalog.triage_checks(%{sort: :count})
    end

    test "checks by severity, package, analysis, confidence and newest" do
      check_titles = fn sort -> Enum.map(Catalog.triage_checks(%{sort: sort}), & &1.title) end

      assert ["E", "W", "W2", "I"] = check_titles.(:severity)
      assert ["W", "W2", "E", "I"] = check_titles.(:package)
      assert ["W", "W2", "E", "I"] = check_titles.(:analysis)
      assert ["W", "I" | _] = check_titles.(:confidence)

      Catalog.triage!(row("mmm", "E").id, %{status: "confirmed"}, @admin)
      assert ["E" | _] = check_titles.(:newest)
    end
  end

  describe "triage_check!/5" do
    @check %{
      analysis: "failure",
      title: "Catch-all rescue swallows exceptions",
      severity: "warning"
    }

    setup do
      ingest(
        "1.0.0",
        ok([finding(), finding(%{"detail" => "two"}), finding(%{"title" => "Other"})]),
        1,
        "alpha"
      )

      ingest("1.0.0", ok([finding()]), 1, "beta")
      :ok
    end

    test "\"all\" sets every finding of the check within the filters" do
      Catalog.triage!(row("beta", @check.title).id, %{status: "confirmed", note: "keep"}, @admin)

      assert 2 ==
               Catalog.triage_check!(
                 %{package: "alph"},
                 @check,
                 :all,
                 %{status: "false_positive", note: "fp"},
                 %{username: "ann"}
               )

      assert %{status: :false_positive, note: "fp", updated_by: "ann"} =
               row("alpha", @check.title)

      assert %{status: :confirmed, note: "keep", updated_by: "tom"} = row("beta", @check.title)
      assert %{status: :new, updated_by: nil} = row("alpha", "Other")
    end

    test "\"only new\" leaves already-triaged findings alone" do
      Catalog.triage!(row("beta", @check.title).id, %{status: "confirmed", note: "keep"}, @admin)

      assert 2 ==
               Catalog.triage_check!(%{}, @check, :new, %{status: "reported"}, %{username: "ann"})

      statuses =
        %{status: @every_status}
        |> Catalog.triage_list()
        |> Enum.filter(&(&1.triage.title == @check.title))
        |> Enum.map(&{&1.triage.package_name, &1.triage.status, &1.triage.updated_by})
        |> Enum.sort()

      assert statuses == [
               {"alpha", :reported, "ann"},
               {"alpha", :reported, "ann"},
               {"beta", :confirmed, "tom"}
             ]

      assert %{note: "keep"} = row("beta", @check.title)
    end

    test "skips stale findings unless the filters include them" do
      ingest("1.1.0", ok([finding(), finding(%{"title" => "Other"})]), 2, "alpha")

      assert 2 == Catalog.triage_check!(%{}, @check, :all, %{status: "ignored"}, @admin)

      assert 3 ==
               Catalog.triage_check!(
                 %{include_stale: true, status: @every_status},
                 @check,
                 :all,
                 %{status: "ignored"},
                 @admin
               )
    end
  end

  describe "triage_many!/3" do
    test "sets only the selected ids and ignores unknown ones" do
      ingest(
        "1.0.0",
        ok([finding(), finding(%{"detail" => "two"}), finding(%{"title" => "Other"})]),
        1
      )

      [a, b, c] = Catalog.triage_list(%{}) |> Enum.map(& &1.triage) |> Enum.sort_by(& &1.id)

      ids = [a.id, c.id, Ecto.UUID.generate(), "not-a-uuid"]

      assert 2 ==
               Catalog.triage_many!(ids, %{status: "confirmed", note: "bulk"}, %{username: "ann"})

      after_ = Map.new(Catalog.triage_list(%{status: @every_status}), &{&1.triage.id, &1.triage})
      assert %{status: :confirmed, note: "bulk", updated_by: "ann"} = after_[a.id]
      assert %{status: :confirmed} = after_[c.id]
      assert %{status: :new, note: nil, updated_by: nil} = after_[b.id]
    end

    test "an unknown status changes nothing" do
      ingest("1.0.0", ok([finding()]), 1)
      [%{triage: a}] = Catalog.triage_list(%{})
      assert 0 == Catalog.triage_many!([a.id], %{status: "deleted"}, @admin)
      assert [%{triage: %{status: :new}}] = Catalog.triage_list(%{})
    end
  end

  test "triage!/3 without a note keeps the note" do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: a}] = Catalog.triage_list(%{})
    Catalog.triage!(a.id, %{status: "confirmed", note: "why"}, @admin)
    Catalog.triage!(a.id, %{status: "reported"}, @admin)
    assert %{status: :reported, note: "why"} = row("tripkg", a.title)
  end

  describe "FindingTriage.source_url/1" do
    test "links to the file and line at the last seen version, encoding each segment" do
      assert FindingTriage.source_url(%{
               package_name: "circuits_uart",
               last_seen_version: "1.5.0",
               file: "lib/circuits uart/a#b.ex",
               line: 12
             }) ==
               "https://hex.pm/packages/circuits_uart/1.5.0/files/lib/circuits%20uart/a%23b.ex#L12"
    end

    test "omits the line anchor without a line" do
      assert FindingTriage.source_url(%{
               package_name: "p",
               last_seen_version: "1.0.0-rc.1+build",
               file: "c_src/x.c",
               line: nil
             }) == "https://hex.pm/packages/p/1.0.0-rc.1%2Bbuild/files/c_src/x.c"
    end

    test "is nil without a version or file, or for a path outside the package" do
      base = %{package_name: "p", last_seen_version: "1.0.0", file: "lib/a.ex", line: 1}
      assert FindingTriage.source_url(%{base | last_seen_version: nil}) == nil
      assert FindingTriage.source_url(%{base | file: nil}) == nil
      assert FindingTriage.source_url(%{base | file: ""}) == nil
      assert FindingTriage.source_url(%{base | file: "/work/deps/p/lib/a.ex"}) == nil
      assert FindingTriage.source_url(%{base | file: "lib/../../etc/passwd"}) == nil
    end
  end
end
