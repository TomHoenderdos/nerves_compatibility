defmodule NccAgent.Tar do
  @moduledoc """
  Upload batches of a run's archived files: plain (uncompressed) tars whose
  entries are named by the files' sha256, the shape the portal's
  `PUT /builder/v1/jobs/:id/files` verifies.
  """

  @type file :: {sha :: String.t(), path :: Path.t()}

  @doc """
  Splits `files` greedily, in order, into batches of at most `max_bytes`
  of file content. A file larger than the cap is a batch of its own: the
  portal refuses it and the refusal is reported, rather than dropped here.
  """
  @spec batches([file()], pos_integer()) :: [[file()]]
  def batches(files, max_bytes) do
    {batches, current, _size} =
      Enum.reduce(files, {[], [], 0}, fn {_sha, path} = file, {done, current, size} ->
        bytes = File.stat!(path).size

        cond do
          current == [] -> {done, [file], bytes}
          size + bytes <= max_bytes -> {done, [file | current], size + bytes}
          true -> {[Enum.reverse(current) | done], [file], bytes}
        end
      end)

    batches = if current == [], do: batches, else: [Enum.reverse(current) | batches]
    Enum.reverse(batches)
  end

  @doc "Writes `batch` as a tar at `out`, each file under its sha name."
  @spec write([file()], Path.t()) :: :ok | {:error, term()}
  def write(batch, out) do
    entries =
      Enum.map(batch, fn {sha, path} -> {String.to_charlist(sha), String.to_charlist(path)} end)

    :erl_tar.create(String.to_charlist(out), entries, [])
  end
end
