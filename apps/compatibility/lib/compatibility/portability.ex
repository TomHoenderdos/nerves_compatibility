defmodule Compatibility.Portability do
  @moduledoc """
  The reasons the worker's compile-time trace (`NccWorker.Portability`) gives
  when it refuses a precompiled build, shared with the portal, which keys the
  withdrawal of earlier `pure_elixir` publications on them
  (`Portal.Precompiled.PureElixirWithdrawal`).

  `could_not_judge/0` is not a refusal of the package: the trace itself did
  not finish (a crash, a cap, a missing sentinel), so nothing is withdrawn
  because of it.
  """

  @refusal_prefixes [
    "compile-time host read: ",
    "compile-time host read in mix.exs: ",
    "compile-time write outside ebin: ",
    "compile-time tracing or system flag: ",
    "calls natively built dependency at compile time: ",
    "bakes the build path: ",
    "closure dependency observed the host: ",
    "rebar3 build "
  ]

  @could_not_judge "portability could not be judged"

  @doc "Every prefix a trace refusal starts with."
  @spec refusal_prefixes() :: [String.t()]
  def refusal_prefixes, do: @refusal_prefixes

  @doc "The reason for a build whose trace could not be used."
  @spec could_not_judge() :: String.t()
  def could_not_judge, do: @could_not_judge

  @doc "Whether `reason` is a trace refusal (and not a rule 1 reason or could-not-judge)."
  @spec refusal?(term()) :: boolean()
  def refusal?(reason) when is_binary(reason),
    do: Enum.any?(@refusal_prefixes, &String.starts_with?(reason, &1))

  def refusal?(_reason), do: false
end
