defmodule Portal.BuildCache.L2.RemoteTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Compatibility.BuildCache.Tarball
  alias Portal.BuildCache.L2.{Config, Remote}
  alias Portal.Test.FakeS3

  @slug "sha256_" <> String.duplicate("ab", 32)

  setup do
    {:ok, s3} = FakeS3.start()
    tmp = Path.join(System.tmp_dir!(), "remote-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{s3: s3, tmp: tmp}
  end

  defp key(n), do: n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(64, "0")

  # A real entry tarball, stored the way `Portal.BuildCache.L2.upload/5` stores it.
  defp put_entry(s3, tmp, key, opts \\ []) do
    entry = Path.join(tmp, "entry-" <> key)
    File.mkdir_p!(Path.join(entry, "ebin"))
    File.write!(Path.join(entry, "ebin/x.beam"), Keyword.get(opts, :content, key))
    tar = Path.join(tmp, key <> ".tar.gz")
    {:ok, %{sha256: sha}} = Tarball.pack(entry, tar, :any)
    body = File.read!(tar)
    meta = Keyword.get(opts, :meta, %{"x-amz-meta-sha256" => sha})
    last = Keyword.get(opts, :last_modified, DateTime.utc_now())
    FakeS3.put_object(s3, "#{@slug}/#{key}.tar.gz", body, meta, last_modified: last)
    %{sha: sha, size: byte_size(body), body: body}
  end

  test "offers every entry the builder lacks, newest first, with a working presigned GET", ctx do
    old = put_entry(ctx.s3, ctx.tmp, key(1), last_modified: ~U[2026-01-01 00:00:00Z])
    new = put_entry(ctx.s3, ctx.tmp, key(2), last_modified: ~U[2026-02-01 00:00:00Z])
    _have = put_entry(ctx.s3, ctx.tmp, key(3))

    now = DateTime.utc_now()
    offer = Remote.offer(@slug, [key(3)], config: ctx.s3.config, now: now)

    assert [first, second] = offer.entries
    assert first["key"] == key(2) and first["sha256"] == new.sha and first["size"] == new.size
    assert second["key"] == key(1) and second["sha256"] == old.sha
    assert DateTime.diff(offer.expires_at, now) == Remote.ttl_seconds()
    assert Remote.ttl_seconds() <= 900

    # The URL is a plain GET, no credentials needed beyond what it carries.
    assert {:ok, %Req.Response{status: 200, body: body}} =
             Req.get(first["url"], retry: false, decode_body: false)

    assert body == new.body

    # It names its own object and nothing else: the signature covers the path.
    other = String.replace(first["url"], key(2), key(1))
    assert {:ok, %Req.Response{status: 403}} = Req.get(other, retry: false)

    # Nor any other method.
    assert {:ok, %Req.Response{status: 403}} = Req.put(first["url"], body: "x", retry: false)
    assert {:ok, %{body: ^body}} = FakeS3.get_object(ctx.s3, "#{@slug}/#{key(2)}.tar.gz")
  end

  test "the URL carries no secret key", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1))
    [entry] = Remote.offer(@slug, [], config: ctx.s3.config).entries
    refute entry["url"] =~ ctx.s3.secret_key
    assert entry["url"] =~ "X-Amz-Expires=#{Remote.ttl_seconds()}"
  end

  test "an expired URL is refused by the store", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1))
    past = DateTime.add(DateTime.utc_now(), -3600)
    [entry] = Remote.offer(@slug, [], config: ctx.s3.config, now: past).entries
    assert {:ok, %Req.Response{status: 403}} = Req.get(entry["url"], retry: false)
  end

  test "an unshareable slug, no config or a failing listing offers nothing", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1))

    assert Remote.offer("unknown", [], config: ctx.s3.config).entries == []

    assert Remote.offer("sha256_" <> String.duplicate("0", 64), [], config: ctx.s3.config).entries ==
             []

    assert Remote.offer(@slug, [], config: nil).entries == []

    FakeS3.set_fault(ctx.s3, {:list, :status, 500})

    log =
      capture_log(fn ->
        assert Remote.offer(@slug, [], config: ctx.s3.config).entries == []
      end)

    assert log =~ "listing"
  end

  test "keys that are not the portal's own names are never offered", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1))

    FakeS3.put_object(ctx.s3, "#{@slug}/../../etc/passwd.tar.gz", "x", %{
      "x-amz-meta-sha256" => key(9)
    })

    FakeS3.put_object(ctx.s3, "#{@slug}/#{String.upcase(key(5))}.tar.gz", "x", %{})
    FakeS3.put_object(ctx.s3, "#{@slug}/#{key(6)}.tar", "x", %{})

    assert [%{"key" => k}] = Remote.offer(@slug, [], config: ctx.s3.config).entries
    assert k == key(1)
  end

  test "an object without a well-formed sha256, or whose size changed, is dropped", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1), meta: %{})
    put_entry(ctx.s3, ctx.tmp, key(2), meta: %{"x-amz-meta-sha256" => "not-hex"})
    put_entry(ctx.s3, ctx.tmp, key(3))

    assert [%{"key" => k}] = Remote.offer(@slug, [], config: ctx.s3.config).entries
    assert k == key(3)
  end

  test "the offer stays within the byte and count budgets", ctx do
    a = put_entry(ctx.s3, ctx.tmp, key(1), last_modified: ~U[2026-03-01 00:00:00Z])

    _b =
      put_entry(ctx.s3, ctx.tmp, key(2),
        content: :crypto.strong_rand_bytes(100_000),
        last_modified: ~U[2026-02-01 00:00:00Z]
      )

    c = put_entry(ctx.s3, ctx.tmp, key(3), last_modified: ~U[2026-01-01 00:00:00Z])

    # The large second does not fit beside the first; the small third behind it does.
    keys =
      Remote.offer(@slug, [], config: ctx.s3.config, budget_bytes: a.size + c.size).entries
      |> Enum.map(& &1["key"])

    assert keys == [key(1), key(3)]

    assert [_] = Remote.offer(@slug, [], config: ctx.s3.config, max_entries: 1).entries
    assert Remote.offer(@slug, [], config: ctx.s3.config, max_object_bytes: 1).entries == []
  end

  test "a read-only config presigns as well", ctx do
    put_entry(ctx.s3, ctx.tmp, key(1))
    %Config{} = cfg = ctx.s3.config
    cfg = %{cfg | read_only?: true}
    assert [entry] = Remote.offer(@slug, [], config: cfg).entries
    assert {:ok, %Req.Response{status: 200}} = Req.get(entry["url"], retry: false)
  end
end
