defmodule BeamScanner do
  @moduledoc """
  Entry point for scanning an OTP release directory and summarizing
  potentially risky runtime capabilities and protocol details found in
  the contained BEAM files.
  """

  @doc """
  Scan a directory that contains `ebin` and `priv` (an OTP release layout)
  and return a summary of potentially risky capabilities.
  """
  @spec analyze(Path.t()) :: BeamScanner.Analyzer.result()
  def analyze(path) do
    BeamScanner.Analyzer.analyze(path)
  end
end
