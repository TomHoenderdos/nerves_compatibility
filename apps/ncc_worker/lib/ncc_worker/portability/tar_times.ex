defmodule NccWorker.Portability.TarTimes do
  @moduledoc """
  Whether two `.tar` or `.tar.gz` files a package's own compile wrote into
  its own `priv` in two builds differ only in the times they carry
  (`NccWorker.Portability.PrivRepro`, judge revision 21). `:erl_tar` stamps
  every member it adds from a binary with the wall clock (kino's
  `Kino.JS.__before_compile__/1` packs its assets so), so two users' own
  compiles of the same package differ the same way: there are no user's
  bytes to diverge from, and a reader that extracts the members gets the
  same files either way. The first build's bytes are the ones published.

  Strict, and only for these two formats, by the file's name:

    * `.tar.gz`: one gzip member and nothing after it (its deflate stream
      ends exactly 8 bytes before the file does, and those 8 bytes are its
      CRC-32 and size), whose header is the other's byte for byte except
      `MTIME` and `OS`. A header CRC (`FHCRC`) or a reserved flag is not
      read. It inflates to at most 64 MiB, and the tars inside are compared
      as below;
    * `.tar`: the members in the same order, each header valid (its
      checksum) and the other's byte for byte except `mtime` and the
      checksum (name, mode, uid, gid, size, type, link name, magic, uname,
      gname, device numbers, prefix all compared), and the same data bytes,
      padding included. A pax extended header (`x`, `g`, or Solaris's
      `X`, which bsdtar and GNU tar read as one) may also differ
      in its size, as long as its records are the other's in order once
      the `mtime`, `atime` and `ctime` records are left out, and neither
      holds a `size` record (which frames the next member's data for a
      POSIX reader where the ustar size, and `:erl_tar`, frame it
      otherwise). After the end of the archive (its first zero block) both
      hold the same bytes.

  Any other name, anything that does not parse, a size in base-256 and
  any other difference is `false`. Never raises.
  """

  import Bitwise

  @max_tar_bytes 64 * 1024 * 1024
  @block 512
  @time_keys ["mtime", "atime", "ctime"]
  # pax extended headers; Solaris's `X` is one to bsdtar and GNU tar.
  @pax_types [?x, ?g, ?X]

  @doc "Whether `a` and `b`, both named `name`, differ in their times alone."
  @spec same?(String.t(), binary(), binary()) :: boolean()
  def same?(name, a, b) when is_binary(name) and is_binary(a) and is_binary(b) do
    cond do
      String.ends_with?(name, ".tar.gz") -> gz_same?(a, b)
      String.ends_with?(name, ".tar") -> tar_same?(a, b)
      true -> false
    end
  rescue
    _ -> false
  catch
    _, _ -> false
  end

  def same?(_name, _a, _b), do: false

  defp gz_same?(a, b) do
    with {:ok, head_a, tar_a} <- gunzip(a),
         {:ok, head_b, tar_b} <- gunzip(b),
         true <- head_a == head_b do
      tar_same?(tar_a, tar_b)
    else
      _ -> false
    end
  end

  # The header without MTIME and OS, and the one member's content.
  defp gunzip(<<0x1F, 0x8B, 8, flags, _mtime::binary-4, xfl, _os, rest::binary>>)
       when (flags &&& 0xE2) == 0 do
    with {:ok, fields, body} <- optional_fields(flags, rest),
         size when size >= 8 <- byte_size(body),
         stream = binary_part(body, 0, size - 8),
         <<crc::little-32, isize::little-32>> <- binary_part(body, size - 8, 8),
         {:ok, tar} <- inflate(stream, true),
         # A byte shorter must not end the stream: nothing sits between the
         # deflate stream and the trailer.
         {:error, :not_ended} <- inflate(binary_part(stream, 0, max(size - 9, 0)), false),
         true <- :erlang.crc32(tar) == crc and band(byte_size(tar), 0xFFFFFFFF) == isize do
      {:ok, {flags, xfl, fields}, tar}
    else
      _ -> :error
    end
  end

  defp gunzip(_gz), do: :error

  # FEXTRA, FNAME and FCOMMENT, in that order.
  defp optional_fields(flags, rest) do
    with {:ok, extra, rest} <- extra(flags &&& 0x04, rest),
         {:ok, name, rest} <- zero_terminated(flags &&& 0x08, rest),
         {:ok, comment, rest} <- zero_terminated(flags &&& 0x10, rest) do
      {:ok, {extra, name, comment}, rest}
    end
  end

  defp extra(0, rest), do: {:ok, nil, rest}

  defp extra(_set, <<len::little-16, data::binary-size(len), rest::binary>>),
    do: {:ok, data, rest}

  defp extra(_set, _rest), do: :error

  defp zero_terminated(0, rest), do: {:ok, nil, rest}

  defp zero_terminated(_set, rest) do
    case :binary.split(rest, <<0>>) do
      [field, rest] -> {:ok, field, rest}
      _ -> :error
    end
  end

  # A raw deflate stream, at most @max_tar_bytes out: `{:ok, bytes}` when it
  # ends, `{:error, :not_ended}` when the input runs out first.
  defp inflate(stream, want_bytes?) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z, -15)
      out = inflate_loop(z, :zlib.safeInflate(z, stream), [], 0)

      case {out, ended?(z)} do
        {{:ok, bytes}, true} -> if want_bytes?, do: {:ok, bytes}, else: {:ok, :ended}
        {{:ok, _bytes}, false} -> {:error, :not_ended}
        {error, _ended} -> error
      end
    after
      :zlib.close(z)
    end
  end

  defp inflate_loop(z, {state, out}, acc, size) when state in [:continue, :finished] do
    size = size + IO.iodata_length(out)
    acc = [acc, out]

    cond do
      size > @max_tar_bytes -> {:error, :over_cap}
      state == :finished -> {:ok, IO.iodata_to_binary(acc)}
      true -> inflate_loop(z, :zlib.safeInflate(z, []), acc, size)
    end
  end

  defp inflate_loop(_z, _other, _acc, _size), do: {:error, :corrupt}

  defp ended?(z) do
    :zlib.inflateEnd(z)
    true
  rescue
    _ -> false
  end

  # --- tar ---------------------------------------------------------------------

  defp tar_same?(a, b) when byte_size(a) > @max_tar_bytes or byte_size(b) > @max_tar_bytes,
    do: false

  defp tar_same?(<<ha::binary-@block, ra::binary>>, <<hb::binary-@block, rb::binary>>) do
    cond do
      zero?(ha) and zero?(hb) -> ra == rb
      zero?(ha) or zero?(hb) -> false
      not (checksum_ok?(ha) and checksum_ok?(hb)) -> false
      :binary.at(ha, 156) in @pax_types -> pax_same?(ha, ra, hb, rb)
      true -> member_same?(ha, ra, hb, rb)
    end
  end

  defp tar_same?(_a, _b), do: false

  defp member_same?(ha, ra, hb, rb) do
    with true <- masked(ha, 136, 20) == masked(hb, 136, 20),
         {:ok, size} <- octal(binary_part(ha, 124, 12)),
         {:ok, da, ra} <- data(ra, size),
         {:ok, db, rb} <- data(rb, size),
         true <- da == db do
      tar_same?(ra, rb)
    else
      _ -> false
    end
  end

  # Size, mtime and checksum may differ; the records may not, but for times.
  defp pax_same?(ha, ra, hb, rb) do
    with true <- masked(ha, 124, 32) == masked(hb, 124, 32),
         {:ok, size_a} <- octal(binary_part(ha, 124, 12)),
         {:ok, size_b} <- octal(binary_part(hb, 124, 12)),
         {:ok, da, ra} <- data(ra, size_a),
         {:ok, db, rb} <- data(rb, size_b),
         {:ok, records_a} <- pax_records(binary_part(da, 0, size_a), []),
         {:ok, records_b} <- pax_records(binary_part(db, 0, size_b), []),
         false <- framing?(records_a) or framing?(records_b),
         true <- untimed(records_a) == untimed(records_b) do
      tar_same?(ra, rb)
    else
      _ -> false
    end
  end

  defp masked(header, at, len),
    do: [binary_part(header, 0, at), binary_part(header, at + len, @block - at - len)]

  # The data blocks of a member of `size` bytes, padding included.
  defp data(rest, size) do
    padded = div(size + @block - 1, @block) * @block

    case rest do
      <<data::binary-size(^padded), rest::binary>> -> {:ok, data, rest}
      _ -> :error
    end
  end

  defp zero?(block), do: block == <<0::size(@block * 8)>>

  # The unsigned sum of the header with the checksum field as spaces.
  defp checksum_ok?(header) do
    sum =
      for <<byte <- binary_part(header, 0, 148) <> "        " <> binary_part(header, 156, 356)>>,
        reduce: 0,
        do: (acc -> acc + byte)

    octal(binary_part(header, 148, 8)) == {:ok, sum}
  end

  # An octal field: digits, then NULs or spaces; base-256 (high bit) does
  # not parse.
  defp octal(<<first, _::binary>>) when (first &&& 0x80) != 0, do: :error

  defp octal(field) do
    case Regex.run(~r/\A *([0-7]+)[ \x00]*\z/, field) do
      [_, digits] -> {:ok, String.to_integer(digits, 8)}
      _ -> :error
    end
  end

  # `"<len> <key>=<value>\n"` records, in order.
  defp pax_records("", acc), do: {:ok, Enum.reverse(acc)}

  defp pax_records(data, acc) do
    with [len_text, _] <- :binary.split(data, " "),
         {len, ""} when len > 0 <- Integer.parse(len_text),
         <<record::binary-size(^len), rest::binary>> <- data,
         [_len, body] <- :binary.split(record, " "),
         true <- String.ends_with?(body, "\n"),
         [key, value] <- :binary.split(binary_part(body, 0, byte_size(body) - 1), "=") do
      pax_records(rest, [{key, value} | acc])
    else
      _ -> :error
    end
  end

  defp untimed(records), do: Enum.reject(records, fn {key, _value} -> key in @time_keys end)

  # A `size` record frames the next member's data for a POSIX reader
  # (bsdtar, GNU tar) where the ustar size field, which this walk follows
  # (as `:erl_tar` does), frames it otherwise: the two would read different
  # members out of the same bytes.
  defp framing?(records), do: Enum.any?(records, &match?({"size", _value}, &1))
end
