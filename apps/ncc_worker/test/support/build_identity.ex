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

  With `consolidated: true`, a beam under `<app>/consolidated/` (a
  consolidated protocol, never a published file) may also differ in its
  `ExCk` chunk's bytes when it decodes to `===` terms: Mix consolidates
  protocols in parallel, so even two untraced compiles disagree on its map
  key order. A beam anywhere else never gets that exception.
  """

  @doc """
  The differences between two `path => bytes` maps, `[]` when they are
  identical in the sense above. Each entry is `{path, reason}`. Option:
  `consolidated:` (default `false`), see the moduledoc.
  """
  @spec differences(%{String.t() => binary()}, %{String.t() => binary()}, keyword()) ::
          [{String.t(), term()}]
  def differences(a, b, opts \\ []) do
    paths = Enum.sort(Enum.uniq(Map.keys(a) ++ Map.keys(b)))

    for path <- paths,
        reason = file_difference(path, Map.get(a, path), Map.get(b, path), opts),
        reason != nil,
        do: {path, reason}
  end

  @doc "Why `a` and `b`, two versions of the file `path`, differ, or `nil`."
  @spec file_difference(String.t(), binary() | nil, binary() | nil, keyword()) :: term()
  def file_difference(path, a, b, opts \\ [])
  def file_difference(_path, a, a, _opts), do: nil
  def file_difference(_path, nil, _b, _opts), do: :only_in_second
  def file_difference(_path, _a, nil, _opts), do: :only_in_first

  def file_difference(path, a, b, opts) do
    if String.ends_with?(path, ".beam"),
      do: beam_difference(a, b, decoded(path, opts)),
      else: :bytes_differ
  end

  # The chunks compared as decoded terms for the beam at `path`.
  defp decoded(path, opts) do
    if Keyword.get(opts, :consolidated, false) and consolidated?(path),
      do: [~c"Dbgi", ~c"ExCk"],
      else: [~c"Dbgi"]
  end

  defp consolidated?(path), do: match?([_app, "consolidated", _file], Path.split(path))

  @doc """
  Why two beams differ chunk by chunk, or `nil` (see the moduledoc).
  `decoded` names the chunks compared as decoded terms (default `Dbgi` only).
  """
  @spec beam_difference(binary(), binary(), [charlist()]) :: term()
  def beam_difference(a, b, decoded \\ [~c"Dbgi"]) do
    with {:ok, ca} <- chunks(a),
         {:ok, cb} <- chunks(b) do
      chunk_difference(ca, cb, decoded)
    end
  end

  defp chunks(beam) do
    case :beam_lib.all_chunks(beam) do
      {:ok, _module, chunks} -> {:ok, chunks}
      {:error, :beam_lib, reason} -> {:not_a_beam, reason}
    end
  end

  defp chunk_difference(ca, cb, decoded) do
    ids = Enum.map(ca, &elem(&1, 0))

    if ids == Enum.map(cb, &elem(&1, 0)) do
      Enum.find_value(Enum.zip(ca, cb), fn {{id, x}, {_id, y}} -> chunk(id, x, y, decoded) end)
    else
      {:chunk_ids_differ, ids, Enum.map(cb, &elem(&1, 0))}
    end
  end

  defp chunk(_id, x, x, _decoded), do: nil

  defp chunk(id, x, y, decoded) do
    if id in decoded and decode(x) === decode(y),
      do: nil,
      else: {:chunk_differs, List.to_string(id)}
  end

  defp decode(payload) do
    :erlang.binary_to_term(payload)
  rescue
    ArgumentError -> {:undecodable, payload}
  end
end
