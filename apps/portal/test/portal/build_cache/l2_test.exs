defmodule Portal.BuildCache.L2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Portal.BuildCache.L2

  @full [
    endpoint: "http://100.64.0.2:3900",
    bucket: "ncc-build-cache",
    region: "garage",
    access_key: "GK1",
    secret_key: "s"
  ]

  setup do
    old = Application.get_env(:portal, L2)
    old_builder = Application.get_env(:portal, Portal.Builder)
    # The test config logs warnings and up only; the "on" line is info.
    old_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      Logger.configure(level: old_level)
      restore(L2, old)
      restore(Portal.Builder, old_builder)
    end)
  end

  defp restore(key, nil), do: Application.delete_env(:portal, key)
  defp restore(key, value), do: Application.put_env(:portal, key, value)

  defp put(env), do: Application.put_env(:portal, L2, env)

  test "object_key is the slug dir plus the key" do
    assert L2.object_key("slug", "abc") == "slug/abc.tar.gz"
  end

  test "status is off with no config" do
    Application.delete_env(:portal, L2)
    assert %{state: :off, endpoint: nil, bucket: nil, counters: %{uploads: 0}} = L2.status()
  end

  test "status is on with a full config" do
    put(@full)

    assert %{state: :on, endpoint: "http://100.64.0.2:3900", bucket: "ncc-build-cache"} =
             L2.status()
  end

  test "status is incomplete with an endpoint alone" do
    put(endpoint: "http://100.64.0.2:3900")
    assert %{state: :incomplete} = L2.status()
  end

  test "enabled? needs a local build cache as well as a full config" do
    put(@full)
    base = Application.get_env(:portal, Portal.Builder, [])

    Application.put_env(:portal, Portal.Builder, Keyword.delete(base, :build_cache))
    refute L2.enabled?()

    Application.put_env(:portal, Portal.Builder, Keyword.put(base, :build_cache, "/tmp/bc"))
    assert L2.enabled?()

    Application.delete_env(:portal, L2)
    refute L2.enabled?()
  end

  test "log_state logs on, read-only, off and incomplete" do
    put(@full)

    assert capture_log(fn -> assert :ok = L2.log_state() end) =~
             "Build cache L2 on: http://100.64.0.2:3900/ncc-build-cache"

    put(Keyword.put(@full, :read_only, true))
    assert capture_log(fn -> L2.log_state() end) =~ "(read-only)"

    Application.delete_env(:portal, L2)
    assert capture_log(fn -> L2.log_state() end) =~ "Build cache L2 off"

    put(endpoint: "http://100.64.0.2:3900")
    assert capture_log(fn -> L2.log_state() end) =~ "NCC_BUILD_CACHE_S3_BUCKET"
  end
end
