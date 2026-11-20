defmodule Compatibility.KinoAssets do
  @moduledoc """
  The content proof of one Kino.JS asset archive a package's compile wrote
  into kino's build `priv` (foreign priv spec, section 3.4), shared by the
  worker's judge (`NccWorker.Portability.ForeignPriv`) and the portal's
  ingest (`Portal.Catalog.ToolchainForeignPriv`).

  `verify/1` takes the archive's bytes and name (`<d>/<h>.tar.gz`), the
  writer module's beam, and the writer's verified Hex tarball with its app
  and version, and passes only when the archive is exactly what Kino.JS
  packs from files that tarball holds:

    1. the name is `<dir_name(module)>/<h>.tar.gz`, `h` 26 characters of
       `[a-z2-7]`;
    2. the beam's `__assets_info__/0`, read from its Elixir debug info as a
       term (nothing is loaded or run), has one clause whose body is a map
       literal with `hash: h` and `cdn_url:
       "https://repo.hex.pm/preview/<app>/<version>/" <> assets_path`;
       inline assets (`cdn_url: nil`), no debug info or any other shape
       refuses;
    3. one gzip member: CM 8, FLG 0, any MTIME, XFL and OS byte; the deflate
       stream ends 8 bytes before the end of the file, the CRC and size
       match, and it inflates to at most 64 MiB;
    4. a ustar archive: each header's checksum valid, typeflag `0`, mode
       0100644, uid and gid 0, empty link name, uname and gname, no prefix,
       a relative safe name; no pax or GNU header; data padded with zeros;
       two zero blocks, then only zeros;
    5. its members, in order, are the sorted paths of the regular files
       under `assets_path/` in the tarball, leaving out a path with a
       segment that starts with `.` (as `Path.wildcard/1` does), with the
       same bytes; a non-regular entry there refuses;
    6. `h` is Kino's hash over the members (`hash/1`).

  The only bytes left free are the members' mtimes and the gzip header's
  MTIME, XFL and OS byte, which no reader reads. Never raises.
  """

  import Bitwise

  alias Compatibility.{ForeignPriv, StaticPriv}
  alias Compatibility.KinoAssets.Term

  @block 512
  @cdn "https://repo.hex.pm/preview/"
  @inline "inline or unrecognised Kino.JS assets"
  @unreadable "Kino.JS archive could not be read"
  @pax_or_gnu [?x, ?g, ?X, ?L, ?K]

  @type member :: {String.t(), binary()}
  @type proof :: %{
          dir: String.t(),
          hash: String.t(),
          assets_path: String.t(),
          members: [member()]
        }

  @spec verify(map()) :: {:ok, proof()} | {:error, String.t()}
  def verify(%{
        name: name,
        archive: archive,
        module: module,
        beam: beam,
        tarball: tarball,
        app: app,
        version: version
      })
      when is_binary(name) and is_binary(archive) and is_binary(module) and is_binary(beam) and
             is_binary(tarball) and is_binary(app) and is_binary(version) do
    with {:ok, dir, hash} <- archive_name(name, module),
         {:ok, info} <- assets_info(beam, module),
         :ok <- same_hash(info.hash, hash),
         {:ok, assets_path} <- assets_path(info.cdn_url, app, version),
         {:ok, members} <- members(archive),
         {:ok, files} <- package_assets(tarball, assets_path),
         :ok <- same_members(members, files, assets_path),
         :ok <- kino_hash(members, hash) do
      {:ok, %{dir: dir, hash: hash, assets_path: assets_path, members: members}}
    end
  rescue
    _ -> {:error, @unreadable}
  catch
    _, _ -> {:error, @unreadable}
  end

  def verify(_input), do: {:error, @unreadable}

  @doc """
  The module a beam holds and whether it exports `__assets_info__/0`, the
  function every `use Kino.JS` module defines: `{:ok, module, exports?}`, the
  module's name as it is written in the beam (`"Elixir.Kino.VegaLite"`), or
  `:error` for anything but an uncompressed beam whose atom table (`AtU8`,
  either length encoding) and export table (`ExpT`) read whole.

  The beam is a package's compile's output, so it is read as the portal reads
  every beam (`Compatibility.DeterministicBeams`): by its own IFF chunks, the
  names compared as bytes. No `:beam_lib`, which inflates a compressed beam
  without a bound and makes atoms of the names it reads, which a node never
  frees. Never raises.
  """
  @spec exports_assets_info(binary()) :: {:ok, String.t(), boolean()} | :error
  def exports_assets_info(<<"FOR1", size::32, "BEAM", rest::binary>>)
      when size >= 4 and size - 4 <= byte_size(rest) do
    with {:ok, chunks} <- beam_chunks(binary_part(rest, 0, size - 4), %{}),
         {:ok, atoms} <- atom_table(chunks["AtU8"]),
         [module | _] <- atoms,
         {:ok, exports} <- export_table(chunks["ExpT"], List.to_tuple(atoms)) do
      {:ok, module, {"__assets_info__", 0} in exports}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  def exports_assets_info(_beam), do: :error

  # Each chunk once, filling the file exactly (each padded to 4 bytes but
  # the last, which may end the file unpadded).
  defp beam_chunks(<<>>, acc), do: {:ok, acc}

  defp beam_chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    cond do
      Map.has_key?(acc, id) ->
        :error

      byte_size(rest) == 0 ->
        {:ok, Map.put(acc, id, data)}

      byte_size(rest) < pad ->
        :error

      true ->
        rest |> binary_part(pad, byte_size(rest) - pad) |> beam_chunks(Map.put(acc, id, data))
    end
  end

  defp beam_chunks(_bytes, _acc), do: :error

  # A negative count is OTP 28's table, each length a compact-term `u`: one
  # byte below 16, two below 2048, which covers every atom (at most 255
  # characters, so 1020 bytes). A positive count, one length byte each.
  defp atom_table(<<count::signed-32, rest::binary>>) when count < 0,
    do: read_atoms(rest, -count, &compact_length/1, [])

  defp atom_table(<<count::signed-32, rest::binary>>) when count > 0,
    do: read_atoms(rest, count, fn <<len, rest::binary>> -> {:ok, len, rest} end, [])

  defp atom_table(_data), do: :error

  defp read_atoms(_rest, 0, _length, acc), do: {:ok, Enum.reverse(acc)}

  defp read_atoms(bytes, n, length, acc) do
    with {:ok, len, rest} <- length.(bytes),
         <<name::binary-size(^len), rest::binary>> <- rest do
      read_atoms(rest, n - 1, length, [name | acc])
    else
      _ -> :error
    end
  end

  defp compact_length(<<len::4, 0::1, 0::3, rest::binary>>), do: {:ok, len, rest}

  defp compact_length(<<hi::3, 0::1, 1::1, 0::3, lo::8, rest::binary>>),
    do: {:ok, hi * 256 + lo, rest}

  defp compact_length(_bytes), do: :error

  # `{name, arity}` per export; an atom index outside the table is no beam.
  defp export_table(<<count::32, rest::binary>>, atoms) when byte_size(rest) == count * 12 do
    exports =
      for <<index::32, arity::32, _label::32 <- rest>> do
        if index >= 1 and index <= tuple_size(atoms),
          do: {elem(atoms, index - 1), arity},
          else: throw(:bad_index)
      end

    {:ok, exports}
  catch
    :bad_index -> :error
  end

  defp export_table(_data, _atoms), do: :error

  @doc "Kino.JS's archive hash over `members` (`assets_hash/1` in kino's js.ex)."
  @spec hash([member()]) :: String.t()
  def hash(members) do
    members
    |> Enum.sort()
    |> Enum.flat_map(&Tuple.to_list/1)
    |> :erlang.md5()
    |> Base.encode32(case: :lower, padding: false)
  end

  defp archive_name(name, module) do
    case ForeignPriv.parse_path("priv/assets/" <> name) do
      {:ok, dir, hash} ->
        if dir == ForeignPriv.dir_name(module),
          do: {:ok, dir, hash},
          else: {:error, "archive is not in #{module}'s directory"}

      :error ->
        {:error, "archive name is not <dir>/<26 base32>.tar.gz"}
    end
  end

  defp same_hash(hash, hash), do: :ok
  defp same_hash(_beam, _name), do: {:error, "archive name's hash is not the module's"}

  @doc """
  The `hash` and `cdn_url` literals of `module`'s `__assets_info__/0`, from
  the beam's Elixir debug info read as a term; `{:error, "inline or
  unrecognised Kino.JS assets"}` for anything else, a compressed beam
  included. The beam is read by its own IFF chunks and its `Dbgi` term
  without making an atom (`Compatibility.KinoAssets.Term`), so the portal
  can read a package's beam on a node that lives on across ingests.
  """
  @spec assets_info(binary(), String.t()) ::
          {:ok, %{hash: String.t(), cdn_url: String.t()}} | {:error, String.t()}
  def assets_info(<<"FOR1", size::32, "BEAM", rest::binary>>, module)
      when is_binary(module) and size >= 4 and size - 4 <= byte_size(rest) do
    with {:ok, chunks} <- beam_chunks(binary_part(rest, 0, size - 4), %{}),
         {:ok, [^module | _]} <- atom_table(chunks["AtU8"]),
         dbgi when is_binary(dbgi) <- chunks["Dbgi"],
         {:ok, {{:atom, "debug_info_v1"}, {:atom, "elixir_erl"}, {{:atom, "elixir_v1"}, meta, _}}}
         when is_map(meta) <- Term.decode(dbgi, ForeignPriv.max_inflated()),
         defs when is_list(defs) <- Map.get(meta, {:atom, "definitions"}),
         [{_fa, {:atom, "def"}, _meta, [{_clause_meta, [], [], {{:atom, "%{}"}, _, pairs}}]}] <-
           Enum.filter(defs, &match?({{{:atom, "__assets_info__"}, 0}, _, _, _}, &1)),
         true <- is_list(pairs) and Enum.all?(pairs, &match?({{:atom, _key}, _value}, &1)),
         [hash] when is_binary(hash) <- values(pairs, "hash"),
         [cdn_url] when is_binary(cdn_url) <- values(pairs, "cdn_url") do
      {:ok, %{hash: hash, cdn_url: cdn_url}}
    else
      _ -> {:error, @inline}
    end
  rescue
    _ -> {:error, @inline}
  end

  def assets_info(_beam, _module), do: {:error, @inline}

  defp values(pairs, key), do: for({{:atom, ^key}, value} <- pairs, do: value)

  defp assets_path(cdn_url, app, version) do
    prefix = @cdn <> app <> "/" <> version <> "/"
    size = byte_size(prefix)

    with true <- String.starts_with?(cdn_url, prefix),
         path = binary_part(cdn_url, size, byte_size(cdn_url) - size),
         true <- safe_relative?(path) do
      {:ok, path}
    else
      _ -> {:error, "assets_path is not this release's: #{String.slice(cdn_url, 0, 200)}"}
    end
  end

  # Relative, every segment non-empty and none starting with `.`, no
  # backslash or NUL: the paths Kino.JS's wildcard can name.
  defp safe_relative?(path) do
    String.valid?(path) and path != "" and not String.contains?(path, ["\\", <<0>>]) and
      Enum.all?(String.split(path, "/"), &(&1 != "" and not String.starts_with?(&1, ".")))
  end

  @doc "The members of a strict single-member gzip ustar archive (steps 3 and 4)."
  @spec members(binary()) :: {:ok, [member()]} | {:error, String.t()}
  def members(archive) when is_binary(archive) do
    with {:ok, tar} <- gunzip(archive), do: tar_members(tar, [])
  rescue
    _ -> {:error, @unreadable}
  end

  def members(_archive), do: {:error, @unreadable}

  defp gunzip(<<0x1F, 0x8B, 8, 0, _mtime::binary-4, _xfl, _os, body::binary>>)
       when byte_size(body) >= 8 do
    size = byte_size(body)
    stream = binary_part(body, 0, size - 8)
    <<crc::little-32, isize::little-32>> = binary_part(body, size - 8, 8)

    with {:ok, tar} <- inflate(stream, true),
         # A byte shorter must not end the stream: nothing sits between the
         # deflate stream and the trailer.
         {:error, :not_ended} <- inflate(binary_part(stream, 0, max(size - 9, 0)), false),
         true <- :erlang.crc32(tar) == crc and band(byte_size(tar), 0xFFFFFFFF) == isize do
      {:ok, tar}
    else
      {:error, :over_cap} -> {:error, "archive inflates past 64 MiB"}
      _ -> {:error, "not one gzip member that ends at the file's end"}
    end
  end

  defp gunzip(<<0x1F, 0x8B, 8, _flags, _rest::binary>>), do: {:error, "gzip header has flags set"}
  defp gunzip(_bytes), do: {:error, "not a gzip file"}

  # A raw deflate stream, at most `ForeignPriv.max_inflated/0` out:
  # `{:ok, bytes}` when it ends, `{:error, :not_ended}` when the input runs
  # out first (as `NccWorker.Portability.TarTimes` reads one).
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
      size > ForeignPriv.max_inflated() -> {:error, :over_cap}
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

  defp tar_members(<<header::binary-@block, rest::binary>>, acc) do
    if zero?(header) do
      tar_end(rest, acc)
    else
      with {:ok, name, size} <- header(header),
           {:ok, data, rest} <- data(rest, size) do
        tar_members(rest, [{name, data} | acc])
      end
    end
  end

  defp tar_members(_bytes, _acc), do: {:error, "tar archive does not end"}

  # The second zero block, then only zeros (`:erl_tar` may pad to a record).
  defp tar_end(<<second::binary-@block, rest::binary>>, acc) do
    if zero?(second) and zero?(rest),
      do: {:ok, Enum.reverse(acc)},
      else: {:error, "bytes after the tar archive's end"}
  end

  defp tar_end(_rest, _acc), do: {:error, "tar archive does not end"}

  defp header(h) do
    <<name::binary-100, mode::binary-8, uid::binary-8, gid::binary-8, size::binary-12,
      _mtime::binary-12, _sum::binary-8, type, link::binary-100, magic::binary-6,
      version::binary-2, uname::binary-32, gname::binary-32, _major::binary-8, _minor::binary-8,
      prefix::binary-155, _pad::binary-12>> = h

    # In order: the first that fails is the reason.
    failed =
      Enum.find(
        [
          {checksum_ok?(h), "tar header checksum does not match"},
          {type not in @pax_or_gnu, "tar archive has a pax or GNU header"},
          {type == ?0, "tar member is not a regular file"},
          {{magic, version} == {"ustar\0", "00"}, "tar header is not ustar"},
          {octal(mode) == {:ok, 0o100644}, "tar member mode is not 0100644"},
          {Enum.map([uid, gid], &octal/1) == [{:ok, 0}, {:ok, 0}], "tar member owner is not 0"},
          {Enum.all?([link, uname, gname], &zero?/1), "tar member names a link or an owner"},
          {zero?(prefix), "tar member name has a prefix"}
        ],
        &(not elem(&1, 0))
      )

    case failed do
      nil -> name_and_size(name, size)
      {false, why} -> {:error, why}
    end
  end

  defp name_and_size(field, size) do
    with [name | rest] <- :binary.split(field, <<0>>),
         true <- Enum.all?(rest, &zero?/1),
         true <- safe_relative?(name),
         {:ok, n} <- octal(size) do
      {:ok, name, n}
    else
      _ -> {:error, "tar member name is not a safe relative path"}
    end
  end

  defp checksum_ok?(<<pre::binary-148, field::binary-8, post::binary>>),
    do: octal(field) == {:ok, sum(pre) + 8 * ?\s + sum(post)}

  defp sum(bin), do: for(<<b <- bin>>, reduce: 0, do: (acc -> acc + b))

  # NUL- or space-terminated octal; base-256 and empty fields are no number.
  defp octal(field) do
    digits = field |> :binary.split(<<0>>) |> hd() |> String.trim(" ")

    case Integer.parse(digits, 8) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp data(rest, size) do
    pad_size = div(size + @block - 1, @block) * @block - size

    case rest do
      <<data::binary-size(^size), pad::binary-size(^pad_size), rest::binary>> ->
        if zero?(pad), do: {:ok, data, rest}, else: {:error, "tar data is not padded with zeros"}

      _ ->
        {:error, "tar archive is cut short"}
    end
  end

  defp zero?(bin), do: bin == :binary.copy(<<0>>, byte_size(bin))

  # The regular files under `assets_path/` in the tarball's contents, as
  # `{path below assets_path, bytes}` sorted by path, without dotfiles.
  defp package_assets(tarball, assets_path) do
    prefix = assets_path <> "/"

    with {:ok, tar} <- StaticPriv.contents(tarball),
         {:ok, table} <- :erl_tar.table({:binary, tar}, [:verbose]),
         listed = for({name, type, _, _, _, _, _} <- table, do: {List.to_string(name), type}),
         under = for({name, type} <- listed, String.starts_with?(name, prefix), do: {name, type}),
         :ok <- only_regular(under, assets_path) do
      wanted =
        for {name, :regular} <- under,
            rel = binary_part(name, byte_size(prefix), byte_size(name) - byte_size(prefix)),
            not hidden?(rel),
            do: {rel, name}

      read_members(tar, wanted)
    else
      {:error, _why} = error -> error
      _ -> {:error, "the package's tarball could not be read"}
    end
  end

  defp only_regular(entries, assets_path) do
    if Enum.all?(entries, fn {_name, type} -> type in [:regular, :directory] end),
      do: :ok,
      else: {:error, "non-regular file under #{assets_path} in the tarball"}
  end

  defp hidden?(rel), do: rel |> String.split("/") |> Enum.any?(&String.starts_with?(&1, "."))

  defp read_members(_tar, []), do: {:ok, []}

  defp read_members(tar, wanted) do
    names = for {_rel, name} <- wanted, do: String.to_charlist(name)

    with {:ok, files} <- :erl_tar.extract({:binary, tar}, [:memory, {:files, names}]) do
      bytes = Map.new(files, fn {name, data} -> {List.to_string(name), data} end)

      {:ok,
       wanted |> Enum.map(fn {rel, name} -> {rel, Map.fetch!(bytes, name)} end) |> Enum.sort()}
    end
  end

  defp same_members(members, members, _assets_path), do: :ok

  defp same_members(_members, _files, assets_path),
    do: {:error, "archive members differ from the package's assets under #{assets_path}"}

  defp kino_hash(members, hash) do
    if hash(members) == hash,
      do: :ok,
      else: {:error, "archive hash is not Kino's over its members"}
  end
end
