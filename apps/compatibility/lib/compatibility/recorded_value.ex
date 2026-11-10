defmodule Compatibility.RecordedValue do
  @moduledoc """
  Whether a manifest-recorded `compile_env` value is plain, small ETF
  (precompiled judge refinements, Task I: defence in depth with client
  0.3.2; fix round 1: a tag-level walk, not `binary_to_term`).

  The client decodes a recorded value with
  `:erlang.binary_to_term(bin, [:safe])`
  (`precompiled`'s `Match.recorded_equals?/2`). A malicious package can set
  any term as its own application env at compile time before that read is
  recorded, and `[:safe]` alone does not stop every shape of it:

    * compressed ETF inflates before `[:safe]` runs, a memory bomb on every
      client at install;
    * `[:safe]` admits a fun of an already-loaded module, and does nothing
      about a pid, a port or a reference, none of which a client can ever
      usefully compare against its own config;
    * `[:safe]`, and `binary_to_term/1,2` generally, raises on any atom not
      already in the decoding VM's atom table — acceptance would then
      depend on which atoms happen to be loaded where. In the worker,
      `config_reads` decodes in the escript VM, so a value as ordinary as
      `{:phoenix, :json_library, Jason}` could be refused there while
      being fine everywhere else, turning an unrelated package's verdict
      into could-not-judge. A real client VM has every atom its own
      `mix.lock` loaded, which is not the deciding VM's atom table, so
      this module must not depend on that table either way.

  So this module never calls `binary_to_term`: it walks the raw External
  Term Format byte-by-byte, by tag, and creates no atom and builds no term
  of its own. The worker and the portal both run this check before
  recording or re-serving a value, and the client runs the identical rule
  before matching one (see `PRECOMPILED_API.md`).

  A recorded value, after base64url decode, is acceptable only when:

    1. it is at most 65,536 bytes and starts with the ETF version byte
       (`131`), not the compressed marker (`131, 80`);
    2. every term in it, walked from the top, is one of: a small or large
       integer, a float (new or old format), an atom (any of the four atom
       encodings, length-checked, no atom created), `nil`, a string
       (`STRING_EXT`, i.e. a list of bytes stored as raw bytes), a binary,
       a bitstring, a small or large bignum, a tuple (small or large), a
       list (proper or improper — its tail is walked like any other term),
       or a map (keys and values both walked);
    3. nothing in it is a fun (plain or export), a pid, a port, a
       reference, an atom cache reference, or any tag this module does not
       recognise;
    4. the byte stream is exactly consumed: no trailing bytes after the
       last term, and no term whose declared length runs past the end of
       the buffer (a truncated value or an absurd length header both fail
       to match and are refused, never read out of bounds).

  Each binary pattern below either matches a complete, in-bounds term or
  does not match at all — Elixir does not partially match a binary, so a
  length header longer than the buffer that holds it simply fails every
  clause and falls through to the catch-all refusal; nothing is read past
  what the length claims or the buffer holds.
  """

  @max_bytes 65_536

  @doc "Whether `base64` is an acceptable recorded `compile_env` value."
  @spec acceptable?(term()) :: boolean()
  def acceptable?(base64) when is_binary(base64) do
    case Base.url_decode64(base64, padding: false) do
      {:ok, <<131, rest::binary>> = bin} when byte_size(bin) <= @max_bytes ->
        walk(rest, 1)

      _ ->
        false
    end
  end

  def acceptable?(_base64), do: false

  # `n` is the count of terms still owed by the stream so far (starts at 1,
  # for the one top-level term). Each clause below reads exactly one term
  # and adjusts `n` by how many more terms that term itself contains, so
  # the walk is tail-recursive and never holds a decoded term.
  defp walk(<<>>, 0), do: true
  defp walk(_rest, 0), do: false

  # SMALL_INTEGER_EXT
  defp walk(<<97, _byte, rest::binary>>, n), do: walk(rest, n - 1)
  # INTEGER_EXT
  defp walk(<<98, _int::32, rest::binary>>, n), do: walk(rest, n - 1)
  # NEW_FLOAT_EXT
  defp walk(<<70, f::64-float, rest::binary>>, n) when is_float(f), do: walk(rest, n - 1)
  # FLOAT_EXT (old, fixed 31-byte ASCII)
  defp walk(<<99, _digits::binary-size(31), rest::binary>>, n), do: walk(rest, n - 1)
  # ATOM_EXT, ATOM_UTF8_EXT (16-bit length)
  defp walk(<<tag, len::16, atom::binary-size(len), rest::binary>>, n)
       when tag in [100, 118] do
    if plain_atom?(tag, atom), do: walk(rest, n - 1), else: false
  end

  # SMALL_ATOM_EXT, SMALL_ATOM_UTF8_EXT (8-bit length)
  defp walk(<<tag, len::8, atom::binary-size(len), rest::binary>>, n)
       when tag in [115, 119] do
    if plain_atom?(tag, atom), do: walk(rest, n - 1), else: false
  end

  # NIL_EXT (empty list)
  defp walk(<<106, rest::binary>>, n), do: walk(rest, n - 1)
  # STRING_EXT (a list of bytes, stored as a raw byte string)
  defp walk(<<107, len::16, _string::binary-size(len), rest::binary>>, n), do: walk(rest, n - 1)
  # BINARY_EXT
  defp walk(<<109, len::32, _bin::binary-size(len), rest::binary>>, n), do: walk(rest, n - 1)
  # BIT_BINARY_EXT: length, then the number of used bits in the last byte
  # (1..8), then the data
  defp walk(<<77, len::32, bits, _bin::binary-size(len), rest::binary>>, n)
       when len > 0 and bits in 1..8 do
    walk(rest, n - 1)
  end

  # SMALL_BIG_EXT: 8-bit length, 8-bit sign, then that many digit bytes
  defp walk(<<110, len::8, sign, _digits::binary-size(len), rest::binary>>, n)
       when sign in 0..1 do
    walk(rest, n - 1)
  end

  # LARGE_BIG_EXT: 32-bit length, 8-bit sign, then that many digit bytes
  defp walk(<<111, len::32, sign, _digits::binary-size(len), rest::binary>>, n)
       when sign in 0..1 do
    walk(rest, n - 1)
  end

  # SMALL_TUPLE_EXT: 8-bit arity, then that many elements
  defp walk(<<104, arity::8, rest::binary>>, n), do: walk(rest, n - 1 + arity)
  # LARGE_TUPLE_EXT: 32-bit arity, then that many elements
  defp walk(<<105, arity::32, rest::binary>>, n), do: walk(rest, n - 1 + arity)
  # LIST_EXT: 32-bit length, then that many elements, then one tail term
  # (nil for a proper list, anything else for an improper one)
  defp walk(<<108, len::32, rest::binary>>, n), do: walk(rest, n + len)
  # MAP_EXT: 32-bit arity (pair count), then 2 * arity key/value terms
  defp walk(<<116, arity::32, rest::binary>>, n), do: walk(rest, n - 1 + 2 * arity)

  # Everything else is refused: 80 (compressed ETF, only valid as the very
  # first byte after the version byte, which this walker never sees since
  # `acceptable?/1` matches it before calling here), 112/113/117 (new fun,
  # export, fun — the three fun encodings), 103/88 (pid, new pid), 102/89/120
  # (port, new port, V4 port), 101/114/90 (reference, new reference, newer
  # reference), 82 (atom cache reference — meaningless outside the
  # compressed stream that defines it), 121 (LOCAL_EXT, not a wire format),
  # any unrecognised tag, and a term whose declared length does not fit the
  # remaining buffer (which never matches any clause above and lands here).
  defp walk(_rest, _n), do: false

  defp plain_atom?(tag, atom) when tag in [100, 115], do: byte_size(atom) <= 255
  defp plain_atom?(_tag, atom), do: String.valid?(atom) and String.length(atom) <= 255
end
