defmodule Portal.Builders.TarStreamTest do
  use ExUnit.Case, async: true

  alias Portal.Builders.TarStream

  defp tar(entries) do
    dir = Path.join(System.tmp_dir!(), "tar-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    files =
      for {name, bytes} <- entries do
        path = Path.join(dir, name)
        File.write!(path, bytes)
        {String.to_charlist(name), String.to_charlist(path)}
      end

    out = Path.join(dir, "out.tar")
    :ok = :erl_tar.create(String.to_charlist(out), files)
    bin = File.read!(out)
    File.rm_rf!(dir)
    bin
  end

  defp collect(bin, chunk) do
    callbacks = %{
      start: fn name, size -> {:ok, {name, size, []}} end,
      data: fn {name, size, acc}, data -> {name, size, [data | acc]} end,
      finish: fn {name, size, acc} ->
        {name, size, acc |> Enum.reverse() |> IO.iodata_to_binary()}
      end
    }

    bin
    |> :binary.bin_to_list()
    |> Enum.chunk_every(chunk)
    |> Enum.map(&:binary.list_to_bin/1)
    |> Enum.reduce_while({:ok, TarStream.new(callbacks)}, fn piece, {:ok, state} ->
      case TarStream.feed(state, piece) do
        {:ok, state} -> {:cont, {:ok, state}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, state} -> TarStream.finish(state)
      error -> error
    end
  end

  test "reads erl_tar output entry by entry whatever the chunking" do
    bin = tar([{"aa", "hello"}, {"bb", String.duplicate("x", 1000)}, {"cc", ""}])

    for chunk <- [1, 7, 512, 513, 4096, byte_size(bin)] do
      assert {:ok, [{"aa", 5, "hello"}, {"bb", 1000, _}, {"cc", 0, ""}]} = collect(bin, chunk)
    end
  end

  test "a skipped entry's bytes are not delivered" do
    bin = tar([{"skip", "zzz"}, {"keep", "k"}])

    callbacks = %{
      start: fn
        "skip", _ -> {:skip, :nope}
        name, size -> {:ok, {name, size}}
      end,
      data: fn acc, _ -> acc end,
      finish: fn acc -> acc end
    }

    state = TarStream.new(callbacks)
    {:ok, state} = TarStream.feed(state, bin)
    assert {:ok, [{:skipped, "skip", :nope}, {"keep", 1}]} = TarStream.finish(state)
  end

  test "symlinks, directories and long names are refused" do
    dir = Path.join(System.tmp_dir!(), "tar-link-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "target"), "t")
    File.ln_s!("target", Path.join(dir, "link"))
    out = Path.join(dir, "out.tar")

    :ok =
      :erl_tar.create(
        String.to_charlist(out),
        [{~c"link", String.to_charlist(Path.join(dir, "link"))}],
        []
      )

    bin = File.read!(out)
    File.rm_rf!(dir)
    assert {:error, {:unsupported_entry, "link"}} = collect(bin, 512)

    long = tar([{String.duplicate("n", 120), "x"}])
    assert {:error, {:unsupported_entry, _}} = collect(long, 512)
  end

  test "a truncated archive is reported" do
    bin = tar([{"aa", String.duplicate("y", 2000)}])
    assert {:error, :truncated} = collect(binary_part(bin, 0, 1024), 512)
  end
end
