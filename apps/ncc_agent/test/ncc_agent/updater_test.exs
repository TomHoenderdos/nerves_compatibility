defmodule NccAgent.UpdaterTest do
  use ExUnit.Case, async: false

  # Refused updates are logged.
  @moduletag :capture_log

  alias NccAgent.{Config, Updater}
  alias NccAgent.Test.{CA, FakePortal, Release}

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-updater-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))

    {tarball, sha} = Release.tarball(dir)
    %{url: url} = FakePortal.start(ca, self(), %{releases: %{"agent-x.tar.gz" => tarball}})

    config = %{Config.defaults() | portal_url: url, data_dir: Path.join(dir, "data")}

    on_exit(fn ->
      Updater.clear_updating()
      File.rm_rf(dir)
    end)

    test_pid = self()

    opts = [
      current: "1700000000.abc",
      stop_fun: fn -> send(test_pid, :stopped) end,
      stop_delay_ms: 0,
      req_options: [connect_options: [transport_opts: [cacertfile: Path.join(ca.dir, "ca.pem")]]]
    ]

    %{config: config, url: url, sha: sha, opts: opts}
  end

  defp claim(url, sha) do
    %{
      "min_agent_version" => "1800000000.def",
      "agent_releases" => %{
        Release.arch() => %{"url" => url <> "/releases/agent-x.tar.gz", "sha256" => sha}
      }
    }
  end

  test "a newer release is downloaded, verified, extracted and made current", %{
    config: config,
    url: url,
    sha: sha,
    opts: opts
  } do
    refute Updater.updating?()
    assert {:updating, "1800000000.def"} = Updater.maybe_update(claim(url, sha), config, opts)
    assert Updater.updating?()
    assert_receive :stopped, 1_000

    releases = Config.path(config, :releases)
    current = Path.join(releases, "current")
    assert {:ok, link} = :file.read_link(String.to_charlist(current))
    assert to_string(link) == "1800000000.def/ncc_agent"
    assert File.read!(Path.join(current, "bin/ncc_agent")) =~ "echo new"
    refute File.exists?(Path.join(releases, "1800000000.def.tar.gz"))

    # Installed already: nothing to do until the restart.
    assert :ok = Updater.maybe_update(claim(url, sha), config, opts)
  end

  test "concurrent callers perform one update", %{config: config, url: url, sha: sha, opts: opts} do
    results =
      1..2
      |> Enum.map(fn _ ->
        Task.async(fn -> Updater.maybe_update(claim(url, sha), config, opts) end)
      end)
      |> Task.await_many(10_000)

    assert Enum.sort(results) == [:ok, {:updating, "1800000000.def"}]
    assert_receive {:portal_request, "GET", "/releases/agent-x.tar.gz", _, _}
    refute_receive {:portal_request, "GET", "/releases/agent-x.tar.gz", _, _}, 200
    assert_receive :stopped, 1_000
    refute_received :stopped
  end

  test "a hash mismatch leaves the current release alone", %{
    config: config,
    url: url,
    opts: opts
  } do
    bad = String.duplicate("0", 64)
    assert :ok = Updater.maybe_update(claim(url, bad), config, opts)
    refute Updater.updating?()
    refute_receive :stopped, 100
    refute File.exists?(Path.join(Config.path(config, :releases), "current"))
    refute File.exists?(Path.join(Config.path(config, :releases), "1800000000.def"))
  end

  test "a crash during the update is contained", %{config: config, url: url, opts: opts} do
    # Req raises on a url without a scheme, inside the update task; the
    # server lives on.
    claim = put_in(claim(url, "x"), ["agent_releases", Release.arch(), "url"], "not a url")
    assert :ok = Updater.maybe_update(claim, config, opts)
    assert Process.alive?(Process.whereis(Updater))
    refute Updater.updating?()
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
    refute_receive :stopped, 100
    refute File.exists?(Path.join(Config.path(config, :releases), "current"))
  end
end
