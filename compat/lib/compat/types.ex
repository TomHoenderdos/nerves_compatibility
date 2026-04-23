defmodule Compat.Types do
  @moduledoc """
  Shared type definitions for the compatibility tracker.
  """

  @type status :: :pass | :fail | :error | :skipped | :unknown

  @doc """
  Parses a status string into the status type.
  """
  @spec parse_status(String.t()) :: status()
  def parse_status("pass"), do: :pass
  def parse_status("fail"), do: :fail
  def parse_status("error"), do: :error
  def parse_status("skipped"), do: :skipped
  def parse_status("unknown"), do: :unknown
  def parse_status(_), do: :unknown

  @doc """
  Converts a status atom to a string.
  """
  @spec status_to_string(status()) :: String.t()
  def status_to_string(:pass), do: "pass"
  def status_to_string(:fail), do: "fail"
  def status_to_string(:error), do: "error"
  def status_to_string(:skipped), do: "skipped"
  def status_to_string(:unknown), do: "unknown"
end
