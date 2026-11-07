defmodule Portal.Builders.ResultJson do
  @moduledoc """
  The one bounded reader for a `result.json`, shared by the local build
  path (`Portal.Builder.read_result_json/1`) and the remote upload path
  (`Portal.Builders.Upload.write_outputs/2`). Both read a file written by
  the worker container running untrusted package code, so neither trusts
  its size or its shape:

    * the size is checked twice — once by `stat`, once by how many bytes
      are actually read (`max_bytes + 1`, so a file that grows between the
      two can't slip extra bytes past the cap)
    * the decoded JSON is walked breadth-first, over an explicit work list
      rather than by recursing on the caller's own stack, and refused if it
      nests past `max_depth`

  Either refusal reaches its caller the same way a missing or unparsable
  file does: there is no result, never a reason why.
  """

  # Matches `Portal.Builders.Upload.caps/0`'s `max_result_bytes` default, so
  # the local path enforces the same cap unless told otherwise.
  @max_bytes 8_388_608
  @max_depth 64

  @type error :: :unreadable | :too_large | :unparsable | :too_deep

  @spec max_bytes() :: pos_integer()
  def max_bytes, do: @max_bytes

  @spec max_depth() :: pos_integer()
  def max_depth, do: @max_depth

  @doc """
  Read and decode the result.json at `path`. `{:ok, bytes, decoded}` on
  success; `{:error, :unreadable | :too_large | :unparsable | :too_deep}`
  otherwise. `path` is refused, not followed, when it is a symlink.
  """
  @spec read(Path.t(), pos_integer(), pos_integer()) ::
          {:ok, binary(), term()} | {:error, error()}
  # path is built by each caller from a configured root and a validated id.
  # sobelow_skip ["Traversal.FileModule"]
  def read(path, max_bytes \\ @max_bytes, max_depth \\ @max_depth) do
    with {:ok, size} <- stat_size(path),
         :ok <- within_bytes(size, max_bytes),
         {:ok, bytes} <- read_capped(path, max_bytes),
         {:ok, decoded} <- decode(bytes),
         :ok <- within_depth(decoded, max_depth) do
      {:ok, bytes, decoded}
    end
  end

  defp stat_size(path) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :regular, size: size}} -> {:ok, size}
      _ -> {:error, :unreadable}
    end
  end

  defp within_bytes(size, max) when size <= max, do: :ok
  defp within_bytes(_size, _max), do: {:error, :too_large}

  # Opened and read fresh rather than trusting the stat above: this is the
  # read that actually bounds what lands in memory, regardless of how the
  # file changes between the two. Reading one byte past `max` turns "it grew"
  # into a clean refusal instead of a silently truncated decode.
  # `path` is the same caller-built path already checked by `stat_size/1`.
  # sobelow_skip ["Traversal.FileModule"]
  defp read_capped(path, max) do
    case File.open(path, [:read, :binary]) do
      {:ok, fd} ->
        try do
          case IO.binread(fd, max + 1) do
            :eof -> {:ok, ""}
            {:error, _reason} -> {:error, :unreadable}
            data when is_binary(data) and byte_size(data) > max -> {:error, :too_large}
            data when is_binary(data) -> {:ok, data}
          end
        after
          File.close(fd)
        end

      {:error, _reason} ->
        {:error, :unreadable}
    end
  end

  defp decode(bytes) do
    case Jason.decode(bytes) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :unparsable}
    end
  end

  # Breadth-first over an explicit work list: a maliciously deep (not just
  # wide) structure can't blow the native call stack, because the self-call
  # here is in tail position and costs no frame of its own.
  defp within_depth(term, max), do: walk([{term, 0}], max)

  defp walk([], _max), do: :ok
  defp walk([{_term, depth} | _rest], max) when depth > max, do: {:error, :too_deep}

  defp walk([{term, depth} | rest], max) do
    case term do
      %{} = map -> walk(Enum.map(Map.values(map), &{&1, depth + 1}) ++ rest, max)
      list when is_list(list) -> walk(Enum.map(list, &{&1, depth + 1}) ++ rest, max)
      _ -> walk(rest, max)
    end
  end
end
