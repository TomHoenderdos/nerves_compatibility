defmodule Compatibility.RecordedValue do
  @moduledoc """
  Whether a manifest-recorded `compile_env` value is plain, small ETF
  (precompiled judge refinements, Task I: defence in depth with client
  0.3.2).

  The client decodes a recorded value with
  `:erlang.binary_to_term(bin, [:safe])`
  (`precompiled`'s `Match.recorded_equals?/2`). A malicious package can set
  any term as its own application env at compile time before that read is
  recorded, and `[:safe]` alone does not stop every shape of it:

    * compressed ETF inflates before `[:safe]` runs, a memory bomb on every
      client at install;
    * `[:safe]` admits a fun of an already-loaded module, and does nothing
      about a pid, a port or a reference, none of which a client can ever
      usefully compare against its own config.

  So the worker and the portal both run this check before recording or
  re-serving a value, and the client runs the identical rule before
  matching one (see `PRECOMPILED_API.md`).

  A recorded value, after base64url decode, is acceptable only when:

    1. it does not start with the compressed ETF marker (`<<131, 80>>`);
    2. its decoded byte size is at most 65,536 bytes;
    3. `:erlang.binary_to_term(bin, [:safe])` decodes it without raising;
    4. the decoded term holds no fun, pid, port or reference at any depth:
       lists (including an improper tail), tuples and maps (both keys and
       values) are all walked.

  This module creates no atoms of its own; `[:safe]` already refuses to.
  The 64 KiB cap bounds the walk, so no separate depth limit is needed.
  """

  @max_bytes 65_536

  @doc "Whether `base64` is an acceptable recorded `compile_env` value."
  @spec acceptable?(term()) :: boolean()
  def acceptable?(base64) when is_binary(base64) do
    case Base.url_decode64(base64, padding: false) do
      {:ok, bin} -> acceptable_binary?(bin)
      :error -> false
    end
  end

  def acceptable?(_base64), do: false

  defp acceptable_binary?(<<131, 80, _rest::binary>>), do: false

  defp acceptable_binary?(bin) when byte_size(bin) <= @max_bytes do
    case safe_decode(bin) do
      {:ok, term} -> plain?(term)
      :error -> false
    end
  end

  defp acceptable_binary?(_bin), do: false

  # Sobelow flags every binary_to_term call, `:safe` included, because
  # `:safe` alone still admits a fun of an already-loaded module. That gap
  # is exactly why `plain?/1` below walks the result for funs (and pids,
  # ports, references) before this module calls anything acceptable.
  # sobelow_skip ["Misc.BinToTerm"]
  defp safe_decode(bin) do
    {:ok, :erlang.binary_to_term(bin, [:safe])}
  rescue
    _ -> :error
  end

  defp plain?([head | tail]), do: plain?(head) and plain?(tail)
  defp plain?([]), do: true
  defp plain?(term) when is_function(term), do: false
  defp plain?(term) when is_pid(term), do: false
  defp plain?(term) when is_port(term), do: false
  defp plain?(term) when is_reference(term), do: false
  defp plain?(term) when is_tuple(term), do: term |> Tuple.to_list() |> Enum.all?(&plain?/1)

  defp plain?(term) when is_map(term),
    do: Enum.all?(term, fn {k, v} -> plain?(k) and plain?(v) end)

  defp plain?(_term), do: true
end
