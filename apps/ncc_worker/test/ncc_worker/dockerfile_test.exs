defmodule NccWorker.DockerfileTest do
  use ExUnit.Case, async: true

  # The portal runs the image --read-only (Portal.Builder), which has two
  # consequences the Dockerfile has to honour: every mount target must already
  # exist, because docker will not create one on a read-only root, and nothing
  # needs to be world-writable any more, only world-readable for a host uid
  # that is not the image's nerves user.
  @dockerfile Path.expand("../../Dockerfile", __DIR__)

  setup_all do
    {:ok, text: File.read!(@dockerfile)}
  end

  test "pre-creates every directory the portal mounts", %{text: text} do
    for target <-
          ~w(/work /out /files /tmp /hex-cache /home/nerves/.nerves /home/nerves/.cache /build-cache) do
      assert Regex.match?(~r/mkdir -p[^\n]*\s#{Regex.escape(target)}(\s|$)/m, text),
             "Dockerfile does not mkdir -p #{target}"
    end
  end

  test "makes the home and app directories readable, not writable, by any uid", %{text: text} do
    assert text =~ "chmod -R a+rX /home/nerves /app"
    refute text =~ "a+rwX"
  end
end
