defmodule Portal.Catalog.LogSanitizer do
  @moduledoc """
  Sanitize build log text safe for Postgres storage and portal display.

  - Invalid UTF-8 bytes replaced with U+FFFD.
  - ANSI escape sequences stripped.
  - C0 control characters (except tab/newline) stripped.
  - Per-system logs truncated to 400 KB head + 400 KB tail.
  - Runner logs truncated to 16 KB tail only.
  """

  @head_bytes 400 * 1024
  @tail_bytes 400 * 1024
  @runner_tail_bytes 16 * 1024

  @ansi ~r/\x1b\[[0-9;?]*[ -\/]*[@-~]/
  @controls ~r/[\x00-\x08\x0b-\x1f\x7f]/

  @type system_log :: %{
          body: String.t(),
          byte_size: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Sanitize a per-system build log, keeping head and tail.

  Both ends carry signal — dependency resolution at head, error at tail.
  `byte_size` records the size *before* truncation.
  """
  @spec system_log(binary()) :: system_log()
  def system_log(raw) do
    original_size = byte_size(raw)

    raw
    |> scrub()
    |> strip_controls()
    |> truncate_head_tail()
    |> then(fn {body, truncated} ->
      %{
        body: body,
        byte_size: original_size,
        truncated: truncated
      }
    end)
  end

  @doc """
  Sanitize a `runner.log` tail for run-level fallback.

  Strips the Portal.Builder header and keeps only the tail.
  """
  @spec runner_excerpt(binary()) :: String.t()
  def runner_excerpt(raw) do
    raw
    |> scrub()
    |> strip_controls()
    |> strip_builder_header()
    |> then(fn text ->
      truncated = byte_size(text) > @runner_tail_bytes
      tail = truncate_tail(text, @runner_tail_bytes)

      if truncated do
        "[... log truncated ...]\n" <> tail
      else
        tail
      end
    end)
  end

  defp strip_controls(text) do
    text
    |> then(&Regex.replace(@ansi, &1, ""))
    |> then(&Regex.replace(@controls, &1, ""))
  end

  defp strip_builder_header(text) do
    Regex.replace(~r/\A={80}\n.*?\n={80}\n\n/s, text, "")
  end

  defp truncate_head_tail(text) do
    size = byte_size(text)

    if size <= @head_bytes + @tail_bytes do
      {text, false}
    else
      elided = size - @head_bytes - @tail_bytes

      body =
        binary_part(text, 0, @head_bytes) <>
          "\n[... #{elided} bytes elided ...]\n" <>
          truncate_tail(text, @tail_bytes)

      {body, true}
    end
  end

  defp truncate_tail(text, max) do
    size = byte_size(text)

    if size <= max do
      text
    else
      offset = size - max
      binary_part(text, offset, max)
    end
  end

  defp scrub(text) when is_binary(text) do
    scrub_binary(text, [])
    |> IO.iodata_to_binary()
  end

  defp scrub_binary(<<c::utf8, rest::binary>>, acc) do
    scrub_binary(rest, [acc, <<c::utf8>>])
  end

  defp scrub_binary(<<_::8, rest::binary>>, acc) do
    scrub_binary(rest, [acc, "�"])
  end

  defp scrub_binary(<<>>, acc) do
    acc
  end
end
