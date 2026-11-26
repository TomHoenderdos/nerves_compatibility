defmodule Portal.Catalog.SystemGroupsTest do
  # Stream S11: one project resolves one lock, and one lock holds one
  # nerves_system_br. Since 2026-11-25 rpi5's newest release wants br 1.35.3
  # and rpi4's, trellis's and x86_64's 1.35.4, so a run of all of them builds
  # rpi4 2.2.2 and trellis 0.6.3. A targets run of one br group resolves its
  # systems' newest releases.
  use ExUnit.Case, async: true

  alias Portal.Catalog.SystemGroups

  @nerves2 "~> 1.11 or ~> 2.0 or ~> 2.0.0-dev"

  defp release(version, br, opts \\ []) do
    %{
      version: version,
      retired?: Keyword.get(opts, :retired?, false),
      retired_reason: nil,
      outer_checksum: nil,
      deps: [
        %{package: "nerves", requirement: Keyword.get(opts, :nerves, @nerves2), optional: false},
        %{package: "nerves_system_br", requirement: br, optional: false}
      ]
    }
  end

  defp registry(answers), do: fn name -> Map.get(answers, name, {:error, :not_found}) end

  defp answers do
    %{
      "nerves_system_rpi4" => {:ok, [release("2.2.2", "1.35.3"), release("2.2.3", "1.35.4")]},
      "nerves_system_rpi5" => {:ok, [release("2.2.3", "1.35.3")]},
      "nerves_system_trellis" => {:ok, [release("0.6.3", "1.35.3"), release("0.6.4", "1.35.4")]},
      "nerves_system_x86_64" => {:ok, [release("1.35.3", "1.35.4")]}
    }
  end

  test "systems whose newest releases want another nerves_system_br are split, largest first" do
    systems = ~w(nerves_system_rpi5 nerves_system_trellis nerves_system_rpi4 nerves_system_x86_64)

    assert SystemGroups.split(systems, registry(answers())) == [
             ~w(nerves_system_rpi4 nerves_system_trellis nerves_system_x86_64),
             ~w(nerves_system_rpi5)
           ]
  end

  test "systems that agree stay one group" do
    assert SystemGroups.split(~w(nerves_system_x86_64 nerves_system_rpi4), registry(answers())) ==
             [~w(nerves_system_rpi4 nerves_system_x86_64)]
  end

  test "a prerelease, a retired release and a Nerves 1 release are not the newest" do
    answers = %{
      "nerves_system_rpi4" =>
        {:ok,
         [
           release("2.2.2", "1.35.3"),
           release("2.2.3", "1.35.4", retired?: true),
           release("2.3.0-rc.0", "1.35.4"),
           release("3.0.0", "1.36.0", nerves: "~> 1.11")
         ]},
      "nerves_system_rpi5" => {:ok, [release("2.2.3", "1.35.3")]}
    }

    assert SystemGroups.split(~w(nerves_system_rpi4 nerves_system_rpi5), registry(answers)) ==
             [~w(nerves_system_rpi4 nerves_system_rpi5)]
  end

  test "a system the registry cannot answer for builds with the others it cannot place" do
    answers = Map.put(answers(), "nerves_system_bbb", {:error, :hex_registry_unavailable})
    systems = ~w(nerves_system_bbb nerves_system_rpi4 nerves_system_rpi5 nerves_system_x86_64)

    assert SystemGroups.split(systems, registry(answers)) == [
             ~w(nerves_system_rpi4 nerves_system_x86_64),
             ~w(nerves_system_bbb),
             ~w(nerves_system_rpi5)
           ]
  end

  test "no systems, no groups" do
    assert SystemGroups.split([], registry(answers())) == []
  end
end
