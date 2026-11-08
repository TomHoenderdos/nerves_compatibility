defmodule Compatibility.ConfigVariants.PhxNewDriftTest do
  # Reads the newest phx_new release on Hex. Excluded by default; the weekly
  # phx-new-drift workflow runs it.
  use ExUnit.Case, async: false

  alias Compatibility.ConfigVariants.PhxNew

  @moduletag :phx_new_drift

  # hex.pm refuses a request without one.
  @headers [{~c"user-agent", ~c"ncc-phx-new-drift"}]

  test "the newest phx_new sets the keys the pinned overlays carry" do
    # The compatibility app depends on no OTP app beyond :logger, and Mix
    # prunes the others from the code path.
    Enum.each([:inets, :ssl, :public_key], &Mix.ensure_application!/1)
    {:ok, _} = Application.ensure_all_started([:inets, :ssl])
    %{"latest_stable_version" => version} = get_json("https://hex.pm/api/packages/phx_new")
    templates = templates(get("https://repo.hex.pm/tarballs/phx_new-#{version}.tar"))
    assert PhxNew.drift(templates) == [], "phx_new #{version}"
  end

  defp templates(tarball) do
    {:ok, files} = :erl_tar.extract({:binary, tarball}, [:memory])
    {_, contents} = List.keyfind(files, ~c"contents.tar.gz", 0)
    {:ok, inner} = :erl_tar.extract({:binary, contents}, [:memory, :compressed])

    Map.new(~w(config.exs dev.exs test.exs prod.exs), fn name ->
      path = ~c"templates/phx_single/config/#{name}.eex"
      {_, text} = List.keyfind(inner, path, 0)
      {name, text}
    end)
  end

  defp get_json(url), do: url |> get() |> JSON.decode!()

  defp get(url) do
    opts = [ssl: [verify: :verify_peer, cacerts: :public_key.cacerts_get()]]

    {:ok, {{_, 200, _}, _, body}} =
      :httpc.request(:get, {~c"#{url}", @headers}, opts, body_format: :binary)

    body
  end
end
