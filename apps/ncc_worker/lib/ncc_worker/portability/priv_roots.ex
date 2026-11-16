defmodule NccWorker.Portability.PrivRoots do
  @moduledoc """
  Spec R2 for the package's own build `priv` (judge revision 21): the files
  the package's own compile wrote there (`NccWorker.Portability.PrivRepro`)
  must not hold any of the roots R2 searches beams for
  (`NccWorker.Portability.Context.roots/1`: the project dir, so every
  closure source path and the build path under it, the OTP root, the
  Elixir install, `HOME`, `MIX_HOME` and `HEX_HOME`).

  The second build varies the build path and the time, nothing else: it
  compiles the same `deps/` with the same OTP, Elixir and homes, so a file
  that holds the source path of the module being compiled (`env.file` in a
  `__before_compile__/1` hook, which is in no beam and no read) or the OTP
  install is the same in both builds, and no user's own compile writes it.
  Such a file refuses as `"bakes the build path: priv/<path>"`.

  Every regular file under `priv` is searched as it is, and a file that
  starts with the gzip magic (an `:erl_tar` `:compressed` archive, a
  `:zlib.gzip/1` file) is searched inflated as well, every member, at most
  64 MiB out. A file that starts so but does not inflate, a link or any
  other file type, more than 2,000 entries or 64 MiB of files is an error,
  which the judge makes could-not-judge. Not searched: a root split across
  parts, or packed in any other compression, or in a gzip inside one
  (R2's own limits for beams are alike: a root split across terms is not
  found). Never raises.
  """

  @max_entries 2_000
  @max_bytes 64 * 1024 * 1024
  @max_inflated 64 * 1024 * 1024

  @doc """
  `:ok` when no file under `dir` holds one of `roots`, `{:refuse, reason}`
  naming the first one (sorted) that does, `{:error, why}` when that cannot
  be told (see the moduledoc). No `dir` at all is `:ok`; no roots is an
  error.
  """
  @spec check(term(), term()) :: :ok | {:refuse, String.t()} | {:error, String.t()}
  def check(dir, roots) when is_binary(dir) and is_list(roots) and roots != [] do
    if Enum.all?(roots, &(is_binary(&1) and &1 != "")),
      do: dir |> files() |> search(:binary.compile_pattern(roots)),
      else: {:error, "priv roots are malformed"}
  rescue
    e -> {:error, "priv roots: " <> Exception.message(e)}
  end

  def check(_dir, _roots), do: {:error, "no priv dir or roots to search"}

  defp search({:ok, files}, pattern) do
    Enum.find_value(files, :ok, fn {rel, bytes} ->
      case holds?(bytes, pattern) do
        false -> nil
        true -> {:refuse, "bakes the build path: priv/#{rel}"}
        {:error, why} -> {:error, "priv/#{rel}: #{why}"}
      end
    end)
  end

  defp search({:error, _why} = error, _pattern), do: error

  defp holds?(<<0x1F, 0x8B, _::binary>> = bytes, pattern) do
    if :binary.match(bytes, pattern) != :nomatch do
      true
    else
      case gunzip(bytes) do
        {:ok, inflated} -> :binary.match(inflated, pattern) != :nomatch
        {:error, _why} = error -> error
      end
    end
  end

  defp holds?(bytes, pattern), do: :binary.match(bytes, pattern) != :nomatch

  # Every gzip member (`reset` at each member's end), at most @max_inflated
  # bytes out.
  defp gunzip(bytes) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, 31, :reset)
      inflate_loop(z, :zlib.safeInflate(z, bytes), [], 0)
    rescue
      _ -> {:error, "does not inflate"}
    catch
      _, _ -> {:error, "does not inflate"}
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, out}, acc, size) when state in [:continue, :finished] do
    size = size + IO.iodata_length(out)
    acc = [acc | out]

    cond do
      size > @max_inflated -> {:error, "inflates to over #{@max_inflated} bytes"}
      state == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), acc, size)
    end
  end

  defp inflate_loop(_z, _other, _acc, _size), do: {:error, "does not inflate"}

  # `[{rel, bytes}]`, sorted, of every regular file under `dir`, read with
  # `lstat`. Bounded in entries and bytes.
  # sobelow_skip ["Traversal.FileModule"]
  defp files(dir) do
    case File.lstat(dir) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk(dir, "", {:ok, [], 0, 0}) do
          {:ok, files, _entries, _bytes} -> {:ok, Enum.sort(files)}
          error -> error
        end

      {:error, :enoent} ->
        {:ok, []}

      {:ok, _other} ->
        {:error, "priv is not a directory"}

      {:error, why} ->
        {:error, "priv: #{inspect(why)}"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp walk(root, rel, acc) do
    case File.ls(Path.join(root, rel)) do
      {:ok, names} ->
        names |> Enum.sort() |> Enum.reduce_while(acc, &entry(root, join(rel, &1), &2))

      {:error, why} ->
        {:error, "priv/#{rel}: #{inspect(why)}"}
    end
  end

  defp entry(_root, _rel, {:ok, _files, entries, _bytes}) when entries >= @max_entries,
    do: {:halt, {:error, "priv has over #{@max_entries} entries"}}

  # sobelow_skip ["Traversal.FileModule"]
  defp entry(root, rel, {:ok, files, entries, bytes}) do
    path = Path.join(root, rel)

    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} ->
        case walk(root, rel, {:ok, files, entries + 1, bytes}) do
          {:ok, _, _, _} = acc -> {:cont, acc}
          error -> {:halt, error}
        end

      {:ok, %File.Stat{type: :regular, size: size}} when bytes + size <= @max_bytes ->
        read(path, rel, size, {files, entries, bytes})

      {:ok, %File.Stat{type: :regular}} ->
        {:halt, {:error, "priv holds over #{@max_bytes} bytes"}}

      {:ok, %File.Stat{type: type}} ->
        {:halt, {:error, "priv/#{rel} is a #{type}"}}

      {:error, why} ->
        {:halt, {:error, "priv/#{rel}: #{inspect(why)}"}}
    end
  end

  # No more than the size `lstat` gave: a file that grew since is not the
  # file that was walked.
  # sobelow_skip ["Traversal.FileModule"]
  defp read(path, rel, size, {files, entries, bytes}) do
    case File.open(path, [:read, :raw, :binary], &IO.binread(&1, size + 1)) do
      {:ok, data} when is_binary(data) and byte_size(data) == size ->
        {:cont, {:ok, [{rel, data} | files], entries + 1, bytes + size}}

      {:ok, :eof} when size == 0 ->
        {:cont, {:ok, [{rel, ""} | files], entries + 1, bytes}}

      _ ->
        {:halt, {:error, "priv/#{rel} could not be read"}}
    end
  end

  defp join("", name), do: name
  defp join(rel, name), do: rel <> "/" <> name
end
