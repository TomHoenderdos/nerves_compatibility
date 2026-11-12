defmodule NccWorker.TargetDepsGet do
  @moduledoc """
  Runs one build target's `mix deps.get`, retrying it when Hex's registry
  answer does not know a version the run's own lock names.

  The lock was resolved minutes earlier in the same run, from the same
  registry, so "Unknown package version X in lockfile" on a target says the
  registry answer this target got is older than the one the lock came from,
  not that anything is wrong with the package. hex.pm serves registry entries
  through a CDN whose cache nodes can keep an entry from before a release for
  hours after it: when nerves_system_qemu_aarch64 0.5.2 came out, single
  targets of unrelated packages failed this way for about a day, and each was
  recorded as a failure of the package. Hex refetches every locked package's
  entry on each `deps.get`, and a later request usually reaches a node with
  the current one, so a retry after a pause is enough.

  Every other failure returns at once, as before.
  """

  @default_waits [20_000, 60_000]

  @stale ~r/Unknown package version \S+ \S+ in lockfile/

  @doc """
  Calls `runner` (returning `{output, exit_code}`) until it exits 0, or until
  a failure that is not `stale?/1`, or until `:waits` (milliseconds slept
  before each retry, default 20 s then 60 s) runs out.
  """
  @spec run((-> {String.t(), non_neg_integer()}), keyword()) ::
          :ok | {:error, pos_integer()}
  def run(runner, opts \\ []) do
    sleep = Keyword.get(opts, :sleep, &Process.sleep/1)
    attempt(runner, Keyword.get(opts, :waits, @default_waits), sleep)
  end

  defp attempt(runner, waits, sleep) do
    case runner.() do
      {_output, 0} -> :ok
      {output, code} -> retry(stale?(output), code, runner, waits, sleep)
    end
  end

  defp retry(true, _code, runner, [wait | rest], sleep) do
    sleep.(wait)
    attempt(runner, rest, sleep)
  end

  defp retry(_stale?, code, _runner, _waits, _sleep), do: {:error, code}

  @doc "Whether `output` carries Hex's unknown-version-in-lockfile error."
  @spec stale?(String.t()) :: boolean()
  def stale?(output), do: Regex.match?(@stale, output)
end
