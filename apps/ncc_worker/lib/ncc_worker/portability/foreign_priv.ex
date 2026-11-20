defmodule NccWorker.Portability.ForeignPriv do
  @moduledoc """
  Foreign priv builds (foreign priv spec, 2026-11-20): a package's compile
  writing Kino.JS asset archives into kino's build `priv`, the one
  reviewed pattern (`Compatibility.ForeignPriv`).

  `gate/3` decides whether the exception is open for a judged compile. All
  of these must hold, else every rule is the judge's as before:

    1. the job asked for it (`foreign_priv: true`, from
       `NCC_INPUT.judge.foreign_priv`) and the judge is not in target mode
       (no `target:`: a firmware target's or a host-native build's trace);
    2. the package is not kino, kino is in its closure, built by `mix` and
       not natively;
    3. kino's build `priv` is a directory of its own
       (`Context.target_priv/2`);
    4. `lib/kino/js.ex` in kino's verified Hex tarball is reviewed
       (`Compatibility.ForeignPriv.reviewed_tarball/2`), and
       `Elixir.Kino.JS` is listed by kino's built `.app` and by no other
       closure app's.

  `decide/3` (Task A5) and `settle/2` (Task A6) apply the rule.
  """

  alias Compatibility.ForeignPriv, as: Rules
  alias NccWorker.Portability.Context

  @kino_js "Elixir.Kino.JS"

  @type gate :: %{
          rule: Rules.rule(),
          target: String.t(),
          build: String.t(),
          assets: String.t(),
          dirs: %{String.t() => MapSet.t(String.t())}
        }

  @doc "The open gate for this compile, else nil (see the moduledoc)."
  @spec gate(Context.t(), MapSet.t(String.t()), keyword()) :: gate() | nil
  def gate(%Context{} = ctx, scope, opts) do
    target = Rules.target()

    with true <- Keyword.get(opts, :foreign_priv) == true,
         nil <- Keyword.get(opts, :target),
         true <- is_binary(ctx.package) and ctx.package != target,
         true <- MapSet.member?(scope, target),
         %{native?: false, manager: "mix", build: build} when is_binary(build) <-
           Map.get(ctx.deps, target),
         priv when is_binary(priv) <- Context.target_priv(ctx, target),
         %{} = rule <- reviewed(ctx, target),
         true <- only_kino_lists_kino_js?(ctx, scope, target) do
      %{
        rule: rule,
        target: target,
        build: Context.realpath(build),
        assets: Path.join(priv, "assets"),
        dirs: Map.new(scope, &{&1, dirs(ctx, &1)})
      }
    else
      _ -> nil
    end
  end

  @doc """
  `trace_stats["foreign_priv"]`: nil (absent) unless the job sent the flag,
  then `"on"` when the gate opened and `"off"` when it did not.
  """
  @spec stat(keyword(), gate() | nil) :: String.t() | nil
  def stat(opts, gate) do
    cond do
      Keyword.get(opts, :foreign_priv) != true -> nil
      gate -> "on"
      true -> "off"
    end
  end

  defp reviewed(%Context{hex: {_home, releases}} = ctx, target) when is_map(releases) do
    with %{version: version} <- Map.get(releases, target),
         tarball when is_binary(tarball) <- Context.tarball(ctx, target) do
      Rules.reviewed_tarball(version, tarball)
    end
  end

  defp reviewed(_ctx, _target), do: nil

  defp only_kino_lists_kino_js?(ctx, scope, target) do
    owners =
      for app <- scope,
          Context.dep?(ctx, app),
          MapSet.member?(Context.app_modules(ctx, app), @kino_js),
          do: app

    owners == [target]
  end

  # Dirs(W): D(M) over the Elixir modules W's built .app lists.
  defp dirs(ctx, app) do
    for m <- Context.app_modules(ctx, app),
        d = Rules.dir_name(m),
        d != nil,
        into: MapSet.new(),
        do: d
  end
end
