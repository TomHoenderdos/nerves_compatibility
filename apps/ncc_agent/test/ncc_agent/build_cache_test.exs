defmodule NccAgent.BuildCacheTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Compatibility.BuildCache.Tarball
  alias NccAgent.{BuildCache, Config, Identity}
  alias NccAgent.Test.{CA, FakeBlobs, FakePortal}

  @lease "5b0c8a8e-1111-4c2d-9e3f-0a1b2c3d4e5f"
  @hex String.duplicate("a", 64)
  @digest "sha256:" <> @hex
  @slug "sha256_" <> @hex

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-bc-#{System.unique_integer([:positive])}")
    ca = CA.new(Path.join(dir, "ca"))
    %{url: url, script: script} = FakePortal.start(ca, self(), %{})
    blobs = FakeBlobs.start(self())

    # Entries end up owned by the agent's own user (`Fs.own_tree/1`) and
    # only readable by NCC_BUILD_USER.
    config = %{
      Config.defaults()
      | portal_url: url,
        data_dir: Path.join(dir, "data"),
        enrolment_token: "id.c2VjcmV0c2VjcmV0.#{ca.prefix}",
        memory: "4g"
    }

    Config.put(config)
    {:ok, req} = Identity.ensure()
    on_exit(fn -> File.rm_rf(dir) end)
    flush()

    %{
      req: req,
      config: config,
      script: script,
      blobs: blobs,
      dir: dir,
      slug_dir: Path.join([config.data_dir, "build-cache", @slug])
    }
  end

  defp flush do
    receive do
      _ -> flush()
    after
      0 -> :ok
    end
  end

  defp claim(digest \\ @digest),
    do: %{"lease_id" => @lease, "image" => %{"name" => "ghcr.io/x/w", "digest" => digest}}

  defp key(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  # A real entry tarball served at its object path; returns the offer entry.
  defp entry(ctx, key, opts \\ []) do
    src = Path.join(ctx.dir, "src-" <> key)
    File.mkdir_p!(Path.join(src, "ebin"))

    File.write!(
      Path.join(src, "ebin/Elixir.Dep.beam"),
      Keyword.get(opts, :content, "beam " <> key)
    )

    File.ln_s!("../../../../deps/dep/priv", Path.join(src, "priv"))
    tar = Path.join(ctx.dir, key <> ".tar.gz")
    {:ok, %{sha256: sha}} = Tarball.pack(src, tar, :any)
    body = Keyword.get(opts, :body, File.read!(tar))
    path = "/ncc/#{@slug}/#{key}.tar.gz"
    FakeBlobs.put(ctx.blobs, path, body)

    %{
      "key" => key,
      "sha256" => Keyword.get(opts, :sha256, sha),
      "size" => Keyword.get(opts, :size, byte_size(body)),
      "url" => ctx.blobs.url <> path <> "?X-Amz-Signature=deadbeef&X-Amz-Credential=GK%2Fsecret"
    }
  end

  defp offer(ctx, entries, slug \\ @slug) do
    Agent.update(ctx.script, &Map.put(&1, :build_cache, {200, %{slug: slug, entries: entries}}))
  end

  test "fetches, verifies and extracts the offered entries, and mounts the slug", ctx do
    offer(ctx, [entry(ctx, key(1)), entry(ctx, key(2))])

    log =
      capture_log(fn -> send(self(), {:r, BuildCache.prepare(ctx.req, claim(), ctx.config)}) end)

    assert_received {:r, {dir, line}}

    assert dir == ctx.slug_dir
    assert line =~ "2 downloaded"
    assert BuildCache.entries(dir) == [key(1), key(2)]
    assert File.read!(Path.join([dir, key(1), "ebin/Elixir.Dep.beam"])) == "beam " <> key(1)
    assert {:ok, "../../../../deps/dep/priv"} = File.read_link(Path.join([dir, key(1), "priv"]))
    refute File.exists?(Path.join([dir, key(1), ".ncc-links.json"]))
    # Nothing but the entries is left in the slug dir.
    assert File.ls!(dir) |> Enum.sort() == [key(1), key(2)]

    assert_received {:portal_request, "POST", "/builder/v1/jobs/" <> _, %{"have" => []}, fp}
    assert is_binary(fp)
    refute log =~ "X-Amz"
    refute log =~ "secret"
  end

  test "a published entry is the agent's own, dirs 0755 and files 0644, whatever the archive said",
       ctx do
    src = Path.join(ctx.dir, "modes")
    File.mkdir_p!(Path.join(src, "ebin"))
    File.mkdir_p!(Path.join(src, "priv_bin"))
    File.write!(Path.join(src, "ebin/Elixir.Dep.beam"), "beam")
    File.write!(Path.join(src, "priv_bin/tool"), "#!/bin/sh\n")
    File.chmod!(Path.join(src, "ebin/Elixir.Dep.beam"), 0o600)
    File.chmod!(Path.join(src, "priv_bin/tool"), 0o700)
    File.chmod!(Path.join(src, "ebin"), 0o700)
    tar = Path.join(ctx.dir, "modes.tar.gz")
    {:ok, %{sha256: sha}} = Tarball.pack(src, tar, :any)
    body = File.read!(tar)
    FakeBlobs.put(ctx.blobs, "/ncc/#{@slug}/#{key(1)}.tar.gz", body)

    offer(ctx, [
      %{
        "key" => key(1),
        "sha256" => sha,
        "size" => byte_size(body),
        "url" => ctx.blobs.url <> "/ncc/#{@slug}/#{key(1)}.tar.gz"
      }
    ])

    {dir, _} = BuildCache.prepare(ctx.req, claim(), ctx.config)
    entry = Path.join(dir, key(1))
    mode = fn path -> Bitwise.band(File.lstat!(path).mode, 0o7777) end
    {uid, 0} = System.cmd("id", ["-u"])
    uid = uid |> String.trim() |> String.to_integer()

    for path <- [
          Path.join(ctx.config.data_dir, "build-cache"),
          dir,
          entry,
          Path.join(entry, "ebin")
        ],
        do: assert(mode.(path) == 0o755, path)

    assert mode.(Path.join(entry, "ebin/Elixir.Dep.beam")) == 0o644
    assert mode.(Path.join(entry, "priv_bin/tool")) == 0o755

    for path <- [entry, Path.join(entry, "ebin/Elixir.Dep.beam")],
        do: assert(File.lstat!(path).uid == uid)
  end

  test "sends what it has and fetches only the rest", ctx do
    File.mkdir_p!(Path.join([ctx.slug_dir, key(1), "ebin"]))
    offer(ctx, [entry(ctx, key(1)), entry(ctx, key(2))])

    {dir, _line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
    assert BuildCache.entries(dir) == [key(1), key(2)]
    assert_received {:portal_request, "POST", _, %{"have" => [have]}, _}
    assert have == key(1)
    # The listed key that is already here is not fetched again.
    assert_received {:blob_get, "/ncc/" <> path2, _}
    assert path2 =~ key(2)
    refute_received {:blob_get, _, _}
  end

  test "a body whose SHA-256 is not the listed one is not published", ctx do
    offer(ctx, [entry(ctx, key(1), sha256: String.duplicate("f", 64))])

    capture_log(fn ->
      assert {nil, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
      assert line =~ "1 failed"
    end)

    assert BuildCache.entries(ctx.slug_dir) == []
    assert File.ls!(ctx.slug_dir) == []
  end

  test "a body longer than listed is cut off and refused", ctx do
    e = entry(ctx, key(1))
    offer(ctx, [%{e | "size" => e["size"] - 1}])

    capture_log(fn -> assert {nil, _} = BuildCache.prepare(ctx.req, claim(), ctx.config) end)
    assert File.ls!(ctx.slug_dir) == []
  end

  test "a tarball with a symlink member is refused, whatever its checksum", ctx do
    src = Path.join(ctx.dir, "evil")
    File.mkdir_p!(src)
    File.ln_s!("/etc/passwd", Path.join(src, "link"))
    tar = Path.join(ctx.dir, "evil.tar.gz")

    :ok =
      :erl_tar.create(
        String.to_charlist(tar),
        [{~c"link", String.to_charlist(Path.join(src, "link"))}],
        [:compressed]
      )

    body = File.read!(tar)
    sha = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    offer(ctx, [entry(ctx, key(1), body: body, sha256: sha)])

    capture_log(fn -> assert {nil, _} = BuildCache.prepare(ctx.req, claim(), ctx.config) end)
    assert File.ls!(ctx.slug_dir) == []
  end

  test "malformed entries are dropped before they name a path or a request", ctx do
    good = entry(ctx, key(1))

    offer(ctx, [
      %{good | "key" => "../../../etc"},
      %{good | "key" => String.upcase(key(0xABC))},
      %{good | "sha256" => "nope"},
      %{good | "size" => -1},
      %{good | "url" => "file:///etc/passwd"},
      "not a map"
    ])

    assert {nil, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
    assert line =~ "of 0 offered"
    refute_received {:blob_get, _, _}
  end

  test "an offer for another slug is ignored", ctx do
    offer(ctx, [entry(ctx, key(1))], "sha256_" <> String.duplicate("b", 64))
    assert {nil, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
    assert line =~ "another image"
    refute_received {:blob_get, _, _}
  end

  test "a portal without the endpoint builds with what is local", ctx do
    capture_log(fn ->
      assert {nil, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
      assert line =~ "no offer"
    end)

    File.mkdir_p!(Path.join([ctx.slug_dir, key(3)]))

    capture_log(fn ->
      assert {dir, _} = BuildCache.prepare(ctx.req, claim(), ctx.config)
      assert dir == ctx.slug_dir
    end)
  end

  test "an image digest that is not a full sha256 asks for nothing", ctx do
    assert {nil, _} = BuildCache.prepare(ctx.req, claim("latest"), ctx.config)
    assert {nil, _} = BuildCache.prepare(ctx.req, claim(nil), ctx.config)
    refute_received {:portal_request, _, _, _, _}
  end

  test "the byte budget skips what does not fit and low disk stops the loop", ctx do
    a = entry(ctx, key(1))
    b = entry(ctx, key(2))
    offer(ctx, [a, b])

    {_, line} = BuildCache.prepare(ctx.req, claim(), ctx.config, budget_bytes: a["size"])
    assert line =~ "1 downloaded" and line =~ "1 skipped"

    offer(ctx, [entry(ctx, key(5))])

    capture_log(fn ->
      {_, line} =
        BuildCache.prepare(ctx.req, claim(), ctx.config, free_bytes: fn _ -> 0 end)

      assert line =~ "0 downloaded" and line =~ "1 skipped"
    end)
  end

  test "a slug at its byte cap fetches nothing more; under it, it fills up to the cap", ctx do
    File.mkdir_p!(Path.join(ctx.slug_dir, key(9)))
    File.write!(Path.join([ctx.slug_dir, key(9), "big"]), :crypto.strong_rand_bytes(200_000))
    big = fn -> :crypto.strong_rand_bytes(100_000) end
    offer(ctx, [entry(ctx, key(1), content: big.()), entry(ctx, key(2), content: big.())])

    {dir, line} =
      BuildCache.prepare(ctx.req, claim(), %{ctx.config | build_cache_max_bytes: 100_000})

    # What is there is still mounted; nothing is added and nothing evicted.
    assert dir == ctx.slug_dir
    assert line =~ "0 downloaded" and line =~ "2 skipped"
    assert BuildCache.entries(dir) == [key(9)]
    refute_received {:blob_get, _, _}

    # Room for one more: the first fills the slug past its cap, the second waits.
    {_, line} =
      BuildCache.prepare(ctx.req, claim(), %{ctx.config | build_cache_max_bytes: 250_000})

    assert line =~ "1 downloaded" and line =~ "1 skipped"
    assert length(BuildCache.entries(ctx.slug_dir)) == 2
  end

  test "a store answering 5xx ends the loop for this build", ctx do
    e1 = entry(ctx, key(1))
    e2 = entry(ctx, key(2))
    FakeBlobs.put(ctx.blobs, "/ncc/#{@slug}/#{key(1)}.tar.gz", "", 503)
    offer(ctx, [e1, e2])

    capture_log(fn ->
      {_, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
      assert line =~ "1 failed" and line =~ "1 skipped"
    end)
  end

  test "a slug dir unused for a week is removed, the current one never", ctx do
    root = Path.join(ctx.config.data_dir, "build-cache")
    stale = Path.join(root, "sha256_" <> String.duplicate("c", 64))
    fresh = Path.join(root, "sha256_" <> String.duplicate("d", 64))
    other = Path.join(root, "not-a-slug")
    for d <- [stale, fresh, other], do: File.mkdir_p!(d)
    old = System.os_time(:second) - 8 * 86_400
    File.touch!(stale, old)
    File.touch!(other, old)

    capture_log(fn -> BuildCache.prepare(ctx.req, claim(), ctx.config) end)

    refute File.exists?(stale)
    assert File.exists?(fresh)
    assert File.exists?(other)
    assert File.exists?(ctx.slug_dir)
  end

  # Another slot's lock on a slug, held by a process of its own until told.
  defp hold_lock(slug) do
    me = self()

    pid =
      spawn(fn ->
        true = :global.set_lock({{BuildCache, slug}, self()}, [node()], 0)
        send(me, :locked)

        receive do
          :release -> :ok
        end
      end)

    assert_receive :locked
    pid
  end

  defp release(pid) do
    ref = Process.monitor(pid)
    send(pid, :release)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}
  end

  test "a stale slug another slot holds the lock on is never pruned", ctx do
    root = Path.join(ctx.config.data_dir, "build-cache")
    other_slug = "sha256_" <> String.duplicate("c", 64)
    other = Path.join(root, other_slug)
    File.mkdir_p!(Path.join(other, key(1)))
    File.touch!(other, System.os_time(:second) - 8 * 86_400)

    # Slot B is filling (and about to mount) `other` while slot A prepares.
    holder = hold_lock(other_slug)
    capture_log(fn -> BuildCache.prepare(ctx.req, claim(), ctx.config) end)
    assert File.exists?(Path.join(other, key(1)))

    # Once B is done, and the slug still unused for a week, it goes.
    release(holder)
    capture_log(fn -> BuildCache.prepare(ctx.req, claim(), ctx.config) end)
    refute File.exists?(other)
    assert File.ls!(root) == [@slug]
  end

  test "a slot that finds its slug locked still marks it in use before anything else", ctx do
    File.mkdir_p!(Path.join(ctx.slug_dir, key(1)))
    File.touch!(ctx.slug_dir, System.os_time(:second) - 8 * 86_400)
    holder = hold_lock(@slug)

    {dir, line} = BuildCache.prepare(ctx.req, claim(), ctx.config)
    release(holder)

    assert line =~ "another slot"
    assert dir == ctx.slug_dir
    {:ok, %File.Stat{mtime: mtime}} = File.stat(ctx.slug_dir, time: :posix)
    assert mtime > System.os_time(:second) - 60
  end

  test "show cuts a query string out of anything it logs" do
    assert BuildCache.show({:error, "http://h/b/k.tar.gz?X-Amz-Signature=abc"}) =~
             "?<query removed>"

    refute BuildCache.show("http://h/b?X-Amz-Credential=x") =~ "X-Amz"
  end
end
