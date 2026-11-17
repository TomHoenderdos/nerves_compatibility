defmodule Portal.HexPmReleaseTimesTest do
  # Real HTTP through Req against an in-process stand-in for hex.pm.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.HexPm
  alias Portal.Test.FakeHex

  @package "/api/packages/nerves_system_rpi4"

  # Trimmed from `GET https://hex.pm/api/packages/nerves_system_rpi4`.
  @body %{
    "name" => "nerves_system_rpi4",
    "releases" => [
      %{"version" => "2.2.1", "inserted_at" => "2026-10-23T00:29:39.123456Z", "has_docs" => true},
      %{"version" => "2.0.0-rc.0", "inserted_at" => "2026-05-01T10:00:00Z"}
    ],
    "retirements" => %{"2.0.0-rc.0" => %{"reason" => "invalid", "message" => "Abandoned"}}
  }

  defp fetch(hex, package \\ "nerves_system_rpi4"),
    do: HexPm.release_times(package, base_url: hex.base_url)

  test "reads each release's version, publication time and retirement" do
    hex = FakeHex.start(%{@package => {200, @body}})

    assert {:ok, releases} = fetch(hex)

    assert Enum.sort_by(releases, & &1.version) == [
             %{version: "2.0.0-rc.0", published_at: ~U[2026-05-01 10:00:00Z], retired: true},
             %{
               version: "2.2.1",
               published_at: ~U[2026-10-23 00:29:39.123456Z],
               retired: false
             }
           ]
  end

  # A release the timeline cannot place would make an answer look certain
  # that is not, so a body with one is no answer at all.
  test "a release without a readable version or time makes the whole answer unavailable" do
    for bad <- [
          %{"version" => "1.0.0"},
          %{"version" => "not-a-version", "inserted_at" => "2026-05-01T10:00:00Z"},
          %{"version" => "2.1.0", "inserted_at" => "not a time"}
        ] do
      assert {:error, :hex_api_unavailable} =
               HexPm.release_times_from_body(%{"releases" => @body["releases"] ++ [bad]}),
             inspect(bad)
    end

    assert {:error, :hex_api_unavailable} = HexPm.release_times_from_body(%{"releases" => nil})
  end

  test "an unknown package and a failing hex.pm are told apart" do
    assert {:error, :unknown_package} = fetch(FakeHex.start(%{}))

    hex = FakeHex.start(%{@package => {500, %{"message" => "oops"}}})
    capture_log(fn -> assert {:error, :hex_api_unavailable} = fetch(hex) end)
  end
end
