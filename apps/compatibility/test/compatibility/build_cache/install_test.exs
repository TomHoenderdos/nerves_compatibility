defmodule Compatibility.BuildCache.InstallTest do
  use ExUnit.Case, async: true

  alias Compatibility.BuildCache.{Install, Tarball}

  setup do
    tmp = Path.join(System.tmp_dir!(), "install-#{System.unique_integer([:positive])}")
    entry = Path.join(tmp, "entry")
    File.mkdir_p!(Path.join(entry, "ebin"))
    File.write!(Path.join(entry, "ebin/Elixir.Jason.beam"), "beam")
    File.ln_s!("../../../../deps/jason/priv", Path.join(entry, "priv"))
    slug = Path.join(tmp, "slug")
    File.mkdir_p!(slug)
    tar = Path.join(tmp, "e.tar.gz")
    {:ok, %{sha256: sha}} = Tarball.pack(entry, tar, "jason")
    on_exit(fn -> File.rm_rf(tmp) end)

    %{
      tmp: tmp,
      tar: tar,
      sha: sha,
      dest: Path.join(slug, String.duplicate("a", 64)),
      staging: Path.join(slug, "staging")
    }
  end

  test "verify_sha compares case-insensitively and refuses a missing value", %{sha: sha} do
    assert :ok = Install.verify_sha(sha, String.upcase(sha))
    assert {:error, :no_sha256_header} = Install.verify_sha(sha, nil)
    assert {:error, {:sha256_mismatch, ^sha, "x"}} = Install.verify_sha(sha, "x")
  end

  test "extracts, recreates Mix's link and publishes by rename", ctx do
    assert {:ok, extracted} = Install.install(ctx.tar, ctx.staging, ctx.dest)
    assert extracted > 0
    assert File.read!(Path.join(ctx.dest, "ebin/Elixir.Jason.beam")) == "beam"
    assert {:ok, "../../../../deps/jason/priv"} = File.read_link(Path.join(ctx.dest, "priv"))
    refute File.exists?(ctx.staging)
    refute File.exists?(ctx.tar)
  end

  test "an entry that exists by then wins", ctx do
    File.mkdir_p!(Path.join(ctx.dest, "ebin"))
    File.write!(Path.join(ctx.dest, "ebin/local.beam"), "local")

    assert {:discarded, _} = Install.install(ctx.tar, ctx.staging, ctx.dest)
    assert File.ls!(Path.join(ctx.dest, "ebin")) == ["local.beam"]
  end

  test "before_publish runs on the staging tree and can refuse it", ctx do
    me = self()

    assert {:error, :nope} =
             Install.install(ctx.tar, ctx.staging, ctx.dest,
               before_publish: fn staging ->
                 send(me, {:staging, staging})
                 {:error, :nope}
               end
             )

    assert_received {:staging, staging}
    assert staging == ctx.staging
    refute File.exists?(ctx.dest)
  end

  test "a tarball that is not one publishes nothing", ctx do
    File.write!(ctx.tar, "not gzip")
    assert {:error, {:gzip, _}} = Install.install(ctx.tar, ctx.staging, ctx.dest)
    refute File.exists?(ctx.dest)
  end
end
