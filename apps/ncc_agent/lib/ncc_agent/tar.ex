defmodule NccAgent.Tar do
  @moduledoc """
  Upload batches of a run's archived files: plain (uncompressed) tars whose
  entries are named by the files' sha256, the shape the portal's
  `PUT /builder/v1/jobs/:id/files` verifies.
  """

  @block 512
  @end_of_archive 2 * @block

  @type file :: {sha :: String.t(), path :: Path.t()}

  @doc """
  Splits `files` greedily, in order, into batches whose tar (a 512-byte
  header per entry, content padded to 512 bytes, 1024 bytes of end of
  archive) is at most `max_bytes` on disk. A file whose tar alone is over
  the cap is a batch of its own: the portal refuses it and the refusal is
  reported, rather than dropped here.
  """
  @spec batches([file()], pos_integer()) :: [[file()]]
  def batches(files, max_bytes) do
    {batches, current, _size} =
      Enum.reduce(files, {[], [], @end_of_archive}, fn {_sha, path} = file,
                                                       {done, current, size} ->
        bytes = entry_bytes(File.stat!(path).size)

        cond do
          current == [] -> {done, [file], @end_of_archive + bytes}
          size + bytes <= max_bytes -> {done, [file | current], size + bytes}
          true -> {[Enum.reverse(current) | done], [file], @end_of_archive + bytes}
        end
      end)

    batches = if current == [], do: batches, else: [Enum.reverse(current) | batches]
    Enum.reverse(batches)
  end

  @doc "The on-disk size of a tar of files of these sizes."
  @spec tar_bytes([non_neg_integer()]) :: pos_integer()
  def tar_bytes(sizes), do: @end_of_archive + Enum.sum(Enum.map(sizes, &entry_bytes/1))

  defp entry_bytes(size), do: @block + div(size + @block - 1, @block) * @block

  @doc "Writes `batch` as a tar at `out`, each file under its sha name."
  @spec write([file()], Path.t()) :: :ok | {:error, term()}
  def write(batch, out) do
    entries =
      Enum.map(batch, fn {sha, path} -> {String.to_charlist(sha), String.to_charlist(path)} end)

    :erl_tar.create(String.to_charlist(out), entries, [])
  end
end
