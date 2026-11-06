defmodule NccWorker.Portability.MappedLibs do
  @moduledoc """
  The loaded-library check of the compile-time trace. `erlang:load_nif/2`
  is not call-traceable on OTP 28 and 29 (no global or local pattern fires
  for it), so a package that loads a NIF at compile time leaves no event.
  The tracer instead records every shared object mapped into the VM
  (`/proc/self/maps`): once at start, before anything compiles, and again at
  the end (the Mix VM's `end` line) or after every compile and flush (a
  rebar3 child VM's `libs` lines).

  `check/3`: a library that appears in a later snapshot but not in the start
  snapshot refuses, `compile-time native library load: <path>`, unless
  `allowed?` holds for it (the OTP root, the Elixir install, a native
  closure dependency's own build or source dir; the judge passes it).
  Libraries already mapped at start are the VM's own (libc, libcrypto,
  crypto.so, the loader, ...): the snapshot replaces an allowlist.

  Without `/proc/self/maps` (any non-Linux host) the tracer writes
  `nif_check: "unavailable"` and the check is `:unavailable`, which the
  judge makes "portability could not be judged". The one exception is
  `NCC_TRACE_ALLOW_NO_NIF_CHECK=1` in the judging VM's environment
  (`waived?/1`): only the ncc_worker test helper sets it, on macOS, so the
  fixture suites can run there. The worker never sets it, and the traced
  compile cannot reach it (the judge runs in the worker, not in the traced
  VM).

  A library loaded and unloaded between two snapshots is not seen; a NIF
  stays loaded while its module is, and a failed `load_nif` maps nothing.
  """

  @waiver "NCC_TRACE_ALLOW_NO_NIF_CHECK"
  @refusal "compile-time native library load: "

  @type snapshot :: map() | nil
  @type result :: {:ok, [String.t()]} | {:refuse, String.t()} | :unavailable

  @doc """
  The libraries `later` snapshots add to `start`: `{:ok, allowed}` (sorted)
  when every one is allowed, `{:refuse, reason}` for the first that is not,
  `:unavailable` when any snapshot is missing or has no list, or there is no
  later snapshot at all.
  """
  @spec check(snapshot(), [snapshot()], (String.t() -> boolean())) :: result()
  def check(start, later, allowed?) do
    with {:ok, before} <- libs(start),
         [_ | _] <- later,
         {:ok, lists} <- all_libs(later) do
      added = lists |> Enum.concat() |> Enum.uniq() |> Kernel.--(before) |> Enum.sort()

      case Enum.reject(added, allowed?) do
        [] -> {:ok, added}
        [first | _] -> {:refuse, @refusal <> first}
      end
    else
      _ -> :unavailable
    end
  end

  @doc "Whether `env` (default: this VM's) waives an unavailable check."
  @spec waived?(map()) :: boolean()
  def waived?(env \\ System.get_env()), do: Map.get(env, @waiver) == "1"

  defp all_libs(snapshots) do
    Enum.reduce_while(snapshots, {:ok, []}, fn snapshot, {:ok, acc} ->
      case libs(snapshot) do
        {:ok, list} -> {:cont, {:ok, [list | acc]}}
        :error -> {:halt, :error}
      end
    end)
  end

  defp libs(%{"nif_check" => "ok", "mapped_libs" => list}) when is_list(list) do
    if Enum.all?(list, &is_binary/1), do: {:ok, list}, else: :error
  end

  defp libs(_snapshot), do: :error
end
