defmodule Portal.Catalog.TriageCollationTest do
  @moduledoc """
  Name orders in the triage queries are byte order (`COLLATE "C"`), as the
  check rows' package lists are, whatever the database's collation. Under
  en_US "a_b", "ab", "abc" and "Zed" sort in that order; in C, "Zed" leads.
  """
  use Portal.DataCase, async: false

  import Portal.Test.ArgusFixtures

  alias Portal.Catalog

  @names ["abc", "ab", "Zed", "a_b"]
  @c_order ["Zed", "a_b", "ab", "abc"]

  defp packages(rows), do: Enum.map(rows, & &1.triage.package_name)

  describe "package names" do
    setup do
      for name <- @names, do: ingest("1.0.0", ok([finding()]), 1, name)
      :ok
    end

    test "every finding sort orders and breaks ties on package name in byte order" do
      for sort <- [:severity, :package, :analysis, :package_new, :package_count, :package_type] do
        {rows, _} = Catalog.triage_page(%{sort: sort}, nil)
        assert packages(rows) == @c_order, "sort #{sort}"
      end
    end

    test "the check row's package list and the Package sort agree" do
      # Its first package, "Yy", leads "Zed" in byte order but trails "a_b"
      # under en_US.
      ingest("1.0.0", ok([finding(%{"title" => "Other"})]), 1, "Yy")

      assert [first, second] = Catalog.triage_checks(%{sort: :package})
      assert first.package_names == ["Yy"]
      assert second.package_names == @c_order
    end

    test "the package picker lists ties in byte order" do
      assert %{packages: packages} = Catalog.triage_filter_options(%{})
      assert Enum.map(packages, &elem(&1, 0)) == @c_order
    end
  end

  describe "analysis and title" do
    setup do
      findings =
        for {name, i} <- Enum.with_index(@names) do
          finding(%{"analysis" => name, "title" => name, "line" => i})
        end

      ingest("1.0.0", ok(findings), 1, "pkg")
      :ok
    end

    test "finding sorts order type and title in byte order" do
      for sort <- [:analysis, :package, :package_type, :severity] do
        {rows, _} = Catalog.triage_page(%{sort: sort}, nil)
        assert Enum.map(rows, & &1.triage.analysis) == @c_order, "sort #{sort}"
      end
    end

    test "check sorts order and break ties on type and title in byte order" do
      for sort <- [:count, :severity, :analysis, :package, :confidence] do
        checks = Catalog.triage_checks(%{sort: sort})
        assert Enum.map(checks, & &1.analysis) == @c_order, "sort #{sort}"
      end
    end

    test "the type picker lists ties in byte order" do
      assert %{analyses: analyses} = Catalog.triage_filter_options(%{})
      assert Enum.map(analyses, &elem(&1, 0)) == @c_order
    end
  end
end
