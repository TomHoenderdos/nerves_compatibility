defmodule Portal.BuildCache.L2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Portal.BuildCache.L2
  alias Portal.BuildCache.L2.{Stats, Tarball}
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

  describe "prefetch/3" do
    @describetag :capture_log

    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2pf-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, "sha256_abc")
      File.mkdir_p!(slug_dir)
      on_exit(fn -> File.rm_rf(tmp) end)
      Stats.reset()
      %{s: s, cfg: s.config, tmp: tmp, slug_dir: slug_dir}
    end

    # An entry packed the way the uploader packs it, placed in the stub.
    defp seed(s, tmp, key, opts \\ []) do
      src = Path.join(tmp, "src-#{key}")
      File.mkdir_p!(Path.join(src, "ebin"))

      File.write!(
        Path.join(src, "ebin/Elixir.X.beam"),
        Keyword.get(opts, :content, "beam-" <> key)
      )

      if Keyword.get(opts, :priv_link),
        do: File.ln_s!("../../../../deps/x/priv", Path.join(src, "priv"))

      tar = Path.join(tmp, "#{key}.tar.gz")
      {:ok, %{sha256: sha}} = Tarball.pack(src, tar, :any)
      bytes = File.read!(tar)
      meta = %{"x-amz-meta-sha256" => Keyword.get(opts, :sha, sha)}
      FakeS3.put_object(s, "sha256_abc/#{key}.tar.gz", Keyword.get(opts, :body, bytes), meta)
      bytes
    end

    defp key(n), do: String.pad_leading(Integer.to_string(n), 64, "0")

    defp sha_meta(body),
      do: %{"x-amz-meta-sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}

    test "restores a missing key and leaves no staging behind", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1), priv_link: true)
      assert %{downloaded: 1, failed: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.read!(Path.join([slug_dir, key(1), "ebin/Elixir.X.beam"])) == "beam-" <> key(1)
      assert File.read_link!(Path.join([slug_dir, key(1), "priv"])) == "../../../../deps/x/priv"
      assert File.ls!(slug_dir) == [key(1)]
      assert %{downloads: 1} = Stats.snapshot()
    end

    test "skips keys present locally and names that are not keys", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      File.mkdir_p!(Path.join(slug_dir, key(1)))
      FakeS3.put_object(s, "sha256_abc/README", "x", %{})

      assert %{downloaded: 0, candidates: 0, listed: 2} =
               L2.prefetch(slug_dir, "sha256_abc", config: cfg)
    end

    test "a sha mismatch is refused, removed and marked bad", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1), sha: String.duplicate("f", 64))

      log =
        capture_log(fn ->
          assert %{failed: 1, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
        end)

      assert log =~ "sha256"
      assert File.ls!(slug_dir) == []
      assert Stats.bad?(key(1))
      assert %{refused: 1} = Stats.snapshot()
      assert %{candidates: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
    end

    test "a truncated tarball is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      cut = binary_part(bytes, 0, div(byte_size(bytes), 2))
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", cut, sha_meta(cut))
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
    end

    test "a short body from the transport is refused", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      FakeS3.set_fault(s, {:get, :truncate})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
    end

    test "a ../ member, an absolute member and a symlink out of the entry are each refused",
         %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      hostile = fn name, members ->
        path = Path.join(tmp, name)
        {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
        for {n, c} <- members, do: :ok = :erl_tar.add(tar, c, String.to_charlist(n), [])
        :ok = :erl_tar.close(tar)
        File.read!(path)
      end

      link_src = Path.join(tmp, "linksrc")
      File.mkdir_p!(Path.join(link_src, "ebin"))
      File.ln_s!("../../outside", Path.join(link_src, "priv"))
      link_tar = Path.join(tmp, "link.tar.gz")

      :ok =
        :erl_tar.create(
          String.to_charlist(link_tar),
          [
            {~c"ebin", String.to_charlist(Path.join(link_src, "ebin"))},
            {~c"priv", String.to_charlist(Path.join(link_src, "priv"))}
          ],
          [:compressed]
        )

      bodies = [
        {key(1), hostile.("dotdot.tar.gz", [{"../escape", "x"}])},
        {key(2), hostile.("abs.tar.gz", [{"/tmp/abs", "x"}])},
        {key(3), File.read!(link_tar)}
      ]

      for {k, body} <- bodies,
          do: FakeS3.put_object(s, "sha256_abc/#{k}.tar.gz", body, sha_meta(body))

      assert %{failed: 3, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
      refute File.exists?(Path.join(tmp, "escape"))
      refute File.exists?("/tmp/abs")
      assert Enum.all?([key(1), key(2), key(3)], &Stats.bad?/1)
    end

    test "an object that is not a tarball at all is refused and marked bad", %{
      s: s,
      cfg: cfg,
      slug_dir: slug_dir
    } do
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", "junk", sha_meta("junk"))
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert Stats.bad?(key(1))
      assert File.ls!(slug_dir) == []
    end

    test "a missing sha header is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", bytes, %{})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert Stats.bad?(key(1))
      assert File.ls!(slug_dir) == []
    end

    test "an object that went missing after the listing is a plain failure", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      FakeS3.set_fault(s, {:get, :status, 500})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      refute Stats.bad?(key(1))
      assert %{download_failures: 1, refused: 0} = Stats.snapshot()
      assert File.ls!(slug_dir) == []
    end

    test "an entry appearing locally during the download is discarded", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      dest = Path.join(slug_dir, key(1))

      FakeS3.on_get(s, fn _ ->
        File.mkdir_p!(Path.join(dest, "ebin"))
        File.write!(Path.join(dest, "ebin/local"), "mine")
      end)

      assert %{discarded: 1, downloaded: 0, failed: 0} =
               L2.prefetch(slug_dir, "sha256_abc", config: cfg)

      assert File.ls!(slug_dir) == [key(1)]
      assert File.ls!(Path.join(dest, "ebin")) == ["local"]
      assert %{discarded: 1, downloads: 0} = Stats.snapshot()
    end

    test "the byte budget stops the loop but lets a small entry behind a large one through", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      # Newest first: key(3) fits, key(2) does not, key(1) still does.
      small = seed(s, tmp, key(1), content: "small")
      _ = seed(s, tmp, key(2), content: :crypto.strong_rand_bytes(50_000))
      big = seed(s, tmp, key(3), content: :crypto.strong_rand_bytes(50_000))
      budget = byte_size(big) + byte_size(small) + 10

      assert %{downloaded: 2, skipped: 1} =
               L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_bytes: budget)

      assert Enum.sort(File.ls!(slug_dir)) == [key(1), key(3)]
    end

    test "the time budget stops the loop", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      for i <- 1..3, do: seed(s, tmp, key(i))
      test_pid = self()

      FakeS3.on_get(s, fn _ ->
        Process.sleep(60)
        send(test_pid, :get_answered)
      end)

      result = L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_ms: 50)
      # The client gave up on the GET; let the stub's handler finish before
      # the test stops the stub under it.
      assert_receive :get_answered, 2000
      Process.sleep(50)
      assert result.downloaded < 3
      assert result.skipped + result.downloaded + result.failed == 3
      assert result.skipped >= 1
    end

    test "an object over the per-object cap is skipped", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1), content: String.duplicate("x", 5000))

      assert %{candidates: 0} =
               L2.prefetch(slug_dir, "sha256_abc", config: cfg, max_object_bytes: 10)
    end

    test "an endpoint that is down lists nothing and says so", %{cfg: cfg, slug_dir: slug_dir} do
      log =
        capture_log(fn ->
          assert %{list_failed: true, downloaded: 0} =
                   L2.prefetch(slug_dir, "sha256_abc",
                     config: %{cfg | endpoint: "http://127.0.0.1:1"}
                   )
        end)

      assert log =~ "Build cache L2 listing of sha256_abc/ failed"
      assert %{list_failures: 1} = Stats.snapshot()
    end

    test "read-only mode still downloads", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))

      assert %{downloaded: 1} =
               L2.prefetch(slug_dir, "sha256_abc", config: %{cfg | read_only?: true})
    end

    test "with L2 off it does nothing", %{s: s, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      Application.delete_env(:portal, L2)
      assert %{listed: 0, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc")
      assert FakeS3.requests(s) == []
    end

    test "a key claimed by another build on this node is skipped", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      assert Stats.claim(key(1))
      assert %{skipped: 1, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      Stats.release(key(1))
    end

    test "newest objects come first", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      Process.sleep(1100)
      seed(s, tmp, key(2))
      small = byte_size(File.read!(Path.join(tmp, "#{key(2)}.tar.gz")))

      assert %{downloaded: 1} =
               L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_bytes: small + 10)

      assert File.ls!(slug_dir) == [key(2)]
    end
  end
end
