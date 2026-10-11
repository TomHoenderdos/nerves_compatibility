defmodule NccWorker.LogTail do
  @moduledoc """
  The end of a log, safe to put in `result.json`.

  Logs are cut on a byte boundary, which can split a multi-byte character, and
  build output can contain raw bytes that were never text. Either one makes
  `JSON.encode!/1` raise when the result is written, failing a build that
  succeeded. The tail is therefore made valid UTF-8 after the cut: invalid
  bytes become U+FFFD.

  A failed target's tail also carries the worker's own reason (`with_error/2`).
  """

  @doc "The last `max_bytes` of `text` (at most), as valid UTF-8."
  @spec tail(binary(), non_neg_integer()) :: String.t()
  def tail(text, max_bytes) when is_binary(text) do
    size = byte_size(text)

    text
    |> binary_part(max(size - max_bytes, 0), min(size, max_bytes))
    |> String.replace_invalid()
    |> trim_to(max_bytes)
  end

  @doc """
  The stored log tail with the worker's own failure reason appended. A reason
  raised after the last build command otherwise leaves a tail that ends in
  "Firmware built successfully!" on a target marked failed.
  """
  @spec with_error(String.t() | nil, term()) :: String.t() | nil
  def with_error(log_tail, nil), do: log_tail
  def with_error(nil, error), do: "** ncc_worker: #{reason(error)}\n"
  def with_error(log_tail, error), do: log_tail <> "\n** ncc_worker: #{reason(error)}\n"

  defp reason(error) when is_binary(error), do: error
  defp reason(error), do: inspect(error)

  # U+FFFD is three bytes, so replacing one invalid byte can push the tail past
  # the budget; drop whole characters from the front until it fits.
  defp trim_to(text, max_bytes) when byte_size(text) <= max_bytes, do: text

  defp trim_to(text, max_bytes) do
    case String.next_grapheme(text) do
      {_first, rest} -> trim_to(rest, max_bytes)
      nil -> ""
    end
  end
end
