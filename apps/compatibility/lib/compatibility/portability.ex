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
    "compile-time priv write not reproducible: ",
    "manager mismatch: ",
    "dependency tree differs from its tarball: ",
    "foreign priv write refused: ",
    "compile-time read of kino's asset archives: ",
    "native build not set apart: ",
    "compile-time probe of an OTP application outside the closure: ",
    "compile-time probe of a dependency outside the closure: ",
    "compile-time probe of whether a module is loaded: "
  ]

  # R1 (the package's own compile observed the host; R4's `mix.exs` slice
  # judges R1 events) and R2 (a baked build path): the refusals that
  # withdraw an earlier publication. The Elixir-patch rule is R1 too (the
  # package's own compile read the Elixir version in a way that differs
  # between patches), and so is a write into the package's own `priv` that
  # a second build did not reproduce. R3 taint, a call into a natively built
  # dependency and the rebar3 rules do not: they speak of a dependency or of
  # the trace's own coverage, not of the package's own compile. A native
  # library load (`NccWorker.Portability.MappedLibs`) is a refusal but, until
  # that is decided on its own, withdraws nothing either. R1 also covers a
  # read of kino's asset archives, whose tar times are the builder's clock,
  # and a probe of an OTP application off the code path, whose answer is
  # the builder's pruned path's.
  @withdrawing_prefixes [
    "compile-time host read: ",
    "compile-time host read in mix.exs: ",
    "compile-time write outside ebin: ",
    "compile-time tracing or system flag: ",
    "compile-time Elixir patch dependence: ",
    "compile-time priv write not reproducible: ",
    "bakes the build path: ",
    "compile-time read of kino's asset archives: ",
    "compile-time probe of an OTP application outside the closure: ",
    "compile-time probe of a dependency outside the closure: ",
    "compile-time probe of whether a module is loaded: "
  ]

  # The oldest judge revision (`NccWorker.Portability.judge_revision/1`)
  # whose refusals withdraw: 3, the first that records compile-time env
  # reads as inputs instead of refusing them. A row an older judge refused
  # may be one the current judge publishes, so it waits for its rebuild.
  @withdrawal_judge_revision 3

  @could_not_judge "portability could not be judged"

  # The texts of a compile-time probe the judge could not judge
  # (`NccWorker.Portability.Probes`): the worker prefixes each with the
  # window it was in, `"<app>: "` or `"outside: "` (S8 review R5).
  @probe_texts [
    "compile-time probe",
    "compile-time call into a module the trace loaded",
    "compile-time list of the loaded modules",
    "unreadable probe event"
  ]
  @owned_probe ~r/\A[a-z][a-z0-9_]*: (?=(?:#{Enum.map_join(@probe_texts, "|", &Regex.escape/1)}))/
  @transient ~r/\A \(transient \d+ times\)\z/

  # A trace that broke shows that first and every other problem because of
  # it ("no end line", "no stats line", a window never closed, a dependency
  # with no digest): the break is the cause. Matched anywhere in a problem,
  # so a child VM's ("child trace of x: trace collector died: killed")
  # counts too.
  @trace_breaks [
    "trace collector died",
    "trace watcher died",
    "the trace files exceed the report's read budget",
    "tracer refused to start",
    "trace overflowed"
  ]

  # The traced compile or the judge itself failed.
  @run_failures [
    "tracer: ",
    "traced compile exited ",
    "traced compile ended ",
    "judge failed: ",
    "not a trace report",
    "after the traced compile: ",
    "processes left running "
  ]

  # Exception, tracer and crash messages can quote a value the compile
  # handled: only an atom or a tuple's tag is kept, or the words before the
  # first value. A child VM's problem is its own, after its wrapper.
  @value_after [
    "judge failed: ",
    "tracer: ",
    "not a trace report: ",
    "second build failed: ",
    "trace collector died: ",
    "trace watcher died: "
  ]
  @child ~r/\A(child trace of [^:\s]+: )(.*)\z/su

  # An absolute path, or one under `~`, from its first `/` (or `~/`) to the
  # first quote, bracket, comma or semicolon, a colon before a digit or a
  # space (a line number, a message), or the end: spaces included, so a
  # directory with spaces in its name goes whole.
  @path ~r/(?<![\w.~-])~?\/(?:[^"'()\[\]{}<>,;:]|:(?![\d\s]|\z))*/u
  # The same, up to the first white space as well: a compiler error goes on
  # after the path it names ("git_hooks: /work/proj/deps/git_hooks is not
  # inside a git working tree.").
  @word_path ~r/(?<![\w.~-])~?\/(?:[^\s"'()\[\]{}<>,;:]|:(?![\d\s]|\z))*/u
  # Line and paragraph separators, controls and format characters (bidi
  # overrides included).
  @breaks ~r/[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]+/u

  # Bytes, not characters: one character can carry thousands of combining
  # marks.
  @max_cause 200
  @manager_mismatch "manager mismatch: "
  @tree_differs "dependency tree differs from its tarball: "
  @priv_not_reproduced "compile-time priv write not reproducible: "
  @foreign_priv_refused "foreign priv write refused: "
  @foreign_priv_read "compile-time read of kino's asset archives: "
  @native_side "native build not set apart: "
  @otp_probe "compile-time probe of an OTP application outside the closure: "
  @dependency_probe "compile-time probe of a dependency outside the closure: "
  @loaded_probe "compile-time probe of whether a module is loaded: "

  @doc """
  Whether `text` is a compile-time probe's text, its owner prefix (when the
  worker gave it one) aside.
  """
  @spec probe_text?(term()) :: boolean()
  def probe_text?(text) when is_binary(text),
    do: Enum.any?(@probe_texts, &String.contains?(text, &1))

  def probe_text?(_text), do: false

  @doc "A probe problem without the owner prefix the worker gives it; any other text as it is."
  @spec unowned(String.t()) :: String.t()
  def unowned(text) when is_binary(text), do: String.replace(text, @owned_probe, "")

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

  @doc "Whether `reason` is a could-not-judge reason, with or without its cause."
  @spec could_not_judge?(term()) :: boolean()
  def could_not_judge?(reason) when is_binary(reason),
    do: String.starts_with?(reason, @could_not_judge)

  def could_not_judge?(_reason), do: false

  @doc """
  `reason` naming its cause when it is the bare could-not-judge reason
  (`could_not_judge/0`, or the portal's `"... (transient N times)"` of it):
  `"portability could not be judged (<cause>)"`, the suffix kept. Any other
  reason is returned as it is.

  The cause is one of `problems` (a build's
  `compile_observations.problems`, in the judge's order): the first that
  says the trace itself broke (its collector died, it overflowed, it was
  over the report's read budget), else the first that says the traced
  compile or the judge failed, else the first. It is made safe to store
  and show: one line; every absolute path and every path under `~` cut out
  whole, spaces and all (`…`); of an exception, tracer or crash message
  only an atom, a tuple's tag or the words before any value it quotes; and
  at most #{@max_cause} bytes. A problem that is the bare reason itself
  names nothing; with no usable problem the reason stays bare.
  """
  @spec with_cause(term(), term()) :: term()
  def with_cause(@could_not_judge <> rest = reason, problems) do
    if rest == "" or Regex.match?(@transient, rest) do
      case cause(problems) do
        nil -> reason
        cause -> "#{@could_not_judge} (#{cause})#{rest}"
      end
    else
      reason
    end
  end

  def with_cause(reason, _problems), do: reason

  @doc "The cause `with_cause/2` named in `reason`, or nil when it named none."
  @spec cause_of(term()) :: String.t() | nil
  def cause_of(@could_not_judge <> " (" <> rest) do
    rest = String.replace(rest, ~r/\) \(transient \d+ times\)\z/, ")")

    if String.ends_with?(rest, ")") and not Regex.match?(~r/\Atransient \d+ times\)\z/, rest),
      do: String.slice(rest, 0..-2//1)
  end

  def cause_of(_reason), do: nil

  @doc """
  `reason`, a failed host compile's (`"compile failed: ..."` ending in
  `"exited with code N"`), naming the compiler error `error` gives (a
  build's `compile_observations.compile_error`, the first error line of the
  compile's log): `"<reason> (<error>)"`. Made safe to store and show the
  way `with_cause/2` makes a cause: one line, every absolute path and every
  path under `~` cut out up to the first white space (`…`), at most
  #{@max_cause} bytes; the value
  an error quotes is kept, since it is what names the error. A code of 128
  or more is a signal (`Portal.Catalog`'s killed-compile rule matches those
  reasons, which stay as they are), and a compile that ran out of time has
  no error of its own. Any other reason, or an `error` that is not text or
  cleans to nothing, leaves `reason` as it is.
  """
  @spec with_compile_error(term(), term()) :: term()
  def with_compile_error("compile failed: " <> _ = reason, error) do
    with [_, code] <- Regex.run(~r/exited with code (\d{1,3})\z/, reason),
         true <- String.to_integer(code) in 1..127,
         error when is_binary(error) and error != "" <- compile_error(error) do
      "#{reason} (#{error})"
    else
      _ -> reason
    end
  end

  def with_compile_error(reason, _error), do: reason

  @doc "The compiler error `with_compile_error/2` named in `reason`, or nil when it named none."
  @spec compile_error_of(term()) :: String.t() | nil
  def compile_error_of("compile failed: " <> _ = reason) do
    case Regex.run(~r/exited with code \d{1,3} \((.+)\)\z/su, reason) do
      [_, error] -> error
      nil -> nil
    end
  end

  def compile_error_of(_reason), do: nil

  defp compile_error(error) when is_binary(error) do
    if String.valid?(error) do
      error
      |> String.replace(@breaks, " ")
      |> String.replace(@word_path, "…")
      |> String.replace(~r/\s+/u, " ")
      |> String.trim()
      |> bounded()
    end
  end

  defp compile_error(_error), do: nil

  defp cause(problems) when is_list(problems) do
    problems = for p <- problems, is_binary(p), p = clean(p), p != "", do: p

    (Enum.find(problems, &trace_break?/1) || Enum.find(problems, &run_failure?/1) ||
       List.first(problems))
    |> bounded()
  end

  defp cause(_problems), do: nil

  defp trace_break?(problem), do: Enum.any?(@trace_breaks, &String.contains?(problem, &1))
  defp run_failure?(problem), do: Enum.any?(@run_failures, &String.starts_with?(problem, &1))

  # A problem that is itself a could-not-judge ("portability could not be
  # judged (dependency tree changed ...)") contributes what it wraps, and
  # the bare reason nothing.
  defp clean(problem) do
    if String.valid?(problem) do
      problem
      |> unowned()
      |> String.replace(@breaks, " ")
      |> unwrap()
      |> without_value()
      |> String.replace(@path, &cut_path/1)
      |> String.trim()
    else
      ""
    end
  end

  # The path goes; a space it swallowed before what follows stays.
  defp cut_path(path), do: if(String.ends_with?(path, " "), do: "… ", else: "…")

  defp unwrap(@could_not_judge), do: ""

  defp unwrap(@could_not_judge <> " (" <> rest) do
    if String.ends_with?(rest, ")"), do: String.slice(rest, 0..-2//1), else: rest
  end

  defp unwrap(problem), do: problem

  defp without_value(problem) do
    case {Regex.run(@child, problem), Enum.find(@value_after, &String.starts_with?(problem, &1))} do
      {[_, wrapper, inner], _} ->
        wrapper <> without_value(inner)

      {nil, nil} ->
        problem

      {nil, prefix} ->
        String.trim_trailing(prefix <> value_free(String.replace_prefix(problem, prefix, "")))
    end
  end

  # A bare atom (`killed`), an atom (`:timeout`) or a tuple's tag
  # (`{:install_failed, ...}`, `{badarg, ...}`) is kept; anything else up to
  # its first value (a quote, a bracket, a map, a number, an `=`).
  defp value_free(rest) do
    cond do
      Regex.match?(~r/\A[a-z]\w*\z/u, rest) ->
        rest

      tag = Regex.run(~r/\A(?:\{\s*)?(:?[a-z]\w*)/u, rest, capture: :all_but_first) ->
        if String.starts_with?(rest, ["{", ":"]),
          do: hd(tag),
          else: words(rest)

      true ->
        words(rest)
    end
  end

  defp words(rest), do: rest |> String.split(~r/[:\[{(<"'%#~=]|\d/u, parts: 2) |> hd()

  defp bounded(nil), do: nil

  # Whole code points up to the byte limit, the ellipsis included.
  defp bounded(cause) when byte_size(cause) <= @max_cause, do: cause

  defp bounded(cause) do
    budget = @max_cause - byte_size("…")

    cause
    |> String.codepoints()
    |> Enum.reduce_while({[], 0}, fn cp, {acc, used} ->
      if used + byte_size(cp) <= budget,
        do: {:cont, {[cp | acc], used + byte_size(cp)}},
        else: {:halt, {acc, used}}
    end)
    |> elem(0)
    |> Enum.reverse()
    |> IO.iodata_to_binary()
    |> Kernel.<>("…")
  end

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

  @doc """
  The prefix of a closure dependency's taint when its window ran the
  reviewed native build tool (`NCC_INPUT.judge.native_side`) and its beams
  could not be shown to be its own sources' alone: its source tree after
  the compile, a beam compiled from elsewhere, an evaluated checksum file
  that is not a literal map, or a manager other than Mix. A refusal that
  withdraws nothing: it speaks of a dependency.
  """
  @spec native_side() :: String.t()
  def native_side, do: @native_side

  @doc """
  The prefix of a refusal of a package whose own compile wrote into its own
  build `priv`, when a second traced build did not write the same bytes
  (judge revision 21, `NccWorker.Portability`). It withdraws: it speaks of
  what the package's own compile wrote, as the write refusal it replaces
  did.
  """
  @spec priv_not_reproduced() :: String.t()
  def priv_not_reproduced, do: @priv_not_reproduced

  @doc "A foreign priv archive the judge's settle refused (`NccWorker.Portability.ForeignPriv`)."
  @spec foreign_priv_refused() :: String.t()
  def foreign_priv_refused, do: @foreign_priv_refused

  @doc "A compile-time read, listing or stat under kino's `priv/assets` while the gate is open."
  @spec foreign_priv_read() :: String.t()
  def foreign_priv_read, do: @foreign_priv_read

  @doc """
  A compile-time probe of a module of an installed OTP or Elixir
  application off the prober's code path (`NccWorker.Portability.Probes`):
  Mix compiles a dependency on a code path pruned to its closure's
  applications, Mix.install does not, so the two compile different code
  (vega_lite 0.1.11's `Code.ensure_loaded?(:wx)`). It withdraws: it speaks
  of what the package's own compile did, as a host read does.
  """
  @spec otp_probe() :: String.t()
  def otp_probe, do: @otp_probe

  @doc """
  The same for a module or application that is no installed OTP or Elixir
  one (a Hex package's): under Mix.install every installed dependency is on
  the code path, and in a Mix project a module an earlier dependency's
  compile loaded stays loaded, so a probe of one the prober's closure does
  not hold answers differently there than on the builder. It withdraws.
  """
  @spec dependency_probe() :: String.t()
  def dependency_probe, do: @dependency_probe

  @doc """
  A compile-time probe of whether a module the prober's code path holds is
  loaded now, with no earlier ensure-load of it in the same process:
  whether it is depends on what other compile-time code in the same VM ran
  (a call into a module loads it), which the user's project decides, not
  the builder's. It withdraws.
  """
  @spec loaded_probe() :: String.t()
  def loaded_probe, do: @loaded_probe

  @doc "Whether `reason` is a trace refusal (and not a rule 1 reason or could-not-judge)."
  @spec refusal?(term()) :: boolean()
  def refusal?(reason) when is_binary(reason),
    do: Enum.any?(@refusal_prefixes, &String.starts_with?(reason, &1))

  def refusal?(_reason), do: false
end
