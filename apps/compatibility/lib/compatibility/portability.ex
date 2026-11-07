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

  # R1 (the package's own compile observed the host; R4's `mix.exs` slice
  # judges R1 events) and R2 (a baked build path): the refusals that
  # withdraw an earlier publication. R3 taint, a call into a natively built
  # dependency and the rebar3 rules do not: they speak of a dependency or of
  # the trace's own coverage, not of the package's own compile.
  @withdrawing_prefixes [
    "compile-time host read: ",
    "compile-time host read in mix.exs: ",
    "compile-time write outside ebin: ",
    "compile-time tracing or system flag: ",
    "bakes the build path: "
  ]

  @could_not_judge "portability could not be judged"

  @doc "Every prefix a trace refusal starts with."
  @spec refusal_prefixes() :: [String.t()]
  def refusal_prefixes, do: @refusal_prefixes

  @doc "The R1 and R2 refusal prefixes, the subset that withdraws an earlier publication."
  @spec withdrawing_prefixes() :: [String.t()]
  def withdrawing_prefixes, do: @withdrawing_prefixes

  @doc "Whether `reason` is an R1 or R2 refusal, one that withdraws an earlier publication."
  @spec withdraws?(term()) :: boolean()
  def withdraws?(reason) when is_binary(reason),
    do: Enum.any?(@withdrawing_prefixes, &String.starts_with?(reason, &1))

  def withdraws?(_reason), do: false

  @doc "The reason for a build whose trace could not be used."
  @spec could_not_judge() :: String.t()
  def could_not_judge, do: @could_not_judge

  @doc "Whether `reason` is a trace refusal (and not a rule 1 reason or could-not-judge)."
  @spec refusal?(term()) :: boolean()
  def refusal?(reason) when is_binary(reason),
    do: Enum.any?(@refusal_prefixes, &String.starts_with?(reason, &1))

  def refusal?(_reason), do: false
end
