defmodule NccWorker.Portability.ElixirVersion do
  @moduledoc """
  The Elixir-version rule of the compile-time trace (precompiled portability
  spec, R1 step 4, "Elixir version"). A client takes a build made on Elixir
  x.y.N on any x.y.M with M >= N, so compile-time code may read the Elixir
  version only in a way that gives the same answer for every such patch.

  Per window (the package's, a closure dependency's, or outside every
  window), among the `elixir_version` observations package or dependency
  code makes (not the toolchain's own, `first_kind` "toolchain"; a missing
  `first_kind` counts as the package's):

    * `System.build_info/0` refuses: it carries the build's revision and
      date, not only the version;
    * every `Version.match?/2` or `Version.compare/2` call one of whose
      arguments is exactly the built version must give the same result for
      the built version and every x.y.P final release from the built patch
      up to x.y.99 (and at least the next patch); `Version.match?/3` (its
      options are not traced) never does, and neither does a call whose
      other argument is not a literal string or does not parse;
    * there must be at least as many such calls as `System.version/0` reads,
      so a read used any other way (a string compare, `String.split/2`, a
      comparison against a `Version` struct the tracer cannot render)
      refuses.

  A comparison made on a line of a dependency's `mix.exs` that
  `NccWorker.Portability.MixExsSlice.direct_version_line?/3` accepts (the
  observation's `"series"`) must also give the same result for every final
  patch x.y.0 to x.y.99: its result picks the project's configuration, so a
  requirement that cuts inside the minor refuses even above the built
  patch.

  A refusal, `compile-time Elixir patch dependence: ...`, belongs to its
  window: in the package's it refuses the package, in a dependency's it
  taints that dependency (R3). Reads to judge with no usable Elixir version
  in the trace's start line are a problem ("could not be judged"), never a
  pass.
  """

  @prefix "compile-time Elixir patch dependence: "
  @judged ["Version.match?/2", "Version.compare/2"]
  @last_patch 99
  @no_version "no Elixir version in the trace"

  @type result :: %{refusals: [{term(), {:refuse, String.t()}}], problems: [String.t()]}

  @doc """
  The refusals and problems of the `elixir_version` observations in
  `decided` (`{owner, decision}`, already limited to the package's closure)
  for a trace made on Elixir `built`.
  """
  @spec judge([{term(), term()}], String.t() | nil) :: result()
  def judge(decided, built) do
    decided
    |> Enum.flat_map(fn
      {owner, {:observe, "elixir_version", item}} when is_map(item) ->
        if item["first_kind"] == "toolchain", do: [], else: [{owner, item}]

      _other ->
        []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> judge_windows(built, versions(built))
  end

  # `System.build_info/0` refuses whatever the built version is, so a
  # window with such a read refuses even when the version is unknown; every
  # other window then cannot be judged.
  defp judge_windows(by_owner, built, versions) do
    results =
      for {owner, items} <- Enum.sort(by_owner), do: {owner, window(items, built, versions)}

    %{
      refusals: for({owner, {:refuse, reason}} <- results, do: {owner, {:refuse, reason}}),
      problems: if(Enum.any?(results, &match?({_, :unjudged}, &1)), do: [@no_version], else: [])
    }
  end

  defp window(items, built, versions) do
    case Enum.find(items, &(&1["mfa"] == "System.build_info/0")) do
      nil -> compared(items, built, versions)
      info -> {:refuse, @prefix <> "System.build_info/0" <> where(info)}
    end
  end

  defp compared(_items, _built, :error), do: :unjudged

  defp compared(items, built, {:ok, versions}) do
    reads = Enum.filter(items, &(&1["mfa"] == "System.version/0"))
    calls = Enum.filter(items, &compares_built?(&1, built))

    cond do
      bad = Enum.find(calls, &(not invariant?(&1, built, versions))) ->
        {:refuse, @prefix <> bad["mfa"] <> " " <> args(bad) <> where(bad)}

      length(reads) > length(calls) ->
        {:refuse,
         @prefix <>
           "System.version/0 read without a patch-invariant Version comparison" <>
           where(hd(reads))}

      true ->
        :ok
    end
  end

  defp compares_built?(item, built), do: built in [arg(item, "left"), arg(item, "right")]

  defp invariant?(%{"mfa" => mfa} = item, built, versions) when mfa in @judged do
    left = arg(item, "left")
    right = arg(item, "right")
    versions = if item["series"] == true, do: series(built, versions), else: versions
    results = for v <- versions, do: call(mfa, swap(left, built, v), swap(right, built, v))
    Enum.all?(results, &match?({:ok, _}, &1)) and length(Enum.uniq(results)) == 1
  end

  defp invariant?(_item, _built, _versions), do: false

  defp swap(arg, built, version) when arg == built, do: version
  defp swap(arg, _built, _version), do: arg

  # A nil (non-literal) argument raises too: never invariant.
  defp call(mfa, a, b) do
    {:ok, apply_version(mfa, a, b)}
  rescue
    _ -> :error
  end

  defp apply_version("Version.match?/2", a, b), do: Version.match?(a, b)
  defp apply_version("Version.compare/2", a, b), do: Version.compare(a, b)

  # The built version itself and every final patch of its minor from its
  # own patch on (a pre-release build is also served to the final release),
  # always including at least the next patch.
  defp versions(built) when is_binary(built) do
    case Version.parse(built) do
      {:ok, %Version{major: major, minor: minor, patch: patch}} ->
        finals = for p <- patch..max(@last_patch, patch + 1)//1, do: "#{major}.#{minor}.#{p}"
        {:ok, Enum.uniq([built | finals])}

      :error ->
        :error
    end
  end

  defp versions(_built), do: :error

  # A call from a dependency's `mix.exs` (`"series"`, `Events` marks it):
  # the same answer for every final patch of the built minor, from x.y.0,
  # as well as for the versions above. The toolchain key is the minor, so a
  # requirement that cuts inside it refuses, wherever the built patch is.
  defp series(built, versions) do
    {:ok, %Version{major: major, minor: minor}} = Version.parse(built)
    Enum.uniq(versions ++ for(p <- 0..@last_patch, do: "#{major}.#{minor}.#{p}"))
  end

  defp arg(%{"arg" => %{} = arg}, side), do: unquoted(arg[side])
  defp arg(_item, _side), do: nil

  defp unquoted("\"" <> rest) when byte_size(rest) > 0 do
    if String.ends_with?(rest, "\""), do: binary_part(rest, 0, byte_size(rest) - 1)
  end

  defp unquoted(_value), do: nil

  defp args(item), do: "(#{shown(item, "left")}, #{shown(item, "right")})"

  defp shown(item, side), do: arg(item, side) || "(not a literal string)"

  defp where(%{"module" => module, "file" => file, "line" => line}) when is_binary(module),
    do: " in #{display(module)} (#{file}:#{line})"

  defp where(_item), do: ""

  defp display("Elixir." <> name), do: name
  defp display(name), do: name
end
