defmodule NccWorker.LogTail do
  @moduledoc """
  The end of a log, safe to put in `result.json`.

  Logs are cut on a byte boundary, which can split a multi-byte character, and
  build output can contain raw bytes that were never text. Either one makes
  `JSON.encode!/1` raise when the result is written, failing a build that
  succeeded. The tail is therefore made valid UTF-8 after the cut: invalid
  bytes become U+FFFD.
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
