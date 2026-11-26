defmodule Portal.Catalog.SystemGroups do
  @moduledoc """
  Firmware targets split by the `nerves_system_br` their systems' newest
  releases want (stream S11).

  A run's project resolves one `mix.lock`, and a lock holds one
  `nerves_system_br`. The worker names every target of a run in that one
  project (`NccWorker.Project.create/3`), so when the systems' newest
  releases want different ones, Hex keeps one system's newest release and
  holds the others back: since 2026-11-25 `nerves_system_rpi5` 2.2.3 wants
  br 1.35.3 and rpi4 2.2.3, trellis 0.6.4, bbb 2.31.3, rpi0_2 2.2.3 and
  x86_64 1.35.3 want 1.35.4, and a run of all of them builds rpi4 2.2.2 and
  trellis 0.6.3. A targets run names only its own targets, so it resolves
  them alone; a run per group gets every target its newest release.

  A system's newest release is its newest stable one the signed registry
  does not list as retired and whose own `nerves` requirement accepts the
  Nerves the worker builds on (`Compatibility.Nerves.buildable?/1`), and its
  group is that release's `nerves_system_br` requirement (an exact version
  for every Nerves system). A system the registry gives no such answer for
  goes with the others it cannot place, as every target went before.
  """

  @doc """
  `systems` (system package names) in groups, each sorted, the largest
  first (then by its first name). `releases` answers like
  `Portal.HexDeps.releases/1`.
  """
  @spec split([String.t()], (String.t() -> {:ok, [map()]} | {:error, term()})) ::
          [[String.t()]]
  def split(systems, releases) do
    systems
    |> Enum.uniq()
    |> Enum.group_by(&br(&1, releases))
    |> Enum.map(fn {_br, group} -> Enum.sort(group) end)
    |> Enum.sort_by(&{-length(&1), hd(&1)})
  end

  defp br(system, releases) do
    with {:ok, list} when is_list(list) <- releases.(system),
         %{deps: deps} <- newest(list) do
      Enum.find_value(deps, fn dep ->
        if dep.package == "nerves_system_br", do: dep.requirement
      end)
    else
      _ -> nil
    end
  end

  defp newest(releases) do
    releases
    |> Enum.filter(&buildable?/1)
    |> Enum.max_by(&Version.parse!(&1.version), Version, fn -> nil end)
  end

  defp buildable?(%{version: version, deps: deps} = release) when is_list(deps) do
    stable?(version) and not Map.get(release, :retired?, false) and
      Enum.any?(
        deps,
        &(&1.package == "nerves" and Compatibility.Nerves.buildable?(&1.requirement))
      )
  end

  defp buildable?(_release), do: false

  defp stable?(version) do
    match?({:ok, %Version{pre: []}}, Version.parse(to_string(version)))
  end
end
