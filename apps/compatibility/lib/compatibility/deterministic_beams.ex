defmodule Compatibility.DeterministicBeams do
  @moduledoc """
  The deterministic sibling of a toolchain build (`docs/superpowers` design
  addendum, option (a)): the same package, closure and toolchain compiled
  again with `ERL_COMPILER_OPTIONS=deterministic`, which a client takes only
  when its own project sets exactly that option. The sibling is a real
  compile, so its beams are what a user's own deterministic compile gives;
  this module is the check that the option changed only what it is known to
  change, run by the worker before it records a sibling and by the portal
  again at ingest. Anything else drops the sibling, never the build.

  `compare_ebin/2` takes the two builds' `ebin` files, `%{path => bytes}`:

    * the same file names;
    * every file that is not a `.beam` (the `.app` among them) byte for byte
      the same;
    * every beam the same module, compiled with the option: its `CInf` has
      neither `options` nor `source` (`compile:compile_info/3` leaves both
      out under `deterministic`), so a compile the option never reached
      cannot pass for one it did;
    * the same chunk ids, with the chunks that differ inside the set the
      option is known to touch, by the module's language (its `Dbgi`
      backend, the same in both):
      * an Elixir module (`elixir_erl`): `CInf`, `Dbgi`, `Docs` and `ExCk`
        alone. Its code, literals, line table and attributes are those of
        the build without the option, and so is its `beam_lib:md5/1`, which
        covers no chunk outside them;
      * an Erlang module (`erl_abstract_code`): `CInf`, `Dbgi`, `Docs`,
        `Line`, `LitT` and `Attr`, and `FunT` in each fun's `old_uniq`
        alone. The option gives epp the source's base name, which is the
        line table's file and `?FILE`, so the literal table, the md5 and
        with it the default `vsn` change, and so does every fun's
        `old_uniq`, which the compiler takes from the md5
        (`beam_asm:finalize_fun_table/2`); the code does not;
      * any other backend, or no `Dbgi`: held to the Elixir rule.

  The beams are untrusted: package code wrote them, and the portal checks
  them on its own node, which lives on across ingests. So no `:beam_lib`
  reads them (it inflates a gzip-compressed beam without a bound, and makes
  atoms of the module's name and of every atom in its debug info, which a
  node never frees), and nothing here creates an atom. The chunks come from
  this module's own IFF reader (an uncompressed beam, each chunk once), the
  module's name is the atom table's first entry as bytes, the sibling's
  `CInf` is decoded `[:safe]` only when small and uncompressed, and of the
  `Dbgi` only its backend's name is read, from a bounded prefix.

  Never raises.
  """

  @options ["deterministic"]
  @env_name "ERL_COMPILER_OPTIONS"
  @env_value "deterministic"

  @elixir_chunks ~w(CInf Dbgi Docs ExCk)
  @erlang_chunks ~w(CInf Dbgi Docs Line LitT Attr)

  # A deterministic compile info is `[{version, _}]`; far below this.
  @max_info_bytes 64 * 1024
  # Enough of a debug info term for its tag and backend.
  @head_bytes 64

  @doc "The `build.erl_compiler_options` a deterministic sibling carries."
  @spec options() :: [String.t()]
  def options, do: @options

  @doc "The environment variable a sibling is compiled with, and its value."
  @spec env() :: {String.t(), String.t()}
  def env, do: {@env_name, @env_value}

  @doc "The variable's name."
  @spec env_name() :: String.t()
  def env_name, do: @env_name

  @doc "Checks a sibling's `ebin` against its build's (see the moduledoc)."
  @spec compare_ebin(%{String.t() => binary()}, %{String.t() => binary()}) ::
          :ok | {:error, String.t()}
  def compare_ebin(normal, sibling) when is_map(normal) and is_map(sibling) do
    names = normal |> Map.keys() |> Enum.sort()

    cond do
      names != sibling |> Map.keys() |> Enum.sort() ->
        {:error, "the sibling's ebin holds other files"}

      names == [] ->
        {:error, "no ebin files"}

      true ->
        Enum.reduce_while(names, :ok, &compare_named(&1, &2, normal, sibling))
    end
  end

  def compare_ebin(_normal, _sibling), do: {:error, "no ebin files"}

  defp compare_named(name, :ok, normal, sibling) do
    case compare_file(name, Map.fetch!(normal, name), Map.fetch!(sibling, name)) do
      :ok -> {:cont, :ok}
      {:error, why} -> {:halt, {:error, "#{name}: #{why}"}}
    end
  end

  defp compare_file(name, normal, sibling) when is_binary(normal) and is_binary(sibling) do
    cond do
      Path.extname(name) == ".beam" -> compare_beam(normal, sibling)
      normal == sibling -> :ok
      true -> {:error, "differs"}
    end
  end

  defp compare_file(_name, _normal, _sibling), do: {:error, "unreadable"}

  @doc "Checks one sibling beam against its build's (see the moduledoc)."
  @spec compare_beam(binary(), binary()) :: :ok | {:error, String.t()}
  def compare_beam(normal, sibling) when is_binary(normal) and is_binary(sibling) do
    with {:ok, a} <- chunks(normal),
         {:ok, b} <- chunks(sibling),
         :ok <- same_module(a, b),
         :ok <- deterministic_info(b),
         :ok <- same_ids(a, b) do
      kind = kind(a, b)
      differ = for {id, bytes} <- a, List.keyfind(b, id, 0) != {id, bytes}, do: id

      case Enum.reject(differ -- allowed(kind), &uniq_only?(&1, kind, a, b)) do
        [] -> :ok
        ids -> {:error, "chunks #{Enum.join(ids, ", ")} differ"}
      end
    end
  rescue
    _ -> {:error, "unreadable beam"}
  end

  def compare_beam(_normal, _sibling), do: {:error, "unreadable beam"}

  # The beam's chunks, `[{id, bytes}]`, read by this module's own IFF
  # reader: an uncompressed `FOR1 ... BEAM` file whose chunks fill it
  # exactly, each id once. No `:beam_lib`, which inflates a gzip-compressed
  # beam without a bound and makes an atom of the module's name.
  defp chunks(<<"FOR1", size::32, "BEAM", rest::binary>>)
       when size >= 4 and size - 4 <= byte_size(rest) do
    with {:ok, chunks} <- read_chunks(binary_part(rest, 0, size - 4), []),
         ids = Enum.map(chunks, &elem(&1, 0)),
         true <- ids == Enum.uniq(ids) do
      {:ok, chunks}
    else
      _ -> {:error, "unreadable beam"}
    end
  end

  defp chunks(_bytes), do: {:error, "unreadable beam"}

  defp read_chunks(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp read_chunks(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    case rest do
      <<_pad::binary-size(^pad), rest::binary>> -> read_chunks(rest, [{id, data} | acc])
      <<>> -> read_chunks(<<>>, [{id, data} | acc])
      _ -> :error
    end
  end

  defp read_chunks(_bytes, _acc), do: :error

  # The first atom of the atom table is the module's name; it is compared
  # as bytes, never made an atom.
  defp same_module(a, b) do
    case {module_name(a), module_name(b)} do
      {{:ok, name}, {:ok, name}} -> :ok
      {{:ok, _}, {:ok, _}} -> {:error, "another module"}
      _ -> {:error, "unreadable beam"}
    end
  end

  defp module_name(chunks) do
    case List.keyfind(chunks, "AtU8", 0) || List.keyfind(chunks, "Atom", 0) do
      {_, <<count::signed-32, rest::binary>>} when count != 0 -> first_atom(count, rest)
      _ -> :error
    end
  end

  defp first_atom(count, <<len::8, name::binary-size(len), _::binary>>) when count > 0,
    do: {:ok, name}

  # A negative count (OTP 28's long atoms): each length is a compact-term
  # `u`, one byte below 16, two below 2048, which covers every atom.
  defp first_atom(_count, <<len::4, 0::1, 0::3, name::binary-size(len), _::binary>>),
    do: {:ok, name}

  defp first_atom(_count, <<hi::3, 0::1, 1::1, 0::3, lo::8, rest::binary>>) do
    len = hi * 256 + lo

    case rest do
      <<name::binary-size(^len), _::binary>> -> {:ok, name}
      _ -> :error
    end
  end

  defp first_atom(_count, _rest), do: :error

  # The sibling's `CInf`, a small uncompressed term decoded `[:safe]`: one
  # that names an atom this VM does not have is no deterministic compile
  # info, and none is created.
  # Misc.BinToTerm, reviewed: the bytes are untrusted, so only an
  # uncompressed term (no inflation) of at most @max_info_bytes is decoded,
  # `[:safe]` (no atom, no external fun reference created), and only its
  # top-level keys are looked at; nothing in it is ever called.
  # sobelow_skip ["Misc.BinToTerm"]
  defp deterministic_info(chunks) do
    case List.keyfind(chunks, "CInf", 0) do
      {_, <<131, tag, _::binary>> = bytes}
      when tag != 80 and byte_size(bytes) <= @max_info_bytes ->
        info = :erlang.binary_to_term(bytes, [:safe])

        cond do
          not is_list(info) -> {:error, "no compile info"}
          List.keymember?(info, :source, 0) -> {:error, "not compiled with the option"}
          List.keymember?(info, :options, 0) -> {:error, "not compiled with the option"}
          true -> :ok
        end

      _ ->
        {:error, "no compile info"}
    end
  rescue
    ArgumentError -> {:error, "unreadable compile info"}
  end

  defp same_ids(a, b) do
    if Enum.map(a, &elem(&1, 0)) |> Enum.sort() == Enum.map(b, &elem(&1, 0)) |> Enum.sort(),
      do: :ok,
      else: {:error, "other chunks"}
  end

  defp kind(a, b) do
    case {backend(a), backend(b)} do
      {"elixir_erl", "elixir_erl"} -> :elixir
      {"erl_abstract_code", "erl_abstract_code"} -> :erlang
      _ -> :other
    end
  end

  # The `Dbgi` backend's name, `{debug_info_v1, Backend, _}`, read from the
  # first bytes of the term alone (inflated a bounded step at most when the
  # term is compressed): the rest, the module's whole debug info, is never
  # decoded.
  defp backend(chunks) do
    with {_, bytes} <- List.keyfind(chunks, "Dbgi", 0),
         {:ok, <<104, 3, rest::binary>>} <- term_head(bytes),
         {:ok, "debug_info_v1", rest} <- atom_name(rest),
         {:ok, backend, _rest} <- atom_name(rest) do
      backend
    else
      _ -> nil
    end
  end

  defp term_head(<<131, 80, _size::32, compressed::binary>>), do: inflate_head(compressed)
  defp term_head(<<131, rest::binary>>), do: {:ok, rest}
  defp term_head(_bytes), do: :error

  defp inflate_head(compressed) do
    z = :zlib.open()

    try do
      :ok = :zlib.inflateInit(z)
      {:ok, inflate_steps(z, :zlib.safeInflate(z, compressed), [], 8)}
    catch
      _, _ -> :error
    after
      :zlib.close(z)
    end
  end

  # `:zlib.safeInflate/2` returns after a small, bounded amount of output;
  # a few steps give the head, never the whole term.
  defp inflate_steps(z, {:continue, out}, acc, steps) when steps > 1 do
    acc = [acc | out]

    if IO.iodata_length(acc) >= @head_bytes,
      do: IO.iodata_to_binary(acc),
      else: inflate_steps(z, :zlib.safeInflate(z, []), acc, steps - 1)
  end

  defp inflate_steps(_z, {_status, out}, acc, _steps), do: IO.iodata_to_binary([acc | out])

  defp atom_name(<<119, len::8, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp atom_name(<<118, len::16, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp atom_name(<<115, len::8, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp atom_name(<<100, len::16, name::binary-size(len), rest::binary>>), do: {:ok, name, rest}
  defp atom_name(_bytes), do: :error

  defp allowed(:erlang), do: @erlang_chunks
  defp allowed(_kind), do: @elixir_chunks

  # An Erlang module's `FunT` that differs only in its funs' `old_uniq`
  # (the last of each entry's six words), the one value the md5 gives every
  # fun of the module: the same funs, in the same order, at the same labels,
  # indices and free variable counts.
  defp uniq_only?("FunT", :erlang, a, b) do
    with {_, normal} <- List.keyfind(a, "FunT", 0),
         {_, sibling} <- List.keyfind(b, "FunT", 0),
         {:ok, normal_funs} <- funs(normal),
         {:ok, sibling_funs} <- funs(sibling) do
      Enum.map(normal_funs, &elem(&1, 0)) == Enum.map(sibling_funs, &elem(&1, 0)) and
        length(Enum.uniq_by(sibling_funs, &elem(&1, 1))) <= 1
    else
      _ -> false
    end
  end

  defp uniq_only?(_id, _kind, _a, _b), do: false

  defp funs(<<count::32, table::binary>>) when byte_size(table) == count * 24,
    do: {:ok, for(<<keep::binary-size(20), uniq::32 <- table>>, do: {keep, uniq})}

  defp funs(_bytes), do: :error
end
