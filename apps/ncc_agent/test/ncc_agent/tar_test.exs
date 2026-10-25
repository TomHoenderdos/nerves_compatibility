defmodule NccAgent.TarTest do
  use ExUnit.Case, async: true

  alias NccAgent.Tar

  setup do
    dir = Path.join(System.tmp_dir!(), "agent-tar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  defp file(dir, name, size) do
    path = Path.join(dir, name)
    File.write!(path, :binary.copy("x", size))
    {name, path}
  end

  test "batches/2 packs greedily by tar size and gives an oversized file its own batch", %{
    dir: dir
  } do
    # Each 400-byte file takes 1024 bytes in a tar (header + padded
    # content), and every tar ends with 1024 bytes: two fit in 3072.
    a = file(dir, "a", 400)
    b = file(dir, "b", 400)
    c = file(dir, "c", 400)
    assert [[^a, ^b], [^c]] = Tar.batches([a, b, c], 3072)
    assert [[^a], [^b], [^c]] = Tar.batches([a, b, c], 3071)

    big = file(dir, "big", 5000)
    assert [[^a], [^big], [^b]] = Tar.batches([a, big, b], 3072)
    assert [] = Tar.batches([], 1000)
  end

  test "a written batch never exceeds the cap on disk", %{dir: dir} do
    files = for i <- 1..7, do: file(dir, "f#{i}", i * 333)
    cap = 4096

    for {batch, i} <- Enum.with_index(Tar.batches(files, cap)) do
      out = Path.join(dir, "b#{i}.tar")
      :ok = Tar.write(batch, out)
      size = File.stat!(out).size
      assert size == Tar.tar_bytes(Enum.map(batch, fn {_, p} -> File.stat!(p).size end))
      assert size <= cap or length(batch) == 1
    end
  end

  test "write/2 writes a tar of the files under their sha names", %{dir: dir} do
    sha1 = String.duplicate("a", 64)
    sha2 = String.duplicate("b", 64)
    {_, p1} = file(dir, "one", 10)
    {_, p2} = file(dir, "two", 20)
    out = Path.join(dir, "batch.tar")

    assert :ok = Tar.write([{sha1, p1}, {sha2, p2}], out)
    assert {:ok, names} = :erl_tar.table(String.to_charlist(out))
    assert Enum.map(names, &to_string/1) == [sha1, sha2]
  end
end
