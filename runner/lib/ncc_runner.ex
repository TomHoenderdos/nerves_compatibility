defmodule NccRunner do
  @moduledoc """
  NCC Runner: Host-side program that runs NCC worker in Docker containers.

  The runner:
  - Takes a job payload (job.json)
  - Launches a Docker container with the worker image pinned by digest
  - Manages working directories and mounts
  - Captures logs and exit codes
  - Validates outputs
  - Records deterministic metadata
  """

  @type exit_code :: 0 | 20 | 21

  @doc """
  Exit codes returned by the runner:
  - 0: Success (worker produced outputs, even if builds failed)
  - 20: Runner error (bad input, docker unavailable, outputs missing, etc.)
  - 21: Worker container exited with non-zero code
  """
  @spec exit_code_name(exit_code()) :: String.t()
  def exit_code_name(0), do: "success"
  def exit_code_name(20), do: "runner_error"
  def exit_code_name(21), do: "worker_failed"
end
