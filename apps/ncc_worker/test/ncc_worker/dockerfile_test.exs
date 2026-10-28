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

  @toolchain_dockerfile Path.expand("../../Dockerfile.toolchain", __DIR__)

  test "pre-creates every directory the portal mounts", %{text: text} do
    for target <-
          ~w(/work /out /files /tmp /hex-cache /nerves-cache /home/nerves/.cache /build-cache) do
      assert Regex.match?(~r/mkdir -p[^\n]*\s#{Regex.escape(target)}(\s|$)/m, text),
             "Dockerfile does not mkdir -p #{target}"
    end
  end

  # Nerves is pointed at the per-run farm or the mounted cache in every mode
  # (`NccWorker.NervesCache`); a ~/.nerves would only invite a fallback.
  test "neither image refers to ~/.nerves", %{text: text} do
    refute text =~ "/home/nerves/.nerves"
    refute File.read!(@toolchain_dockerfile) =~ "/home/nerves/.nerves"
  end

  test "the toolchain image pre-creates the Nerves cache mount point too" do
    assert File.read!(@toolchain_dockerfile) =~ ~r/mkdir -p[^\n]*\s\/nerves-cache(\s|$)/m
  end

  # The host mounts /hex-cache read-only only for an image that says its
  # worker seeds a per-run HEX_HOME (`Compatibility.Builder.Argv`).
  test "both images carry the seeded Hex cache label", %{text: text} do
    assert text =~ ~r/^LABEL ncc\.hex-cache=seeded$/m
    assert File.read!(@toolchain_dockerfile) =~ ~r/^LABEL ncc\.hex-cache=seeded$/m
  end

  test "makes the home and app directories readable, not writable, by any uid", %{text: text} do
    assert text =~ "chmod -R a+rX /home/nerves /app"
    refute text =~ "a+rwX"
  end
end
