defmodule Portal.Catalog.ClosureDriftTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.ClosureDrift

  @built ~U[2026-11-10 00:00:00Z]
  @released ~U[2026-11-12 00:00:00Z]

  defp entry(name, versions, opts \\ []) do
    %{
      name: name,
      latest_version: List.last(versions),
      updated_at: Keyword.get(opts, :updated_at, @released),
      versions: versions,
      retired: Keyword.get(opts, :retired, [])
    }
  end

  defp index(entries), do: ClosureDrift.index(entries)

  defp release(version, deps) do
    deps =
      for {package, requirement} <- deps,
          do: %{package: package, requirement: requirement, optional: false, repository: "hexpm"}

    %{version: version, retired?: false, outer_checksum: nil, deps: deps}
  end

  # `fledex_scheduler 0.4.0` -> `hackney 1.25.0` -> `certifi ~> 2.18`.
  defp releases(overrides \\ %{}) do
    releases =
      Map.merge(
        %{
          "fledex_scheduler" => [release("0.4.0", [{"hackney", "~> 1.20"}])],
          "hackney" => [release("1.25.0", [{"certifi", "~> 2.18"}])],
          "certifi" => [release("2.18.0", []), release("2.19.0", [])]
        },
        overrides
      )

    fn name ->
      case Map.fetch(releases, name) do
        {:ok, list} -> {:ok, list}
        :error -> {:error, :not_found}
      end
    end
  end

  defp build(lock, built_at \\ @built) do
    %{
      package: "fledex_scheduler",
      version: "0.4.0",
      deps_lock:
        Map.new(lock, fn {name, version} -> {name, %{"version" => version, "checksum" => "x"}} end),
      built_at: built_at
    }
  end

  defp registry(certifi_versions, opts \\ []) do
    index([
      entry("fledex_scheduler", ["0.3.0", "0.4.0"]),
      entry("hackney", ["1.24.0", "1.25.0"], updated_at: ~U[2026-01-01 00:00:00Z]),
      entry("certifi", certifi_versions, opts)
    ])
  end

  test "a newer release every requirement in the closure allows is drift" do
    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}),
             registry(["2.17.0", "2.18.0", "2.19.0"]),
             releases()
           ) == {:drift, [%{"dep" => "certifi", "from" => "2.18.0", "to" => "2.19.0"}]}
  end

  test "a release a requirement in the closure rules out is not" do
    releases = releases(%{"hackney" => [release("1.25.0", [{"certifi", "~> 2.18.0"}])]})

    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}),
             registry(["2.18.0", "2.19.0"]),
             releases
           ) == :current
  end

  test "the newest allowed release is the target, not the registry's newest" do
    releases = releases(%{"hackney" => [release("1.25.0", [{"certifi", "~> 2.18"}])]})

    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}),
             registry(["2.18.0", "2.18.1", "3.0.0"]),
             releases
           ) == {:drift, [%{"dep" => "certifi", "from" => "2.18.0", "to" => "2.18.1"}]}
  end

  test "prereleases and retired releases are never the target" do
    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}),
             registry(["2.18.0", "2.19.0-rc.1", "2.19.0"], retired: ["2.19.0"]),
             releases()
           ) == :current
  end

  # The build resolved after the dependency last changed, so whatever kept it
  # at the older release (a constraint this check does not model) still
  # holds: rebuilding would only resolve the same lock again.
  test "a dependency that last changed before the build is not drift" do
    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}, ~U[2026-11-13 00:00:00Z]),
             registry(["2.18.0", "2.19.0"]),
             releases()
           ) == :current
  end

  test "a closure whose requirements cannot be read is not judged" do
    releases = releases(%{"hackney" => []})

    assert {:error, {:unknown_release, "hackney", "1.25.0"}} =
             ClosureDrift.drift(
               build(%{"hackney" => "1.25.0", "certifi" => "2.18.0"}),
               registry(["2.18.0", "2.19.0"]),
               releases
             )
  end

  test "a closure with nothing newer asks Hex nothing" do
    assert ClosureDrift.drift(
             build(%{"hackney" => "1.25.0", "certifi" => "2.19.0"}),
             registry(["2.18.0", "2.19.0"]),
             fn name -> flunk("asked for #{name}") end
           ) == :current
  end

  test "index/1 keeps each package's newest stable unretired release" do
    index =
      index([
        entry("a", ["1.0.0", "1.1.0", "2.0.0-rc.0"]),
        entry("b", ["1.0.0", "1.1.0"], retired: ["1.1.0"]),
        entry("c", ["0.1.0-dev"])
      ])

    assert index["a"].newest == "1.1.0"
    assert index["b"].newest == "1.0.0"
    assert index["c"].newest == nil
  end
end
