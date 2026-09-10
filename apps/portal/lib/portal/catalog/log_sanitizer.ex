defmodule Portal.Catalog.LogSanitizer do
  @moduledoc """
  Makes build log text safe to store and safe to render.

  Log bodies are compile output from unreviewed third-party Hex packages, so
  they are attacker-influenced input. Three things happen before one reaches
  Postgres:

    * Invalid UTF-8 becomes U+FFFD. This is a crash path, not hygiene: Postgres
      rejects invalid UTF-8 in a `text` column, so one stray byte would fail the
      ingest through every attempt and throw away a completed build.
    * ANSI escapes, C0 and C1 controls, and the bidi overrides are dropped.
      Defensive rather than routine — `Portal.Builder.build_docker_args/4`
      allocates no TTY, so `mix` disables colour and normal output carries no
      escapes at all — but a package can emit them directly, and stripping is
      cheap.
    * The text is truncated to a bounded budget with a marker saying what went.

  HTML escaping is deliberately *not* done here: HEEx escapes on render, and
  doing it twice would show users `&lt;` where the log said `<`.
  """

  @head_bytes 400 * 1024
  @tail_bytes 400 * 1024
  @runner_bytes 16 * 1024

  # ESC [ ... final byte. Covers colour, cursor movement, and the private-mode
  # sequences (`\e[?25l`) that progress bars use.
  @ansi ~r/\x1b\[[0-9;?]*[ -\/]*[@-~]/
  # ESC ] ... BEL or ST — the window-title sequences. The control sweep alone
  # eats the ESC and the terminator and leaves `]0;pwned` as visible text.
  @osc ~r/\x1b\][^\x1b\x07]*(?:\x07|\x1b\\)/
  # Everything below space except tab (\x09) and newline (\x0a), plus DEL.
  # Carriage returns go too: they are progress-bar redraws and render as
  # garbage inside a <pre>.
  @controls ~r/[\x00-\x08\x0b-\x1f\x7f]/
  # C1 controls, plus the bidi embeddings and isolates. U+202E reverses the
  # visual order of everything after it — the Trojan Source trick — and this
  # text is rendered on a public page. Codepoint ranges, so this needs the `u`
  # modifier and cannot be folded into the byte-oriented sweep above.
  @unicode_controls ~r/[\x{80}-\x{9f}\x{202a}-\x{202e}\x{2066}-\x{2069}]/u

  @type system_log :: %{
          body: String.t(),
          byte_size: non_neg_integer(),
          truncated: boolean()
        }

  @doc """
  Sanitize a per-system build log, keeping the head and the tail.

  Both ends carry signal — dependency resolution at the head, the error at the
  tail — and the middle is `Generated <app> app` lines. `byte_size` is the size
  of the input, before any truncation, so the page can say what was dropped.
  """
  @spec system_log(binary()) :: system_log()
  def system_log(raw) when is_binary(raw) do
    original = byte_size(raw)
    {body, truncated} = raw |> scrub() |> strip_controls() |> truncate_head_tail()

    %{body: body, byte_size: original, truncated: truncated}
  end

  @doc """
  Sanitize a `runner.log` tail for the run-level fallback.

  Tail only: a runner failure is always at the end. The `Portal.Builder` header
  is stripped explicitly rather than left for the tail cut to skip, because a
  short log makes the header part of the tail — and that header carries the
  full `docker run` argv and the host mount paths.

  `scratch_root` is taken as an argument, defaulting to the builder's own, so
  the masking can be tested without reaching into application config.
  """
  @spec runner_excerpt(binary(), Path.t() | nil) :: String.t()
  def runner_excerpt(raw, scratch_root \\ Portal.Builder.scratch_root()) when is_binary(raw) do
    raw
    |> scrub()
    |> strip_builder_header()
    |> mask_scratch_root(scratch_root)
    |> strip_controls()
    |> truncate_tail(@runner_bytes)
  end

  # `String.valid?/1` is the fast path: almost every log is already valid, and
  # the byte-at-a-time rebuild is only worth paying for when one is not.
  defp scrub(binary) do
    if String.valid?(binary) do
      binary
    else
      do_scrub(binary, [])
    end
  end

  defp do_scrub(<<>>, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp do_scrub(<<c::utf8, rest::binary>>, acc), do: do_scrub(rest, [<<c::utf8>> | acc])

  defp do_scrub(<<_invalid, rest::binary>>, acc), do: do_scrub(rest, ["�" | acc])

  # The escape sequences first: they contain \x1b, which the control sweep would
  # otherwise eat on its own, leaving `[31m` or `]0;title` behind as visible
  # text.
  defp strip_controls(text) do
    text
    |> then(&Regex.replace(@osc, &1, ""))
    |> then(&Regex.replace(@ansi, &1, ""))
    |> then(&Regex.replace(@controls, &1, ""))
    |> then(&Regex.replace(@unicode_controls, &1, ""))
  end

  # The header `Portal.Builder.log_command/2` writes: two rules of `=` with the
  # command between them, then a blank line. The width is deliberately not
  # pinned — pinning it to 80 meant a one-character change in the builder would
  # silently stop the strip from matching and ship the docker argv to the
  # public request page, with the suite still green.
  defp strip_builder_header(text) do
    Regex.replace(~r/\A=+\n.*?\n=+\n\n/s, text, "", global: false)
  end

  # Docker daemon errors echo the bind source path back — "bind source path does
  # not exist: /Users/deploy/.ncc-scratch/pkg-1.0.0-123/work" — and a mount
  # failure is exactly the class of failure that produces a run-level error_log.
  # No credentials leak (`build_docker_args/4` passes none), but the host
  # filesystem layout and the account name it runs as are still not something to
  # publish.
  defp mask_scratch_root(text, root) when is_binary(root) and root != "" do
    String.replace(text, root, "<scratch>")
  end

  defp mask_scratch_root(text, _root), do: text

  defp truncate_head_tail(text) do
    size = byte_size(text)

    if size <= @head_bytes + @tail_bytes do
      {text, false}
    else
      elided = size - @head_bytes - @tail_bytes

      # `binary_part/3` can cut a UTF-8 codepoint in half; `scrub/1` turns the
      # orphaned bytes into replacement characters rather than leaving Postgres
      # something it will reject.
      body =
        scrub(binary_part(text, 0, @head_bytes)) <>
          "\n\n[... #{elided} bytes elided by the portal ...]\n\n" <>
          scrub(binary_part(text, size - @tail_bytes, @tail_bytes))

      {body, true}
    end
  end

  defp truncate_tail(text, max) do
    size = byte_size(text)

    if size <= max do
      text
    else
      "[... truncated, showing the last #{max} bytes of #{size} ...]\n" <>
        scrub(binary_part(text, size - max, max))
    end
  end
end
