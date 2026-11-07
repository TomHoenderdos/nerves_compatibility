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
    put(dir, "ebin/b.beam", "B")
    put(dir, "ebin/a.beam", "")

    expected =
      [{"ebin/a.beam", ""}, {"ebin/b.beam", "B"}, {"priv/z", "ZZ"}]
      |> Enum.map(fn {rel, body} ->
        <<byte_size(rel)::32, rel::binary, byte_size(body)::64, body::binary>>
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
      assert {:error, _} = :ncc_tracer_digest.dir(dir)
    end
  end
end
