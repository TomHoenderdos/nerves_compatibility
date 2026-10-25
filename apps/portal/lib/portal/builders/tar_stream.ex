defmodule Portal.Builders.TarStream do
  @moduledoc """
  A streaming reader for the plain ustar archives the agent uploads: regular
  files only, names in the 100-byte field. Each entry's bytes are handed to
  the caller as they arrive, so a 512 MiB batch never lives in memory and a
  bad entry can be discarded the moment its hash is known. Anything that is
  not a plain file entry refuses the archive.

  `callbacks` is `%{start: (name, size -> {:ok, acc} | {:skip, reason}),
  data: (acc, binary -> acc), finish: (acc -> result)}`. `finish/1` returns
  the results in archive order, `{:skipped, name, reason}` for a skipped
  entry.
  """

  @block 512

  defstruct callbacks: nil,
            buffer: <<>>,
            mode: :header,
            entry: nil,
            remaining: 0,
            padding: 0,
            results: [],
            done: false

  @type t :: %__MODULE__{}

  @spec new(map()) :: t()
  def new(callbacks), do: %__MODULE__{callbacks: callbacks}

  @spec feed(t(), binary()) :: {:ok, t()} | {:error, term()}
  def feed(%__MODULE__{done: true} = state, _chunk), do: {:ok, state}
  def feed(%__MODULE__{} = state, chunk), do: step(%{state | buffer: state.buffer <> chunk})

  @spec finish(t()) :: {:ok, [any()]} | {:error, :truncated}
  def finish(%__MODULE__{done: true, results: results}), do: {:ok, Enum.reverse(results)}

  def finish(%__MODULE__{mode: :header, buffer: buffer, results: results})
      when byte_size(buffer) < @block,
      do: {:ok, Enum.reverse(results)}

  def finish(_state), do: {:error, :truncated}

  @doc "The accumulator of the entry being read, if one is open (for cleanup on error)."
  @spec pending(t()) :: any() | nil
  def pending(%__MODULE__{mode: :data, entry: {_name, acc}}), do: acc
  def pending(_state), do: nil

  defp step(%{mode: :header, buffer: buffer} = state) when byte_size(buffer) >= @block do
    <<header::binary-size(@block), rest::binary>> = buffer

    if header == <<0::size(@block * 8)>> do
      {:ok, %{state | buffer: <<>>, done: true}}
    else
      with {:ok, name, size, typeflag, prefix} <- parse(header),
           :ok <- plain_file(typeflag, prefix, name) do
        open_entry(state, rest, name, size)
      end
    end
  end

  defp step(%{mode: :header} = state), do: {:ok, state}

  defp step(%{mode: mode, remaining: 0, padding: padding, buffer: buffer} = state)
       when mode in [:data, :skip] do
    if byte_size(buffer) >= padding do
      <<_pad::binary-size(^padding), rest::binary>> = buffer
      results = finish_entry(state)
      step(%{state | buffer: rest, mode: :header, entry: nil, padding: 0, results: results})
    else
      {:ok, state}
    end
  end

  defp step(%{mode: mode, buffer: buffer, remaining: remaining} = state)
       when mode in [:data, :skip] and byte_size(buffer) > 0 do
    take = min(remaining, byte_size(buffer))
    <<data::binary-size(^take), rest::binary>> = buffer

    entry =
      case {mode, state.entry} do
        {:data, {name, acc}} -> {name, state.callbacks.data.(acc, data)}
        {:skip, entry} -> entry
      end

    step(%{state | buffer: rest, remaining: remaining - take, entry: entry})
  end

  defp step(state), do: {:ok, state}

  defp open_entry(state, rest, name, size) do
    padding = rem(@block - rem(size, @block), @block)

    {mode, entry} =
      case state.callbacks.start.(name, size) do
        {:ok, acc} -> {:data, {name, acc}}
        {:skip, reason} -> {:skip, {name, reason}}
      end

    step(%{state | buffer: rest, mode: mode, entry: entry, remaining: size, padding: padding})
  end

  defp finish_entry(%{mode: :data, entry: {_name, acc}, results: results} = state),
    do: [state.callbacks.finish.(acc) | results]

  defp finish_entry(%{mode: :skip, entry: {name, reason}, results: results}),
    do: [{:skipped, name, reason} | results]

  defp parse(
         <<name::binary-size(100), _mode::binary-size(8), _uid::binary-size(8),
           _gid::binary-size(8), size::binary-size(12), _mtime::binary-size(12),
           _chksum::binary-size(8), typeflag::binary-size(1), _link::binary-size(100),
           _magic::binary-size(6), _version::binary-size(2), _uname::binary-size(32),
           _gname::binary-size(32), _dev::binary-size(16), prefix::binary-size(155),
           _pad::binary-size(12)>>
       ) do
    with {:ok, size} <- octal(size) do
      {:ok, cstring(name), size, typeflag, cstring(prefix)}
    end
  end

  defp plain_file(flag, "", _name) when flag in ["0", <<0>>], do: :ok
  defp plain_file(_flag, _prefix, name), do: {:error, {:unsupported_entry, name}}

  defp cstring(bin), do: bin |> :binary.split(<<0>>) |> List.first()

  defp octal(field) do
    case field |> cstring() |> String.trim() |> Integer.parse(8) do
      {n, ""} when n >= 0 -> {:ok, n}
      _ -> {:error, :bad_size}
    end
  end
end
