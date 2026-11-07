defmodule NccWorker.Tracer.DigestTest do
  use ExUnit.Case, async: true

  @moduletag :tmp_dir

  defp put(dir, rel, body) do
    path = Path.join(dir, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
  end

  test "covers ebin and priv by path and content, nothing else", %{tmp_dir: dir} do
    put(dir, "ebin/a.beam", "A")
    put(dir, "priv/static/app.js", "JS")
    put(dir, ".mix/compile.elixir", "manifest")
    assert {:ok, digest, 2} = :ncc_tracer_digest.dir(dir)
    assert byte_size(digest) == 64

    put(dir, ".mix/compile.elixir", "changed")
    assert {:ok, ^digest, 2} = :ncc_tracer_digest.dir(dir)

    put(dir, "ebin/a.beam", "B")
    assert {:ok, other, 2} = :ncc_tracer_digest.dir(dir)
    refute other == digest
  end

  test "a renamed file changes it; a priv symlink is followed", %{tmp_dir: dir} do
    build = Path.join(dir, "build")
    put(build, "ebin/a.beam", "A")
    {:ok, before, 1} = :ncc_tracer_digest.dir(build)
    File.rename!(Path.join(build, "ebin/a.beam"), Path.join(build, "ebin/b.beam"))
    refute match?({:ok, ^before, 1}, :ncc_tracer_digest.dir(build))

    put(dir, "src_priv/x.txt", "X")
    File.ln_s!(Path.join(dir, "src_priv"), Path.join(build, "priv"))
    assert {:ok, _, 2} = :ncc_tracer_digest.dir(build)
  end

  test "a missing dir is empty, not an error", %{tmp_dir: dir} do
    assert {:ok, _, 0} = :ncc_tracer_digest.dir(Path.join(dir, "none"))
  end

  test "it is the sha256 of every entry in path order", %{tmp_dir: dir} do
    put(dir, "priv/z", "ZZ")
    File.chmod!(Path.join(dir, "priv/z"), 0o744)
    put(dir, "ebin/b.beam", "B")
    put(dir, "ebin/a.beam", "")

    expected =
      [{"ebin/a.beam", "", 0}, {"ebin/b.beam", "B", 0}, {"priv/z", "ZZ", 1}]
      |> Enum.map(fn {rel, body, exec} ->
        <<byte_size(rel)::32, rel::binary, exec::8, byte_size(body)::64, body::binary>>
      end)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    assert {:ok, ^expected, 3} = :ncc_tracer_digest.dir(dir)
  end

  test "a file read in chunks digests as one read whole", %{tmp_dir: dir} do
    put(dir, "ebin/big.beam", :binary.copy("x", 3 * 1024 * 1024 + 7))
    assert {:ok, whole, 1} = :ncc_tracer_digest.dir(dir)
    assert {:ok, ^whole, 1} = :ncc_tracer_digest.dir(dir, %{chunk_bytes: 4096})
  end

  test "a dotfile is covered", %{tmp_dir: dir} do
    put(dir, "ebin/a.beam", "A")
    {:ok, before, 1} = :ncc_tracer_digest.dir(dir)
    put(dir, "priv/.hidden", "H")
    assert {:ok, other, 2} = :ncc_tracer_digest.dir(dir)
    refute other == before
  end

  test "a changed exec bit changes it", %{tmp_dir: dir} do
    put(dir, "priv/run", "R")
    {:ok, before, 1} = :ncc_tracer_digest.dir(dir)
    File.chmod!(Path.join(dir, "priv/run"), 0o755)
    assert {:ok, other, 1} = :ncc_tracer_digest.dir(dir)
    refute other == before
  end

  test "a file that changes size while it is read is an error", %{tmp_dir: dir} do
    put(dir, "ebin/a.beam", "A")
    grow = fn path -> File.write!(path, "more", [:append]) end
    assert {:error, :changed} = :ncc_tracer_digest.dir(dir, %{before_read: grow})

    put(dir, "ebin/a.beam", "AAAA")
    shrink = fn path -> File.write!(path, "A") end
    assert {:error, :changed} = :ncc_tracer_digest.dir(dir, %{before_read: shrink})
  end

  describe "symlinks below ebin and priv" do
    test "one that resolves inside its tree is followed", %{tmp_dir: dir} do
      put(dir, "priv/real/x", "X")
      File.ln_s!("real", Path.join(dir, "priv/alias"))
      File.ln_s!("real/x", Path.join(dir, "priv/x_link"))
      assert {:ok, _, 3} = :ncc_tracer_digest.dir(dir)
    end

    test "a file one that resolves outside its tree is an error", %{tmp_dir: dir} do
      build = Path.join(dir, "build")
      put(build, "ebin/a.beam", "A")
      put(dir, "elsewhere/secret", "S")
      File.ln_s!(Path.join(dir, "elsewhere/secret"), Path.join(build, "ebin/s"))
      assert {:error, :outside_tree} = :ncc_tracer_digest.dir(build)
    end

    test "a directory one that resolves outside its tree is an error", %{tmp_dir: dir} do
      build = Path.join(dir, "build")
      put(build, "priv/a", "A")
      put(dir, "elsewhere/secret", "S")
      File.ln_s!("../../elsewhere", Path.join(build, "priv/up"))
      assert {:error, :outside_tree} = :ncc_tracer_digest.dir(build)
    end

    test "one from priv into ebin is outside priv's tree", %{tmp_dir: dir} do
      put(dir, "ebin/a.beam", "A")
      File.mkdir_p!(Path.join(dir, "priv"))
      File.ln_s!("../ebin/a.beam", Path.join(dir, "priv/a"))
      assert {:error, :outside_tree} = :ncc_tracer_digest.dir(dir)
    end
  end

  test "the tracer records an unavailable digest module as an error", %{tmp_dir: dir} do
    assert %{digest: :null, error: "digest_unavailable"} =
             :ncc_tracer.built_fields(:ncc_tracer_no_such_module, dir)

    put(dir, "ebin/a.beam", "A")
    {:ok, digest, 1} = :ncc_tracer_digest.dir(dir)
    assert %{digest: ^digest, files: 1} = :ncc_tracer.built_fields(:ncc_tracer_digest, dir)
  end

  describe "bounds" do
    test "more files than the cap is an error, found before any file is read", %{tmp_dir: dir} do
      for i <- 1..3, do: put(dir, "ebin/m#{i}.beam", "M")
      assert {:ok, _, 3} = :ncc_tracer_digest.dir(dir, %{max_files: 3})
      assert {:error, :too_many_files} = :ncc_tracer_digest.dir(dir, %{max_files: 2})
    end

    test "more bytes than the cap is an error", %{tmp_dir: dir} do
      put(dir, "ebin/a.beam", "12345")
      put(dir, "priv/b", "678")
      assert {:ok, _, 2} = :ncc_tracer_digest.dir(dir, %{max_bytes: 8})
      assert {:error, :too_large} = :ncc_tracer_digest.dir(dir, %{max_bytes: 7})
    end

    test "a digest past its deadline is an error", %{tmp_dir: dir} do
      put(dir, "ebin/a.beam", "A")
      assert {:error, :timeout} = :ncc_tracer_digest.dir(dir, %{timeout_ms: 0})
    end

    test "a symlink loop under priv ends in an error, not a hang", %{tmp_dir: dir} do
      put(dir, "priv/x", "X")
      File.ln_s!(Path.join(dir, "priv"), Path.join(dir, "priv/loop"))
      assert {:error, :too_deep} = :ncc_tracer_digest.dir(dir)
    end

    test "a directory with more entries than the file cap is an error", %{tmp_dir: dir} do
      for i <- 1..3, do: File.mkdir_p!(Path.join(dir, "priv/d#{i}"))
      assert {:error, :too_many_files} = :ncc_tracer_digest.dir(dir, %{max_files: 2})
    end
  end
end
