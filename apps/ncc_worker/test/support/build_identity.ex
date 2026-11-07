defmodule NccWorker.BuildIdentity do
  @moduledoc """
  Compares two builds' published files (`path => bytes` maps), the identity
  a traced build must have with an untraced `mix compile` of the same
  project.

  Every file is byte-equal, with one exception: a beam's `Dbgi` chunk only
  has to decode to `===` terms. Elixir writes it with `term_to_binary/2`
  without `:deterministic`, and since OTP 26 a small map's encoded key order
  is the creation order of its atom keys in the compiling VM, which no two
  VMs with different histories share. Beams are compared chunk by chunk:
  the same chunk IDs in the same order, every chunk other than `Dbgi`
  byte-equal. Nothing is stripped and no other chunk is decoded.
  """

  @doc """
  The differences between two `path => bytes` maps, `[]` when they are
  identical in the sense above. Each entry is `{path, reason}`.
  """
  @spec differences(%{String.t() => binary()}, %{String.t() => binary()}) ::
          [{String.t(), term()}]
  def differences(a, b) do
    paths = Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b)))

    for path <- paths,
        reason = file_difference(path, Map.get(a, path), Map.get(b, path)),
        reason != nil,
        do: {path, reason}
  end

  @doc "Why `a` and `b`, two versions of the file `path`, differ, or `nil`."
  @spec file_difference(String.t(), binary() | nil, binary() | nil) :: term()
  def file_difference(_path, a, a), do: nil
  def file_difference(_path, nil, _b), do: :only_in_second
  def file_difference(_path, _a, nil), do: :only_in_first

  def file_difference(path, a, b) do
    if String.ends_with?(path, ".beam"), do: beam_difference(a, b), else: :bytes_differ
  end

  @doc "Why two beams differ chunk by chunk, or `nil` (see the moduledoc)."
  @spec beam_difference(binary(), binary()) :: term()
  def beam_difference(a, b) do
    with {:ok, ca} <- chunks(a),
         {:ok, cb} <- chunks(b) do
      chunk_difference(ca, cb)
    end
  end

  defp chunks(beam) do
    case :beam_lib.all_chunks(beam) do
      {:ok, _module, chunks} -> {:ok, chunks}
      {:error, :beam_lib, reason} -> {:not_a_beam, reason}
    end
  end

  defp chunk_difference(ca, cb) do
    ids = Enum.map(ca, &elem(&1, 0))

    if ids == Enum.map(cb, &elem(&1, 0)) do
      Enum.find_value(Enum.zip(ca, cb), fn {{id, x}, {_id, y}} -> chunk(id, x, y) end)
    else
      {:chunk_ids_differ, ids, Enum.map(cb, &elem(&1, 0))}
    end
  end

  defp chunk(_id, x, x), do: nil

  defp chunk(~c"Dbgi", x, y),
    do: if(decode(x) === decode(y), do: nil, else: {:chunk_differs, "Dbgi"})

  defp chunk(id, _x, _y), do: {:chunk_differs, List.to_string(id)}

  defp decode(payload) do
    :erlang.binary_to_term(payload)
  rescue
    ArgumentError -> {:undecodable, payload}
  end
end
