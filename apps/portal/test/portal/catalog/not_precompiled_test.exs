defmodule Portal.Catalog.NotPrecompiledTest do
  use Portal.DataCase, async: true

  import Portal.Test.NotPrecompiledFixtures

  alias Portal.Catalog.NotPrecompiled

  test "rows: the newest skip per package and toolchain, unrevoked, one per package and reason" do
    seed_not_precompiled!()
    rows = NotPrecompiled.rows()

    assert Enum.map(rows, & &1.package) == [
             "req_like",
             "tesla_like",
             "env_reader",
             "small_hackney"
           ]

    [req | _] = rows
    assert req.toolchains == ["1.19/28", "1.20/29"]
    assert req.version == "1.0.0"
    assert req.downloads == 900
    assert %{class: :build_hooks, detail: "post_hooks", blocker: "hackney"} = req
    assert req.reason == hackney_reason()

    env = Enum.find(rows, &(&1.package == "env_reader"))
    assert env.version == "1.0.0"
    assert %{class: :env_read, detail: "GITHUB_ACTIONS", blocker: nil} = env
  end

  test "an :error at a newer version leaves the older skip standing" do
    build!("flaky", "1.0.0", reason: "no compiled beams")
    build!("flaky", "2.0.0", status: :error, reason: "boom")

    assert [%{package: "flaky", version: "1.0.0", class: :no_beams}] = NotPrecompiled.rows()
  end

  test "a config variant other than the default does not count" do
    build!("overlay", "1.0.0", reason: "no compiled beams", config_variant: "phx_prod")
    assert NotPrecompiled.rows() == []

    build!("overlay", "1.0.0", reason: "nerves-specific source")
    assert [%{class: :nerves_specific}] = NotPrecompiled.rows()
  end

  test "semver, not string order, picks the newest version" do
    build!("semver", "1.10.0", reason: "no compiled beams")
    build!("semver", "1.9.0", reason: "nerves-specific source")
    build!("semver", "2.0.0-rc.1", reason: "nerves-specific source")

    assert [%{version: "1.10.0", class: :no_beams}] = NotPrecompiled.rows()
  end

  test "by_class, by_detail, by_blocker and filter" do
    seed_not_precompiled!()
    rows = NotPrecompiled.rows()

    assert NotPrecompiled.by_class(rows) == [
             %{class: :env_read, packages: 1, downloads: 300},
             %{class: :build_hooks, packages: 3, downloads: 1410}
           ]

    assert NotPrecompiled.by_detail(rows, :env_read) == [%{detail: "GITHUB_ACTIONS", packages: 1}]
    assert NotPrecompiled.by_detail(rows, :build_hooks) == [%{detail: "post_hooks", packages: 3}]

    assert NotPrecompiled.by_blocker(rows, 2) == [
             %{
               blocker: "hackney",
               packages: 3,
               downloads: 1410,
               sample: ["req_like", "tesla_like"]
             }
           ]

    assert rows |> NotPrecompiled.filter(blocker: "hackney") |> Enum.map(& &1.package) ==
             ["req_like", "tesla_like", "small_hackney"]

    assert rows
           |> NotPrecompiled.filter(class: :env_read, detail: "GITHUB_ACTIONS", blocker: nil)
           |> Enum.map(& &1.package) == ["env_reader"]

    assert NotPrecompiled.filter(rows, class: :no_beams) == []
    assert NotPrecompiled.filter(rows, []) == rows
  end

  test "no builds, no rows" do
    assert NotPrecompiled.rows() == []
    assert NotPrecompiled.by_class([]) == []
    assert NotPrecompiled.by_blocker([]) == []
  end
end
