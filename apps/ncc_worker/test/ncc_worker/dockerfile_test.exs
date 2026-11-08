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

  # CI builds the amd64 and arm64 images in separate jobs: a floating tag
  # could resolve to a different base for each. The multi-arch index digest
  # names one base for both, with its version tag kept for reading.
  test "the base is pinned by its multi-arch index digest", %{text: text} do
    assert Regex.match?(
             ~r/^FROM ghcr\.io\/nerves-project\/nerves_system_br:\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$/m,
             text
           )

    refute text =~ "nerves_system_br:latest"
  end

  # Hex is pinned, never the floating latest: Hex 2.6 renamed its registry
  # cache, and `NccWorker.HexHome` shares that file between targets only under
  # the name the pinned Hex uses. A bump to a Hex `HexHome.registry_file/1`
  # does not know fails here until someone checks what it writes.
  test "both images pin the same Hex, whose registry file HexHome shares", %{text: text} do
    pins =
      for t <- [text, File.read!(@toolchain_dockerfile)] do
        refute t =~ ~r/mix local\.hex --force/
        assert [_, version] = Regex.run(~r/^ARG HEX_VERSION=(\S+)$/m, t)
        assert t =~ ~r/mix local\.hex \$\{HEX_VERSION\} --force/
        version
      end

    assert [version] = Enum.uniq(pins)
    assert {:ok, name} = NccWorker.HexHome.registry_file(version)
    assert name == hd(NccWorker.HexHome.registry_files())
  end

  test "makes the home and app directories readable, not writable, by any uid", %{text: text} do
    assert text =~ "chmod -R a+rX /home/nerves /app"
    refute text =~ "a+rwX"
  end

  # The worker's cleanup of leftover processes uses kill(1) where there is one
  # (`NccWorker.OsKill`); the slim toolchain base has no procps.
  test "the toolchain image installs procps for kill(1)" do
    assert File.read!(@toolchain_dockerfile) =~ ~r/apt-get install[^\n]*\n?[^\n]*\bprocps\b/
  end

  # A cmake-based NIF build (elixir_make or a rebar3 port hook calling
  # cmake) must not fail on one toolchain only: the main image's
  # nerves_system_br base ships cmake, the slim toolchain base does not.
  test "the toolchain image installs cmake, as the main image's base has it" do
    assert File.read!(@toolchain_dockerfile) =~ ~r/apt-get install[^\n]*\n?[^\n]*\bcmake\b/
  end
end
