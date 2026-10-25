defmodule NccAgent.Caps do
  @moduledoc """
  Size caps on what the agent reads back from a worker container, which
  runs untrusted package code: `result.json`, each `out/logs/*.log`, and
  how much container output `runner.log` collects. Tests lower them with
  `Application.put_env(:ncc_agent, :caps, result_json_bytes: 10)`.
  """

  @defaults %{
    result_json_bytes: 8 * 1024 * 1024,
    log_bytes: 16 * 1024 * 1024,
    runner_log_bytes: 64 * 1024 * 1024
  }

  @type key :: :result_json_bytes | :log_bytes | :runner_log_bytes

  @spec get(key()) :: pos_integer()
  def get(key) do
    :ncc_agent
    |> Application.get_env(:caps, [])
    |> Keyword.get(key, Map.fetch!(@defaults, key))
  end
end
