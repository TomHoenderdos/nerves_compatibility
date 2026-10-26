defmodule NccAgent.Caps do
  @moduledoc """
  Size caps on what the agent reads back from a worker container, which
  runs untrusted package code: `result.json`, each `out/logs/*.log` (at most
  `max_logs` of them, `logs_total_bytes` together, measured before anything
  is read or compressed), and how much container output `runner.log`
  collects; and on what `complete` sends: the last `runner_log_tail_bytes`
  of `runner.log` (the portal reads no more) and a `logs.tar.gz` of at most
  `logs_tarball_bytes` (under the portal's 64 MiB `max_logs_bytes`). The
  caps on the archived files come from the claim (`upload`), not from here.
  Tests lower them with `Application.put_env(:ncc_agent, :caps, result_json_bytes: 10)`.
  """

  @defaults %{
    result_json_bytes: 8 * 1024 * 1024,
    log_bytes: 16 * 1024 * 1024,
    max_logs: 64,
    logs_total_bytes: 64 * 1024 * 1024,
    runner_log_bytes: 64 * 1024 * 1024,
    runner_log_tail_bytes: 1024 * 1024,
    logs_tarball_bytes: 48 * 1024 * 1024
  }

  @type key ::
          :result_json_bytes
          | :log_bytes
          | :max_logs
          | :logs_total_bytes
          | :runner_log_bytes
          | :runner_log_tail_bytes
          | :logs_tarball_bytes

  @spec get(key()) :: pos_integer()
  def get(key) do
    :ncc_agent
    |> Application.get_env(:caps, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end
end
