defmodule Portal.BuildCache.L2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Portal.BuildCache.L2
  alias Portal.BuildCache.L2.Stats
  alias Portal.Test.FakeS3

  @full [
    endpoint: "http://100.64.0.2:3900",
    bucket: "ncc-build-cache",
    region: "garage",
    access_key: "GK1",
    secret_key: "s"
  ]

  setup do
    Stats.reset()
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

  describe "upload/4" do
    @describetag :capture_log

    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2up-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, "sha256_abc")
      key = String.duplicate("a", 64)
      entry = Path.join(slug_dir, key)
      File.mkdir_p!(Path.join(entry, "ebin"))
      File.write!(Path.join(entry, "ebin/Elixir.Jason.beam"), "beam")
      on_exit(fn -> File.rm_rf(tmp) end)
      Stats.reset()
      %{s: s, cfg: s.config, slug_dir: slug_dir, entry: entry, key: key}
    end

    test "stores the entry as <slug>/<key>.tar.gz with its sha", %{
      s: s,
      cfg: cfg,
      entry: entry,
      key: key,
      slug_dir: slug_dir
    } do
      assert {:ok, bytes} = L2.upload(entry, "sha256_abc", key, "jason", config: cfg)

      assert {:ok, %{body: body, meta: %{"x-amz-meta-sha256" => sha}}} =
               FakeS3.get_object(s, "sha256_abc/#{key}.tar.gz")

      assert sha == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert File.ls!(slug_dir) == [key], "no tarball left beside the entry"
      assert %{uploads: 1, upload_failures: 0} = Stats.snapshot()
      assert Stats.snapshot().bytes_up == byte_size(body)
      assert bytes == byte_size(body)
    end

    test "read-only mode uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      assert :skipped =
               L2.upload(entry, "sha256_abc", key, "jason", config: %{cfg | read_only?: true})

      assert FakeS3.objects(s) == []
    end

    test "an endpoint that is down is logged and counted, never raised", %{
      cfg: cfg,
      entry: entry,
      key: key
    } do
      log =
        capture_log(fn ->
          assert {:error, _} =
                   L2.upload(entry, "sha256_abc", key, "jason",
                     config: %{cfg | endpoint: "http://127.0.0.1:1"}
                   )
        end)

      assert log =~ "Build cache L2 upload of sha256_abc/#{key}.tar.gz failed"
      assert %{upload_failures: 1} = Stats.snapshot()
    end

    test "a structural refusal uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      File.ln_s!("/etc/hostname", Path.join(entry, "ebin/evil"))
      assert {:error, _} = L2.upload(entry, "sha256_abc", key, "jason", config: cfg)
      assert FakeS3.objects(s) == []
    end

    test "with L2 off it is skipped", %{entry: entry, key: key} do
      assert :skipped = L2.upload(entry, "sha256_abc", key, "jason", config: nil)
    end
  end
end
