defmodule NccWorker do
  @moduledoc """
  NCC Worker: Container-side program that evaluates one Hex package
  against a matrix of Nerves systems.

  The worker:
  - Runs inside a Docker container (does not run Docker itself)
  - Reads input.json from mounted directory
  - Creates a Nerves project and adds the package
  - Builds firmware for each Nerves system
  - Enforces Hex-only dependency policy
  - Writes result.json and per-system logs to output directory

  Exit codes:
  - 0: Worker completed and wrote result.json
  - 10: Worker internal failure (setup/runtime/IO)
  - 11: Policy violation (git/path deps detected)
  """

  @type exit_code :: 0 | 10 | 11

  @doc """
  Exit codes returned by the worker:
  - 0: Success (worker completed and wrote result.json)
  - 10: Worker internal failure
  - 11: Policy violation
  """
  @spec exit_code_name(exit_code()) :: String.t()
  def exit_code_name(0), do: "success"
  def exit_code_name(10), do: "worker_error"
  def exit_code_name(11), do: "policy_violation"
end
