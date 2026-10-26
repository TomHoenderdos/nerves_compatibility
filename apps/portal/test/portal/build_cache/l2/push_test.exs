defmodule Portal.BuildCache.L2.PushTest do
  use ExUnit.Case, async: false

  alias Portal.BuildCache.L2.{Push, Stats}
  alias Portal.Test.FakeS3

  setup do
    {:ok, s} = FakeS3.start()
    root = Path.join(System.tmp_dir!(), "push-#{System.unique_integer([:positive])}")

    for slug <- ["sha256_a", "sha256_b"], n <- 1..2 do
      key = String.pad_leading(String.replace("#{slug}#{n}", ~r/[^a-f0-9]/, ""), 64, "0")
      dir = Path.join([root, slug, key, "ebin"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "x.beam"), String.duplicate("b", n * 100))
    end

    File.mkdir_p!(
      Path.join(root, "sha256_a/" <> String.duplicate("c", 64) <> ".tmp.box.0123456789abcdef")
    )

    File.write!(Path.join(root, "sha256_a/stray"), "x")
    on_exit(fn -> File.rm_rf(root) end)
    Stats.reset()
    %{s: s, cfg: s.config, root: root}
  end

  test "uploads every entry once and skips what is present on a second run", %{
    s: s,
    cfg: cfg,
    root: root
  } do
    {:ok, io} = StringIO.open("")

    assert {:ok, %{uploaded: 4, present: 0, failed: 0}} =
             Push.run(root: root, config: cfg, io: io)

    assert length(FakeS3.objects(s)) == 4
    assert {:ok, %{uploaded: 0, present: 4}} = Push.run(root: root, config: cfg, io: io)
    {_, out} = StringIO.contents(io)
    assert out =~ "present"
  end

  test "dry run uploads nothing", %{s: s, cfg: cfg, root: root} do
    {:ok, io} = StringIO.open("")

    assert {:ok, %{skipped: 4, uploaded: 0}} =
             Push.run(root: root, config: cfg, dry_run: true, io: io)

    assert FakeS3.objects(s) == []
  end

  test "limit, max_bytes and slug bound it", %{s: s, cfg: cfg, root: root} do
    {:ok, io} = StringIO.open("")
    assert {:ok, %{uploaded: 1, skipped: 3}} = Push.run(root: root, config: cfg, limit: 1, io: io)
    assert length(FakeS3.objects(s)) == 1

    assert {:ok, %{uploaded: 1, skipped: 1}} =
             Push.run(root: root, config: cfg, slug: "sha256_b", max_bytes: 1, io: io)

    assert length(FakeS3.objects(s)) == 2
  end

  test "refuses read-only and off", %{cfg: cfg, root: root} do
    assert {:error, msg} = Push.run(root: root, config: %{cfg | read_only?: true})
    assert msg =~ "read-only"
    assert {:error, _} = Push.run(root: root, config: nil)
  end
end
