defmodule Portal.BuildCache.L2.Bounded do
  @moduledoc """
  Runs a function over untrusted input in a process of its own, bounded in
  time and in heap, so that what the input makes it do cannot take the
  caller, or the node, down with it.

  The process is spawned unlinked and monitored: a crash, a heap kill or a
  timeout kill reaches the caller only as a `:DOWN` message, never as an exit
  signal. Its heap is capped with the `:max_heap_size` process flag
  (`kill: true`), which is what stops `:erl_tar.table/2` from building a
  member list of millions of entries out of a header flood. That cap counts
  the process's own heap only: binaries over 64 bytes live off-heap and are
  not counted, so a single huge member is not stopped here. That is the job
  of `Portal.BuildCache.L2.Tarball`'s streaming gzip pre-scan, which runs
  before this and refuses a tarball that decompresses past
  `Tarball.max_extracted_bytes/0`.

  A raise, throw or exit inside the function becomes
  `{:error, {:exception, message}}` rather than a crash.
  """

  @default_max_heap_bytes 512 * 1024 * 1024

  @spec default_max_heap_bytes() :: pos_integer()
  def default_max_heap_bytes, do: @default_max_heap_bytes

  @doc """
  Runs `fun` in a fresh unlinked process. Options: `:timeout_ms` (required)
  and `:max_heap_bytes` (default 512 MiB).
  """
  @spec run((-> term()), keyword()) ::
          {:ok, term()}
          | {:error, :timeout | :killed | {:exit, term()} | {:exception, String.t()}}
  def run(fun, opts) when is_function(fun, 0) do
    timeout = max(Keyword.fetch!(opts, :timeout_ms), 0)

    heap_words =
      div(
        Keyword.get(opts, :max_heap_bytes, @default_max_heap_bytes),
        :erlang.system_info(:wordsize)
      )

    parent = self()
    ref = make_ref()

    {pid, monitor} =
      spawn_monitor(fn ->
        Process.flag(:max_heap_size, %{size: heap_words, kill: true, error_logger: true})
        send(parent, {ref, guarded(fun)})
      end)

    receive do
      {^ref, result} ->
        Process.demonitor(monitor, [:flush])
        result

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :killed}

      {:DOWN, ^monitor, :process, ^pid, reason} ->
        {:error, {:exit, reason}}
    after
      timeout ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        # The result may have been sent just before the kill.
        receive do
          {^ref, _late} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp guarded(fun) do
    {:ok, fun.()}
  catch
    kind, reason ->
      {:error, {:exception, Exception.format_banner(kind, reason) |> String.slice(0, 500)}}
  end
end
