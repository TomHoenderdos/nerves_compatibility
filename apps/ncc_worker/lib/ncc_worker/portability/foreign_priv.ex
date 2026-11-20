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

  # The calls `File.mkdir_p!/1` makes (Elixir 1.17 to 1.20, judge revision
  # 21's `@mkdir_p` and `@type_probe`), and the frameless stats Task A6's
  # real-VM fixture found right after an accepted call on the same path
  # (none unless it shows them: spec 3.2, row F5).
  @mkdir_p_caller {"Elixir.File", "do_mkdir_p", 1}
  @type_probe_caller {"elixir_utils", "read_file_type", 2}
  @rm_rf_reads ~w(file:read_link_info/1 file:read_link_info/2)
  @frameless_stats []

  @type decision :: :pass | {:accept, map()} | :refuse_read | :refuse_write

  @doc """
  What the open gate makes of one file event (spec 3.2 and 3.5):
  `{:accept, item}` for a reviewed Kino.JS call, `:refuse_read` for any
  other read, listing or stat under kino's `priv/assets`, `:refuse_write`
  for any other write there, and `:pass` for everything else, which
  `NccWorker.Portability.Events` decides as before. Always `:pass` while
  the gate is closed.
  """
  @spec decide(map(), Context.t(), term()) :: decision()
  def decide(_event, %Context{foreign_priv: nil}, _owner), do: :pass

  def decide(
        %{"channel" => channel, "arg" => %{} = arg} = e,
        %Context{foreign_priv: gate} = ctx,
        owner
      )
      when channel in ["file_read", "file_write"] do
    real = Context.resolve(ctx, arg["path"], owner)
    from = if channel == "file_write", do: Context.resolve(ctx, arg["from"], owner)

    cond do
      # A copy or rename out of A: its target may be anywhere, so never split it.
      below_assets?(from, gate) ->
        :refuse_write

      below_assets?(real, gate) ->
        below(channel, e, gate, ctx, owner, real)

      on_path?(real, gate) and mkdir_p?(e, gate, ctx, owner) and owner_dirs(gate, owner) != [] ->
        {:accept, item("mkdir_p", nil, real, gate, e)}

      # A listing or stat of `A` itself is a read under `A` too (spec 3.5).
      channel == "file_read" and real == gate.assets ->
        :refuse_read

      true ->
        :pass
    end
  end

  def decide(_event, _ctx, _owner), do: :pass

  defp below("file_read", e, gate, ctx, owner, real) do
    {d, rest} = split(real, gate)

    cond do
      rest == [] and e["mfa"] in @rm_rf_reads and toolchain?(e) and
        frame?(e, gate.rule.rm_rf, ctx, owner) and
          writer_dir?(gate, owner, d) ->
        {:accept, item("rm_rf", d, real, gate, e)}

      rest == [] and mkdir_p?(e, gate, ctx, owner) and writer_dir?(gate, owner, d) ->
        {:accept, item("mkdir_p", d, real, gate, e)}

      frameless_stat?(e) and writer_dir?(gate, owner, d) ->
        {:accept, item("stat", d, real, gate, e)}

      true ->
        :refuse_read
    end
  end

  defp below("file_write", e, gate, ctx, owner, real) do
    {d, rest} = split(real, gate)
    hash = archive_hash(rest)

    cond do
      e["arg"]["from"] != nil or e["arg"]["ram"] == true ->
        :refuse_write

      rest == [] and e["mfa"] == "file:make_dir/1" and mkdir_p?(e, gate, ctx, owner) and
          writer_dir?(gate, owner, d) ->
        {:accept, item("mkdir_p", d, real, gate, e)}

      hash != nil and e["mfa"] == "file:open/2" and frame?(e, gate.rule.archive, ctx, owner) and
          writer_dir?(gate, owner, d) ->
        {:accept, Map.put(item("archive", d, real, gate, e), "hash", hash)}

      hash != nil and e["mfa"] == "prim_file:open/2" and e["user"] == nil and
          writer_dir?(gate, owner, d) ->
        {:accept, Map.put(item("stream", d, real, gate, e), "hash", hash)}

      true ->
        :refuse_write
    end
  end

  # Strictly below `A`: `{d, the segments below A/<d>}`.
  defp split(real, gate) do
    [d | rest] = real |> Path.split() |> Enum.drop(length(Path.split(gate.assets)))
    {d, rest}
  end

  defp below_assets?(real, gate),
    do: is_binary(real) and real != gate.assets and Context.under?(real, gate.assets)

  # `A` itself or a directory above it: what `File.mkdir_p!/1` walks.
  defp on_path?(real, gate),
    do:
      is_binary(real) and
        (real == gate.assets or real == "/" or Context.under?(gate.assets, real))

  defp archive_hash([file]) do
    case Regex.run(~r/\A([a-z2-7]{26})\.tar\.gz\z/, file) do
      [_, hash] -> hash
      _ -> nil
    end
  end

  defp archive_hash(_rest), do: nil

  defp mkdir_p?(e, gate, ctx, owner) do
    frame?(e, gate.rule.mkdir_p, ctx, owner) and toolchain?(e) and
      ((e["mfa"] == "file:make_dir/1" and caller?(e, @mkdir_p_caller)) or
         (e["mfa"] == "file:read_file_info/2" and caller?(e, @type_probe_caller)))
  end

  # The event's first user frame is exactly the rule's, and not in a mix.exs.
  defp frame?(%{"user" => %{} = user} = e, {module, function, arity, line}, ctx, owner) do
    user["module"] == module and user["function"] == function and user["arity"] == arity and
      user["line"] == line and Context.mix_exs(ctx, e, owner) == nil
  end

  defp frame?(_e, _frame, _ctx, _owner), do: false

  defp toolchain?(e), do: e["caller_kind"] == "toolchain"

  defp frameless_stat?(e), do: e["user"] == nil and Enum.member?(@frameless_stats, e["mfa"])

  defp caller?(%{"caller" => %{"module" => m, "function" => f, "arity" => a}}, {m, f, a}),
    do: true

  defp caller?(_e, _mfa), do: false

  defp owner_dirs(gate, owner) when is_binary(owner),
    do: gate.dirs |> Map.get(owner, MapSet.new()) |> MapSet.to_list()

  defp owner_dirs(_gate, _owner), do: []

  # `d` is one of W's own modules' directories, and not kino's unless W is kino.
  defp writer_dir?(gate, owner, d) when is_binary(owner) do
    MapSet.member?(Map.get(gate.dirs, owner, MapSet.new()), d) and
      (owner == gate.target or
         not MapSet.member?(Map.get(gate.dirs, gate.target, MapSet.new()), d))
  end

  defp writer_dir?(_gate, _owner, _d), do: false

  defp item(call, d, real, gate, e),
    do: %{
      "call" => call,
      "dir" => d,
      "path" => relative(real, gate.build),
      "ts" => e["ts"],
      "pid" => e["pid"]
    }

  # Relative to kino's build dir (`"."` for the dir itself), else the real
  # path: a probe above it.
  defp relative(real, build) do
    if Context.under?(real, build) do
      case real |> Path.split() |> Enum.drop(length(Path.split(build))) do
        [] -> "."
        parts -> Path.join(parts)
      end
    else
      real
    end
  end
end
