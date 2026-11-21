defmodule NccWorker.FirmwareJudge do
  @moduledoc """
  The classes of a firmware target's trace verdict that withhold its files
  (stream S8 phase 2). `NccWorker.FirmwareInputs` traces each passing
  target's compile with the toolchain judge in target mode
  (`NccWorker.Portability.target_inputs/3`), whose rules are the toolchain
  build's own. A refusal in one of these channels withholds the target as
  it withholds a toolchain build, because `mix firmware` ran the same code:

    * `"probe"`: a compile-time probe (`NccWorker.Portability.Probes`): of a
      module the trace loaded, of an OTP application or a dependency outside
      the closure, of whether a module is loaded, a call into a module the
      trace loaded, a list of the loaded modules;
    * `"plugins_hooks"`: a rebar3 rule (`NccWorker.Portability.Rebar`): its
      plugins, hooks, `rebar.config.script` or `platform_define`, or a
      plugin release that is not the reviewed one;
    * `"taint"`: a closure dependency's taint whose own reason is one of
      those two.

  Any other refusal (a host read, native code, a baked build path) is no
  class: on the target such a read may be the target's own, and it is not a
  decided firmware channel.
  """

  @taint "closure dependency observed the host: "
  @probe [
    "compile-time probe",
    "compile-time call into a module the trace loaded",
    "compile-time list of the loaded modules",
    "unreadable probe event"
  ]
  @plugins_hooks ["rebar3 build ", "rebar3 plugin"]

  @doc """
  The classes `texts` (a verdict's `texts/1`) hit, sorted and unique: any of
  `"plugins_hooks"`, `"probe"`, `"taint"`.
  """
  @spec classes([String.t()]) :: [String.t()]
  def classes(texts) do
    texts
    |> Enum.flat_map(&class/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp class(text) do
    case String.split(text, @taint, parts: 2) do
      [_, rest] -> if own(inner(rest)) == [], do: [], else: ["taint"]
      [_] -> own(text)
    end
  end

  defp own(text) do
    cond do
      Enum.any?(@plugins_hooks, &String.contains?(text, &1)) -> ["plugins_hooks"]
      Enum.any?(@probe, &String.contains?(text, &1)) -> ["probe"]
      true -> []
    end
  end

  # "<app> (<its own reason>)": everything in the outer parentheses.
  defp inner(rest) do
    case String.split(rest, " (", parts: 2) do
      [_app, inner] -> inner
      [_app] -> ""
    end
  end

  @doc """
  Every text of a verdict that may name a refusal: its `reason`, its
  `refusal_texts` (a target verdict's every refusal, uncut:
  `NccWorker.Portability.target_inputs/3`), each `observations["refusals"]`
  reason, each `observations["problems"]` entry (where a could-not-judge
  verdict names its causes), each `observations["rebar"]` refusal (the
  package's and each dependency's rebar3 rule, which an earlier reason
  hides) and each `observations["taint"]` entry, as the R3 refusal names
  it. Anything that is not a string is left out, and each text is kept
  once.
  """
  @spec texts(map()) :: [String.t()]
  def texts(verdict) do
    obs = Map.get(verdict, :observations)
    obs = if is_map(obs), do: obs, else: %{}

    refusals = for %{"reason" => r} <- list(obs["refusals"]), is_binary(r), do: r
    problems = for p <- list(obs["problems"]), is_binary(p), do: p

    taint =
      for {app, why} <- map(obs["taint"]),
          is_binary(app) and is_binary(why),
          do: "#{@taint}#{app} (#{why})"

    uncut = for t <- list(Map.get(verdict, :refusal_texts)), is_binary(t), do: t
    rebar = for {_app, r} <- map(obs["rebar"]), is_binary(r), do: r

    (Enum.filter([Map.get(verdict, :reason)], &is_binary/1) ++
       uncut ++ refusals ++ problems ++ rebar ++ taint)
    |> Enum.uniq()
  end

  defp list(value) when is_list(value), do: value
  defp list(_value), do: []

  defp map(value) when is_map(value), do: Enum.sort(value)
  defp map(_value), do: []
end
