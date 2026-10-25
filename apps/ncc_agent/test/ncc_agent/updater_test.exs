defmodule NccAgent.UpdaterTest do
  use ExUnit.Case, async: false

  # Failed chowns (not root here), timeouts, crashes and refused updates are logged.
  @moduletag :capture_log

  alias NccAgent.{Config, Updater}
  alias NccAgent.Test.{CA, FakePortal}

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-updater-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))

    tarball = release_tarball(dir)
    sha = :crypto.hash(:sha256, tarball) |> Base.encode16(case: :lower)
    %{url: url} = FakePortal.start(ca, self(), %{releases: %{"agent-x.tar.gz" => tarball}})

    config = %{Config.defaults() | portal_url: url, data_dir: Path.join(dir, "data")}
    on_exit(fn -> File.rm_rf(dir) end)

    test_pid = self()

    opts = [
      current: "1700000000.abc",
      stop_fun: fn -> send(test_pid, :stopped) end,
      req_options: [connect_options: [transport_opts: [cacertfile: Path.join(ca.dir, "ca.pem")]]]
    ]

    %{config: config, url: url, sha: sha, opts: opts}
  end

  defp release_tarball(dir) do
    src = Path.join(dir, "src")
    File.mkdir_p!(Path.join(src, "ncc_agent/bin"))
    File.write!(Path.join(src, "ncc_agent/bin/ncc_agent"), "#!/bin/sh\necho new\n")
    out = Path.join(dir, "release.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(out),
        [
          {~c"ncc_agent/bin/ncc_agent",
           String.to_charlist(Path.join(src, "ncc_agent/bin/ncc_agent"))}
        ],
        [:compressed]
      )

    File.read!(out)
  end

  defp claim(url, sha) do
    %{
      "min_agent_version" => "1800000000.def",
      "agent_releases" => %{
        arch() => %{"url" => url <> "/releases/agent-x.tar.gz", "sha256" => sha}
      }
    }
  end

  defp arch do
    arch = to_string(:erlang.system_info(:system_architecture))
    if String.starts_with?(arch, "aarch64"), do: "aarch64", else: "x86_64"
  end

  test "a newer release is downloaded, verified, extracted and made current", %{
    config: config,
    url: url,
    sha: sha,
    opts: opts
  } do
    assert {:updating, "1800000000.def"} = Updater.maybe_update(claim(url, sha), config, opts)
    assert_received :stopped

    releases = Config.path(config, :releases)
    current = Path.join(releases, "current")
    assert {:ok, link} = :file.read_link(String.to_charlist(current))
    assert to_string(link) == "1800000000.def/ncc_agent"
    assert File.read!(Path.join(current, "bin/ncc_agent")) =~ "echo new"
    refute File.exists?(Path.join(releases, "1800000000.def.tar.gz"))
  end

  test "a hash mismatch leaves the current release alone", %{
    config: config,
    url: url,
    opts: opts
  } do
    bad = String.duplicate("0", 64)
    assert :ok = Updater.maybe_update(claim(url, bad), config, opts)
    refute_received :stopped
    refute File.exists?(Path.join(Config.path(config, :releases), "current"))
    refute File.exists?(Path.join(Config.path(config, :releases), "1800000000.def"))
  end

  test "an older or equal version, a missing arch and a dev build do nothing", %{
    config: config,
    url: url,
    sha: sha,
    opts: opts
  } do
    claim = claim(url, sha)

    assert :ok =
             Updater.maybe_update(%{claim | "min_agent_version" => "1600000000.x"}, config, opts)

    assert :ok = Updater.maybe_update(%{claim | "agent_releases" => %{}}, config, opts)
    assert :ok = Updater.maybe_update(%{claim | "min_agent_version" => nil}, config, opts)
    # The test build is a dev build ("0.dev"), which never updates.
    assert :ok = Updater.maybe_update(claim, config, Keyword.delete(opts, :current))
    refute_received :stopped
    refute File.exists?(Path.join(Config.path(config, :releases), "current"))
  end
end
