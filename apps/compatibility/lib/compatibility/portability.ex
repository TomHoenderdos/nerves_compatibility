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
    "compile-time native library load: ",
    "bakes the build path: ",
    "closure dependency observed the host: ",
    "rebar3 build ",
    "compile-time config read: ",
    "compile-time Elixir patch dependence: ",
    "manager mismatch: ",
    "dependency tree differs from its tarball: "
  ]

  # R1 (the package's own compile observed the host; R4's `mix.exs` slice
  # judges R1 events) and R2 (a baked build path): the refusals that
  # withdraw an earlier publication. The Elixir-patch rule is R1 too (the
  # package's own compile read the Elixir version in a way that differs
  # between patches). R3 taint, a call into a natively built
  # dependency and the rebar3 rules do not: they speak of a dependency or of
  # the trace's own coverage, not of the package's own compile. A native
  # library load (`NccWorker.Portability.MappedLibs`) is a refusal but, until
  # that is decided on its own, withdraws nothing either.
  @withdrawing_prefixes [
    "compile-time host read: ",
    "compile-time host read in mix.exs: ",
    "compile-time write outside ebin: ",
    "compile-time tracing or system flag: ",
    "compile-time Elixir patch dependence: ",
    "bakes the build path: "
  ]

  # The oldest judge revision (`NccWorker.Portability.judge_revision/1`)
  # whose refusals withdraw: 3, the first that records compile-time env
  # reads as inputs instead of refusing them. A row an older judge refused
  # may be one the current judge publishes, so it waits for its rebuild.
  @withdrawal_judge_revision 3

  @could_not_judge "portability could not be judged"
  @manager_mismatch "manager mismatch: "
  @tree_differs "dependency tree differs from its tarball: "

  @doc "Every prefix a trace refusal starts with."
  @spec refusal_prefixes() :: [String.t()]
  def refusal_prefixes, do: @refusal_prefixes

  @doc "The R1 and R2 refusal prefixes, the subset that withdraws an earlier publication."
  @spec withdrawing_prefixes() :: [String.t()]
  def withdrawing_prefixes, do: @withdrawing_prefixes

  @doc """
  The oldest judge revision whose refusals withdraw an earlier publication:
  a row judged before it is no evidence until rebuilt.
  """
  @spec withdrawal_judge_revision() :: pos_integer()
  def withdrawal_judge_revision, do: @withdrawal_judge_revision

  @doc "Whether `reason` is an R1 or R2 refusal, one that withdraws an earlier publication."
  @spec withdraws?(term()) :: boolean()
  def withdraws?(reason) when is_binary(reason),
    do: Enum.any?(@withdrawing_prefixes, &String.starts_with?(reason, &1))

  def withdraws?(_reason), do: false

  @doc "The reason for a build whose trace could not be used."
  @spec could_not_judge() :: String.t()
  def could_not_judge, do: @could_not_judge

  @doc """
  The prefix of a refusal of a dependency rule 2 took off the native list
  because Mix runs mix or rebar3 for it (precompiled judge refinements,
  item 1), when the trace says another manager built it. A refusal that
  withdraws nothing: it speaks of a dependency.
  """
  @spec manager_mismatch() :: String.t()
  def manager_mismatch, do: @manager_mismatch

  @doc """
  The prefix of a refusal of a closure dependency whose source tree, before
  the traced compile, was not its verified Hex tarball's (precompiled judge
  refinements, item 5e). A refusal that withdraws nothing: it speaks of the
  build's inputs, not of the package's own compile.
  """
  @spec tree_differs() :: String.t()
  def tree_differs, do: @tree_differs

  @doc "Whether `reason` is a trace refusal (and not a rule 1 reason or could-not-judge)."
  @spec refusal?(term()) :: boolean()
  def refusal?(reason) when is_binary(reason),
    do: Enum.any?(@refusal_prefixes, &String.starts_with?(reason, &1))

  def refusal?(_reason), do: false
end
