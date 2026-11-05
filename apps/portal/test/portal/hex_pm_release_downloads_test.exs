defmodule Portal.HexPmReleaseDownloadsTest do
  # Real HTTP through Req against an in-process stand-in for hex.pm, so the
  # status and transport handling is what is tested, not a mock of it.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Portal.HexPm
  alias Portal.Test.FakeHex

  @release "/api/packages/jason/releases/1.4.5"

  # Trimmed from `GET https://hex.pm/api/packages/jason/releases/1.4.5`: the
  # field this caller reads, beside fields it must not care about.
  @body %{
    "version" => "1.4.5",
    "checksum" => "d3ff1f3b9b9b0a1f8a3b0c1f3b9b9b0a1f8a3b0c1f3b9b9b0a1f8a3b0c1f3b9b",
    "downloads" => 1_234_567,
    "has_docs" => true,
    "meta" => %{"elixir" => "~> 1.11"}
  }

  defp fetch(hex, package \\ "jason", version \\ "1.4.5", opts \\ []) do
    HexPm.release_downloads(package, version, [base_url: hex.base_url] ++ opts)
  end

  test "reads the release's download count" do
    hex = FakeHex.start(%{@release => {200, @body}})

    assert {:ok, 1_234_567} = fetch(hex)
    assert FakeHex.requests(hex) == [@release]
  end

  # A count becomes a sort key for what gets built first; anything that is
  # not a non-negative integer is unknown, not a rank.
  test "a missing or malformed count is unknown, not an error" do
    for downloads <- [nil, -1, "12", 1.5, %{"all" => 3}] do
      hex = FakeHex.start(%{@release => {200, Map.put(@body, "downloads", downloads)}})
      assert {:ok, nil} = fetch(hex), "downloads: #{inspect(downloads)}"
    end

    hex = FakeHex.start(%{@release => {200, Map.delete(@body, "downloads")}})
    assert {:ok, nil} = fetch(hex)
  end

  test "an unknown release is its own error" do
    hex = FakeHex.start(%{})
    assert {:error, :unknown_release} = fetch(hex)
  end

  # The caller stops its whole run on this one, so it must be told apart from
  # any other failure, and asked exactly once: a retry here is the storm.
  test "a rate limit is reported once, without a retry" do
    hex =
      FakeHex.start(%{@release => {429, %{"message" => "API rate limit exceeded"}}})

    capture_log(fn -> assert {:error, :rate_limited} = fetch(hex) end)
    assert FakeHex.requests(hex) == [@release]
  end

  test "a server error or a body that is not a release is unavailable, asked once" do
    for answer <- [{500, %{}}, {503, "<html>busy</html>"}, {200, "not json"}, {200, ["a"]}] do
      hex = FakeHex.start(%{@release => answer})

      capture_log(fn ->
        assert {:error, :hex_api_unavailable} = fetch(hex), "answer: #{inspect(answer)}"
      end)

      assert FakeHex.requests(hex) == [@release]
    end
  end

  test "a dropped connection is unavailable, not a raise" do
    hex = FakeHex.start(%{@release => :close})
    capture_log(fn -> assert {:error, :hex_api_unavailable} = fetch(hex) end)
  end

  test "a request that outlives its timeout is unavailable, within the timeout" do
    hex = FakeHex.start(%{@release => :hang})
    started = System.monotonic_time(:millisecond)

    capture_log(fn ->
      assert {:error, :hex_api_unavailable} = fetch(hex, "jason", "1.4.5", receive_timeout: 200)
    end)

    assert System.monotonic_time(:millisecond) - started < 2_000
  end

  # Each part is one path segment: nothing in a name or version may add
  # another, or reach a different endpoint.
  test "the package and version stay single path segments" do
    hex = FakeHex.start(%{})

    for {package, version} <- [{"../users", "me"}, {"jason", "1.0.0/../../x"}, {"a?b", "1#c"}] do
      assert {:error, _} = fetch(hex, package, version)
    end

    for path <- FakeHex.requests(hex) do
      assert ["", "api", "packages", _package, "releases", _version] = String.split(path, "/"),
             path
    end

    assert length(FakeHex.requests(hex)) == 3
  end
end
