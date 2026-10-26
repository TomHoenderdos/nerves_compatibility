defmodule Portal.BuildCache.L2Test do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Portal.BuildCache.L2
  alias Portal.BuildCache.L2.{Stats, Tarball}
  alias Portal.Test.FakeS3

  @slug "sha256_" <> String.duplicate("ab", 32)

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

  test "log_state warns about plain http outside the private network, and only there" do
    put(@full)
    refute capture_log(fn -> L2.log_state() end) =~ "tampered"

    put(Keyword.put(@full, :endpoint, "http://10.1.2.3:3900"))
    log = capture_log(fn -> L2.log_state() end)
    assert log =~ "Build cache L2 on: http://10.1.2.3:3900/ncc-build-cache"

    assert log =~
             "Build cache L2 endpoint http://10.1.2.3:3900 is plain http outside the private network; " <>
               "entries can be tampered with in transit"

    put(Keyword.put(@full, :endpoint, "https://garage.example"))
    refute capture_log(fn -> L2.log_state() end) =~ "tampered"
  end

  test "shareable_slug? takes a full sha256 digest only" do
    assert L2.shareable_slug?(@slug)
    refute L2.shareable_slug?("sha256_" <> String.duplicate("0", 64))
    refute L2.shareable_slug?("sha256_abc")
    refute L2.shareable_slug?("sha256_" <> String.duplicate("A", 64))
    refute L2.shareable_slug?("unknown")
    refute L2.shareable_slug?(@slug <> "\n")
    refute L2.shareable_slug?(nil)
  end

  describe "upload/4" do
    @describetag :capture_log

    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2up-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, @slug)
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
      assert {:ok, bytes} = L2.upload(entry, @slug, key, "jason", config: cfg)

      assert {:ok, %{body: body, meta: %{"x-amz-meta-sha256" => sha}}} =
               FakeS3.get_object(s, "#{@slug}/#{key}.tar.gz")

      assert sha == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert File.ls!(slug_dir) == [key], "no tarball left beside the entry"
      assert %{uploads: 1, upload_failures: 0} = Stats.snapshot()
      assert Stats.snapshot().bytes_up == byte_size(body)
      assert bytes == byte_size(body)
    end

    test "read-only mode uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      assert :skipped =
               L2.upload(entry, @slug, key, "jason", config: %{cfg | read_only?: true})

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
                   L2.upload(entry, @slug, key, "jason",
                     config: %{cfg | endpoint: "http://127.0.0.1:1"}
                   )
        end)

      assert log =~ "Build cache L2 upload of #{@slug}/#{key}.tar.gz failed"
      assert %{upload_failures: 1} = Stats.snapshot()
    end

    test "a structural refusal uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      File.ln_s!("/etc/hostname", Path.join(entry, "ebin/evil"))
      assert {:error, _} = L2.upload(entry, @slug, key, "jason", config: cfg)
      assert FakeS3.objects(s) == []
    end

    test "with L2 off it is skipped", %{entry: entry, key: key} do
      assert :skipped = L2.upload(entry, @slug, key, "jason", config: nil)
    end

    test "a slug that is not a full digest is skipped, with one info line", %{
      s: s,
      cfg: cfg,
      entry: entry,
      key: key
    } do
      for slug <- ["sha256_abc", "unknown", "sha256_" <> String.duplicate("0", 64)] do
        log =
          capture_log(fn ->
            assert :skipped = L2.upload(entry, slug, key, "jason", config: cfg)
          end)

        assert log =~ "is not shareable"
      end

      assert FakeS3.objects(s) == []
      assert FakeS3.requests(s) == []
    end

    test "the upload honours timeout_ms and is counted as a failure", %{
      s: s,
      cfg: cfg,
      entry: entry,
      key: key,
      slug_dir: slug_dir
    } do
      FakeS3.set_fault(s, {:put, :hang})

      {micros, result} =
        :timer.tc(fn -> L2.upload(entry, @slug, key, "jason", config: cfg, timeout_ms: 200) end)

      assert {:error, :timeout} = result
      assert micros < 1_000_000
      assert %{upload_failures: 1} = Stats.snapshot()
      assert File.ls!(slug_dir) == [key], "no tarball left beside the entry"
    end
  end

  describe "prefetch/3" do
    @describetag :capture_log

    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2pf-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, @slug)
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
      FakeS3.put_object(s, "#{@slug}/#{key}.tar.gz", Keyword.get(opts, :body, bytes), meta)
      bytes
    end

    defp object_gets(s) do
      for {"GET", path, _query} <- FakeS3.requests(s), String.contains?(path, ".tar.gz"), do: path
    end

    defp key(n), do: String.pad_leading(Integer.to_string(n), 64, "0")

    # The host's real free space is not this test's business unless it says so.
    defp prefetch(slug_dir, opts),
      do: L2.prefetch(slug_dir, @slug, Keyword.put_new(opts, :free_bytes, fn _ -> nil end))

    defp sha_meta(body),
      do: %{"x-amz-meta-sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)}

    test "restores a missing key and leaves no staging behind", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1), priv_link: true)
      assert %{downloaded: 1, failed: 0} = prefetch(slug_dir, config: cfg)
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
      FakeS3.put_object(s, "#{@slug}/README", "x", %{})

      assert %{downloaded: 0, candidates: 0, listed: 2} =
               prefetch(slug_dir, config: cfg)
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
          assert %{failed: 1, downloaded: 0} = prefetch(slug_dir, config: cfg)
        end)

      assert log =~ "sha256"
      assert File.ls!(slug_dir) == []
      assert Stats.bad?(key(1))
      assert %{refused: 1} = Stats.snapshot()
      assert %{candidates: 0} = prefetch(slug_dir, config: cfg)
    end

    test "a truncated tarball is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      cut = binary_part(bytes, 0, div(byte_size(bytes), 2))
      FakeS3.put_object(s, "#{@slug}/#{key(1)}.tar.gz", cut, sha_meta(cut))
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
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
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
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
          do: FakeS3.put_object(s, "#{@slug}/#{k}.tar.gz", body, sha_meta(body))

      assert %{failed: 3, downloaded: 0} = prefetch(slug_dir, config: cfg)
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
      FakeS3.put_object(s, "#{@slug}/#{key(1)}.tar.gz", "junk", sha_meta("junk"))
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
      assert Stats.bad?(key(1))
      assert File.ls!(slug_dir) == []
    end

    test "a missing sha header is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      FakeS3.put_object(s, "#{@slug}/#{key(1)}.tar.gz", bytes, %{})
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
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
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
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
               prefetch(slug_dir, config: cfg)

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
               prefetch(slug_dir, config: cfg, budget_bytes: budget)

      assert Enum.sort(File.ls!(slug_dir)) == [key(1), key(3)]
    end

    test "the time budget stops the loop, skipping rather than starting a GET it cannot finish",
         %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      for i <- 1..3, do: seed(s, tmp, key(i))
      FakeS3.on_get(s, fn _ -> Process.sleep(600) end)

      log =
        capture_log(fn ->
          result = prefetch(slug_dir, config: cfg, budget_ms: 1500)
          # One GET fits; after it under a second is left, too little to start another.
          assert %{downloaded: 1, skipped: 2, failed: 0} = result
        end)

      refute log =~ "failed"
      assert length(object_gets(s)) == 1
    end

    test "a listing slower than the budget counts as a failed listing", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      test_pid = self()

      FakeS3.on_list(s, fn _ ->
        Process.sleep(1000)
        send(test_pid, :list_answered)
      end)

      {micros, result} =
        :timer.tc(fn -> prefetch(slug_dir, config: cfg, budget_ms: 100) end)

      assert %{list_failed: true, downloaded: 0} = result
      assert micros < 700_000
      assert %{list_failures: 1} = Stats.snapshot()
      # Let the stub's handler finish before the test stops the stub under it.
      assert_receive :list_answered, 3000
      Process.sleep(50)
    end

    test "a store answering 5xx on GET stops the loop at the first object", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      for i <- 1..3, do: seed(s, tmp, key(i))
      FakeS3.set_fault(s, {:get, :status, 503})
      assert %{failed: 1, skipped: 2} = prefetch(slug_dir, config: cfg)
      assert length(object_gets(s)) == 1
      refute Enum.any?(1..3, &Stats.bad?(key(&1)))
    end

    test "five failures in a row stop the loop; a missing object alone does not", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      for i <- 1..7, do: seed(s, tmp, key(i))
      # Every object vanishes between the listing and its GET: a 404 each.
      FakeS3.on_get(s, fn object -> FakeS3.delete_object(s, object) end)
      assert %{failed: 5, skipped: 2} = prefetch(slug_dir, config: cfg)
      assert length(object_gets(s)) == 5
    end

    test "an empty object is refused and marked bad", %{s: s, cfg: cfg, slug_dir: slug_dir} do
      FakeS3.put_object(s, "#{@slug}/#{key(1)}.tar.gz", "", sha_meta(""))
      assert %{failed: 1} = prefetch(slug_dir, config: cfg)
      assert Stats.bad?(key(1))
    end

    test "an object over the per-object cap is skipped", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1), content: String.duplicate("x", 5000))

      assert %{candidates: 0} =
               prefetch(slug_dir, config: cfg, max_object_bytes: 10)
    end

    test "an endpoint that is down lists nothing and says so", %{cfg: cfg, slug_dir: slug_dir} do
      log =
        capture_log(fn ->
          assert %{list_failed: true, downloaded: 0} =
                   prefetch(slug_dir,
                     config: %{cfg | endpoint: "http://127.0.0.1:1"}
                   )
        end)

      assert log =~ "Build cache L2 listing of #{@slug}/ failed"
      assert %{list_failures: 1} = Stats.snapshot()
    end

    test "read-only mode still downloads", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))

      assert %{downloaded: 1} =
               prefetch(slug_dir, config: %{cfg | read_only?: true})
    end

    test "with L2 off it does nothing", %{s: s, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      Application.delete_env(:portal, L2)
      assert %{listed: 0, downloaded: 0} = L2.prefetch(slug_dir, @slug)
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
      assert %{skipped: 1, downloaded: 0} = prefetch(slug_dir, config: cfg)
      Stats.release(key(1))
    end

    test "a slug that is not a full digest is not even listed", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))

      log =
        capture_log(fn ->
          assert %{listed: 0, downloaded: 0} =
                   L2.prefetch(slug_dir, "sha256_abc", config: cfg, free_bytes: fn _ -> nil end)
        end)

      assert log =~ "is not shareable"
      assert FakeS3.requests(s) == []
    end

    test "free space under the minimum stops the loop before the next object, warning once", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      for i <- 1..3, do: seed(s, tmp, key(i))
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      free = fn dir ->
        assert dir == slug_dir
        if Agent.get_and_update(calls, &{&1, &1 + 1}) == 0, do: 10_000, else: 10
      end

      log =
        capture_log(fn ->
          assert %{downloaded: 1, skipped: 2, failed: 0} =
                   prefetch(slug_dir, config: cfg, free_bytes: free, min_free_bytes: 1_000)
        end)

      assert length(Regex.scan(~r/stopped: 10 bytes free/, log)) == 1
      assert length(object_gets(s)) == 1
    end

    test "the extracted-bytes budget stops the loop", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      for i <- 1..3, do: seed(s, tmp, key(i))

      assert %{downloaded: 1, skipped: 2, extracted_bytes: extracted} =
               prefetch(slug_dir, config: cfg, extracted_budget_bytes: 1)

      assert extracted > 0
      assert length(object_gets(s)) == 1
    end

    test "an object replaced by a bigger one after the listing is a plain failure", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      seed(s, tmp, key(1))
      object = "#{@slug}/#{key(1)}.tar.gz"
      bigger = :crypto.strong_rand_bytes(100_000)
      FakeS3.on_get(s, fn _ -> FakeS3.put_object(s, object, bigger, sha_meta(bigger)) end)

      assert %{failed: 1, downloaded: 0} = prefetch(slug_dir, config: cfg)
      refute Stats.bad?(key(1))
      assert %{download_failures: 1, refused: 0} = Stats.snapshot()
      assert File.ls!(slug_dir) == []
    end

    test "a raise inside the listing task and a throw in the loop both come back as counts", %{
      s: s,
      cfg: cfg,
      tmp: tmp,
      slug_dir: slug_dir
    } do
      # A bucket that is not a string makes `Client.list/2` raise inside the
      # listing task.
      assert %{list_failed: true} = prefetch(slug_dir, config: %{cfg | bucket: nil})

      # A `free_bytes` seam that throws does so in the loop, outside any task,
      # where only `L2.prefetch/3`'s own boundary can catch it.
      seed(s, tmp, key(1))

      log =
        capture_log(fn ->
          assert %{failed: 1, downloaded: 0} =
                   prefetch(slug_dir, config: cfg, free_bytes: fn _ -> throw(:boom) end)
        end)

      assert log =~ "{:throw, :boom}"
      assert Process.alive?(self())
    end

    test "newest objects come first", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      Process.sleep(1100)
      seed(s, tmp, key(2))
      small = byte_size(File.read!(Path.join(tmp, "#{key(2)}.tar.gz")))

      assert %{downloaded: 1} =
               prefetch(slug_dir, config: cfg, budget_bytes: small + 10)

      assert File.ls!(slug_dir) == [key(2)]
    end
  end

  describe "Prefetch.classify/1" do
    alias Portal.BuildCache.L2.Prefetch

    test "what the object did is refused; what this host or the store did is not" do
      for reason <- [
            :no_sha256_header,
            :too_large,
            :empty_archive,
            :empty,
            {:sha256_mismatch, "a", "b"},
            {:tar, :eof},
            {:tar, {~c"x", :unsafe_path}},
            {:tar, :eacces},
            {:tar, :eperm},
            {:gzip, :data_error},
            {:unpack, :killed},
            {:unpack, :timeout},
            :empty_entry,
            {:structure, :symlink},
            {:member_type, :symlink, "x"},
            {:member_name, "x"},
            {:links, {:bad_target, "x"}},
            {:links, :not_a_map}
          ] do
        assert {:refused, _} = Prefetch.classify(reason), inspect(reason)
      end

      for reason <- [
            {:tar, :enospc},
            {:tar, :eio},
            {:links, :eacces},
            {:links, :enospc},
            {:links, :eio},
            :not_found,
            :eexist,
            :larger_than_listed,
            {:rename, :exdev}
          ] do
        assert {:failed, :go} = Prefetch.classify(reason), inspect(reason)
      end
    end

    test "a failing store stops the loop" do
      for reason <- [
            :timeout,
            {:status, 401},
            {:status, 403},
            {:status, 500},
            {:status, 503},
            {:exit, :killed},
            {:exception, "boom"},
            {:throw, :boom},
            :budget_spent,
            %Req.TransportError{reason: :econnrefused}
          ] do
        assert {:failed, :stop} = Prefetch.classify(reason), inspect(reason)
      end

      assert {:failed, :go} = Prefetch.classify({:status, 404})
      assert {:failed, :go} = Prefetch.classify({:status, 400})
    end
  end
end
