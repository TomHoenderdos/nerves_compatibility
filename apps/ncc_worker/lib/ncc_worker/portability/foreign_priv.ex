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

  import Bitwise

  alias Compatibility.ForeignPriv, as: Rules
  alias Compatibility.KinoAssets
  alias Compatibility.Portability, as: Reasons
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
      below_assets?(from, gate) -> :refuse_write
      below_assets?(real, gate) -> below(channel, e, gate, ctx, owner, real)
      true -> at_or_above(channel, e, gate, ctx, owner, real)
    end
  end

  def decide(_event, _ctx, _owner), do: :pass

  # `A` itself or a directory above it: only `File.mkdir_p!/1`'s walk there
  # is accepted, and a listing or stat of `A` itself is a read under `A` too
  # (spec 3.5).
  defp at_or_above(channel, e, gate, ctx, owner, real) do
    cond do
      on_path?(real, gate) and mkdir_p?(e, gate, ctx, owner) and owner_dirs(gate, owner) != [] ->
        {:accept, item("mkdir_p", nil, real, gate, e)}

      channel == "file_read" and real == gate.assets ->
        :refuse_read

      true ->
        :pass
    end
  end

  # Strictly below `A`: the reviewed call the event is, if any, accepted only
  # in a directory of the window's own (`writer_dir?/3`). The calls differ
  # by mfa and by whether they have a user frame, so no event is two of them.
  defp below("file_read", e, gate, ctx, owner, real) do
    {d, rest} = split(real, gate)

    case read_call(e, rest, gate, ctx, owner) do
      nil -> :refuse_read
      call -> accept(call, d, nil, {real, gate, e, owner}, :refuse_read)
    end
  end

  defp below("file_write", e, gate, ctx, owner, real) do
    {d, rest} = split(real, gate)
    hash = archive_hash(rest)

    case write_call(e, rest, hash, gate, ctx, owner) do
      nil -> :refuse_write
      call -> accept(call, d, hash, {real, gate, e, owner}, :refuse_write)
    end
  end

  defp accept(call, d, hash, {real, gate, e, owner}, refusal) do
    if writer_dir?(gate, owner, d) do
      item = item(call, d, real, gate, e)
      {:accept, if(hash, do: Map.put(item, "hash", hash), else: item)}
    else
      refusal
    end
  end

  defp read_call(e, rest, gate, ctx, owner) do
    cond do
      rest == [] and rm_rf?(e, gate, ctx, owner) -> "rm_rf"
      rest == [] and mkdir_p?(e, gate, ctx, owner) -> "mkdir_p"
      frameless_stat?(e) -> "stat"
      true -> nil
    end
  end

  # A copy, a rename or an in-memory file is never a reviewed call.
  defp write_call(%{"arg" => %{"from" => from}}, _rest, _hash, _gate, _ctx, _owner)
       when not is_nil(from),
       do: nil

  defp write_call(%{"arg" => %{"ram" => true}}, _rest, _hash, _gate, _ctx, _owner), do: nil

  defp write_call(%{"mfa" => "file:make_dir/1"} = e, [], _hash, gate, ctx, owner),
    do: if(mkdir_p?(e, gate, ctx, owner), do: "mkdir_p")

  defp write_call(%{"mfa" => "file:open/2"} = e, _rest, hash, gate, ctx, owner)
       when is_binary(hash),
       do: if(frame?(e, gate.rule.archive, ctx, owner), do: "archive")

  defp write_call(%{"mfa" => "prim_file:open/2"} = e, _rest, hash, _gate, _ctx, _owner)
       when is_binary(hash),
       do: if(e["user"] == nil, do: "stream")

  defp write_call(_e, _rest, _hash, _gate, _ctx, _owner), do: nil

  defp rm_rf?(e, gate, ctx, owner),
    do: e["mfa"] in @rm_rf_reads and toolchain?(e) and frame?(e, gate.rule.rm_rf, ctx, owner)

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

  @doc """
  Settles the accepted events once every event is decided (spec 3.3), in
  every window but kino's own, all or nothing per window:

    * F4: each `stream` follows an `archive` of the same path in the same
      window, at most one per archive; each `stat` follows an `rm_rf` or
      `mkdir_p` of its path there (kino's window too);
    * S6: at most 64 archives, 10 MiB in all (each inflating to at most
      64 MiB, `Compatibility.KinoAssets`);
    * S4: every beam in the window's ebin that exports `__assets_info__/0`
      has its directory among the archives, in every closure app but kino,
      calls or no calls;
    * per directory `d`: one `archive` for it in this window and no
      accepted event naming it in another (S1); `A/<d>` is a directory of
      its own holding exactly that archive, a regular file without an
      execute bit (S2); `d` is not kino's own (S3); exactly one module of
      the window's `.app` has `d` as its directory, and its beam exports
      `__assets_info__/0` (S4); `KinoAssets.verify/1` passes on the
      archive, that beam and the window's verified Hex tarball (S5).

  `decided` comes back with one refusal added in each window that does not
  settle; `entries` are the settled windows' `foreign_priv` entries and
  `exclude` their directories, relative to kino's build dir, for its built
  check. A closed gate settles nothing.
  """
  @spec settle([{term(), term()}], Context.t()) ::
          {[{term(), term()}], %{entries: %{String.t() => [map()]}, exclude: [String.t()]}}
  def settle(decided, %Context{foreign_priv: nil}), do: {decided, %{entries: %{}, exclude: []}}

  def settle(decided, %Context{foreign_priv: gate} = ctx) do
    accepted =
      for {owner, {:observe, "foreign_priv", item}} <- decided,
          is_binary(owner),
          do: {owner, item}

    unpaired = unpaired(accepted)

    # Every closure app is settled, not only those with accepted calls: an
    # app whose beams export `__assets_info__/0` with no archive the trace
    # saw written points at nothing (S4), whatever made it so.
    windows =
      accepted
      |> Enum.map(&elem(&1, 0))
      |> Kernel.++(Map.keys(gate.dirs))
      |> Enum.uniq()
      |> Enum.sort()

    {refusals, entries} =
      Enum.reduce(windows, {[], %{}}, fn window, {refusals, entries} ->
        result =
          cond do
            Map.has_key?(unpaired, window) -> {:refuse, unpaired[window]}
            window == gate.target -> {:ok, []}
            true -> settle_window(window, accepted, gate, ctx)
          end

        case result do
          {:ok, []} ->
            {refusals, entries}

          {:ok, list} ->
            {refusals, Map.put(entries, window, list)}

          {:refuse, why} ->
            {[{window, {:refuse, Reasons.foreign_priv_refused() <> why}} | refusals], entries}
        end
      end)

    exclude =
      for {_window, list} <- entries,
          %{"path" => path} <- list,
          into: [],
          do: path |> Path.dirname()

    {decided ++ Enum.reverse(refusals), %{entries: entries, exclude: Enum.sort(exclude)}}
  end

  # Spec 3.2 rows F4 and F5: per window, the first open or stat no accepted
  # call explains.
  defp unpaired(accepted) do
    accepted
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.flat_map(fn {window, items} ->
      case first_unpaired(Enum.sort_by(items, & &1["ts"])) do
        nil -> []
        why -> [{window, why}]
      end
    end)
    |> Map.new()
  end

  defp first_unpaired(items) do
    {why, _open} =
      Enum.reduce_while(items, {nil, %{}}, fn item, {nil, open} ->
        case item["call"] do
          "archive" ->
            {:cont, {nil, Map.update(open, item["path"], 1, &(&1 + 1))}}

          c when c in ["rm_rf", "mkdir_p"] ->
            {:cont, {nil, Map.put(open, {:seen, item["path"]}, true)}}

          "stream" ->
            stream_paired(item, open)

          "stat" ->
            stat_paired(item, open)

          _other ->
            {:cont, {nil, open}}
        end
      end)

    why
  end

  defp stat_paired(item, open) do
    if open[{:seen, item["path"]}],
      do: {:cont, {nil, open}},
      else: {:halt, {"a stat of kino #{item["path"]} no reviewed call made", open}}
  end

  defp stream_paired(item, open) do
    case Map.get(open, item["path"], 0) do
      0 -> {:halt, {"an open of kino #{item["path"]} no reviewed call made", open}}
      n -> {:cont, {nil, Map.put(open, item["path"], n - 1)}}
    end
  end

  defp settle_window(window, accepted, gate, ctx) do
    items = for {^window, item} <- accepted, do: item
    dirs = for(%{"call" => "archive", "dir" => d} <- items, do: d) |> Enum.uniq() |> Enum.sort()

    with :ok <- count_ok(dirs),
         :ok <- every_dir_archived(items, dirs),
         :ok <- every_asset_module(window, dirs, ctx),
         {:ok, entries} <- each_dir(dirs, &settle_dir(window, &1, items, accepted, gate, ctx)) do
      size_ok(entries)
    end
  end

  # S1 for a directory the window's accepted calls named (its `rm_rf` or
  # `mkdir_p`) but wrote no archive into.
  defp every_dir_archived(items, dirs) do
    case Enum.find(items, &(is_binary(&1["dir"]) and &1["dir"] not in dirs)) do
      nil -> :ok
      %{"dir" => d} -> {:refuse, "kino priv/assets/#{d}: no archive written"}
    end
  end

  defp count_ok(dirs) do
    if length(dirs) > Rules.max_entries(),
      do: {:refuse, "more than #{Rules.max_entries()} foreign priv files"},
      else: :ok
  end

  defp size_ok(entries) do
    if entries |> Enum.map(& &1["size"]) |> Enum.sum() > Rules.max_bytes(),
      do: {:refuse, "more than 10 MiB of foreign priv files"},
      else: {:ok, entries}
  end

  defp each_dir(dirs, fun) do
    Enum.reduce_while(dirs, {:ok, []}, fn d, {:ok, acc} ->
      case fun.(d) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:refuse, _} = refusal -> {:halt, refusal}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      refusal -> refusal
    end
  end

  defp settle_dir(window, d, items, accepted, gate, ctx) do
    with :ok <- one_writer(window, d, items, accepted),
         {:ok, name} <- only_archive(gate, d, items),
         :ok <- not_kinos(gate, d),
         {:ok, module, beam} <- writer_module(window, d, ctx),
         {:ok, bytes} <- read_archive(Path.join([gate.assets, d, name])),
         {:ok, proof} <- proof(window, d, name, bytes, module, beam, ctx) do
      {:ok,
       %{
         "app" => gate.target,
         "path" => Rules.archive_path(d, proof.hash),
         "sha256" => :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower),
         "size" => byte_size(bytes),
         "mode" => Rules.mode(),
         "module" => module,
         "assets_path" => proof.assets_path
       }}
    else
      {:refuse, :two_writers} -> {:refuse, "two writers of kino priv/assets/#{d}"}
      {:refuse, why} -> {:refuse, "kino priv/assets/#{d}: #{why}"}
    end
  end

  # S1.
  defp one_writer(window, d, items, accepted) do
    archives = Enum.count(items, &(&1["call"] == "archive" and &1["dir"] == d))
    elsewhere = Enum.any?(accepted, fn {owner, item} -> owner != window and item["dir"] == d end)
    if archives == 1 and not elsewhere, do: :ok, else: {:refuse, :two_writers}
  end

  # S2: lstat, never following a link.
  # sobelow_skip ["Traversal.FileModule"]
  defp only_archive(gate, d, items) do
    dir = Path.join(gate.assets, d)
    %{"path" => path} = Enum.find(items, &(&1["call"] == "archive" and &1["dir"] == d))
    name = Path.basename(path)

    with {:ok, %File.Stat{type: :directory}} <- File.lstat(gate.assets),
         {:ok, %File.Stat{type: :directory}} <- File.lstat(dir),
         {:ok, entries} <- File.ls(dir) do
      only_entry(dir, name, entries)
    else
      _ -> {:refuse, "is not a directory of its own"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp only_entry(dir, name, [name]) do
    case File.lstat(Path.join(dir, name)) do
      {:ok, %File.Stat{type: :regular, mode: mode}} when (mode &&& 0o111) == 0 -> {:ok, name}
      _ -> {:refuse, "its archive is not a regular file without an execute bit"}
    end
  end

  defp only_entry(_dir, _name, _entries), do: {:refuse, "holds more than its archive"}

  # S3.
  defp not_kinos(gate, d) do
    if MapSet.member?(Map.get(gate.dirs, gate.target, MapSet.new()), d),
      do: {:refuse, "is kino's own"},
      else: :ok
  end

  # S4, first half: the one module of the window whose directory `d` is.
  defp writer_module(window, d, ctx) do
    with [module] <- for(m <- Context.app_modules(ctx, window), Rules.dir_name(m) == d, do: m),
         ebin when is_binary(ebin) <- Context.ebin(ctx, window),
         {:ok, beam} <- read_beam(Path.join(ebin, module <> ".beam")),
         true <- exports_assets?(beam) do
      {:ok, module, beam}
    else
      [] -> {:refuse, "no module of #{window} packs it"}
      [_ | _] -> {:refuse, "two modules of #{window} pack it"}
      _ -> {:refuse, "its module's beam exports no __assets_info__/0"}
    end
  end

  # S4, second half.
  # sobelow_skip ["Traversal.FileModule"]
  defp every_asset_module(window, dirs, ctx) do
    ebin = Context.ebin(ctx, window)

    paths = if is_binary(ebin), do: ebin |> Path.join("*.beam") |> Path.wildcard(), else: []

    paths
    |> Enum.sort()
    |> Enum.find_value(:ok, &asset_module_problem(&1, dirs))
  end

  # nil when the beam at `path` packs no assets or its directory has an
  # archive; else the refusal. A beam that cannot be read is no proof
  # either way.
  defp asset_module_problem(path, dirs) do
    module = Path.basename(path, ".beam")

    case read_beam(path) do
      {:ok, beam} ->
        if exports_assets?(beam) and Rules.dir_name(module) not in dirs,
          do: {:refuse, "#{module} has assets but no archive"}

      {:refuse, _why} ->
        {:refuse, "#{module}'s beam cannot be read"}
    end
  end

  defp exports_assets?(beam) do
    case :beam_lib.chunks(beam, [:exports]) do
      {:ok, {_module, [exports: exports]}} -> {:__assets_info__, 0} in exports
      _ -> false
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_beam(path) do
    case File.read(path) do
      {:ok, bytes} -> {:ok, bytes}
      {:error, _} -> {:refuse, "its module's beam cannot be read"}
    end
  end

  # sobelow_skip ["Traversal.FileModule"]
  defp read_archive(path) do
    with {:ok, %File.Stat{size: size}} when size <= 10 * 1024 * 1024 <- File.lstat(path),
         {:ok, bytes} <- File.read(path) do
      {:ok, bytes}
    else
      {:ok, %File.Stat{}} -> {:refuse, "its archive is over 10 MiB"}
      _ -> {:refuse, "its archive cannot be read"}
    end
  end

  # S5, against the window's verified Hex tarball.
  defp proof(window, d, name, bytes, module, beam, %Context{hex: {_home, releases}} = ctx) do
    with %{version: version} <- Map.get(releases, window),
         tarball when is_binary(tarball) <- Context.tarball(ctx, window),
         {:ok, proof} <-
           KinoAssets.verify(%{
             name: d <> "/" <> name,
             archive: bytes,
             module: module,
             beam: beam,
             tarball: tarball,
             app: window,
             version: version
           }) do
      {:ok, proof}
    else
      {:error, why} -> {:refuse, why}
      _ -> {:refuse, "#{window} has no verified Hex tarball"}
    end
  end

  @doc """
  The verdict's `foreign_priv` and `foreign_priv_rule` (spec 3.6), only
  when the job sent the flag: the package's settled entries on a pass
  (`[]` for none) and the rule when there are any; both nil otherwise.
  """
  @spec put_verdict(map(), map(), :pass | :skip, String.t() | nil) :: map()
  def put_verdict(verdict, %{flag: false}, _status, _package), do: verdict

  def put_verdict(verdict, %{flag: true} = foreign, status, package) do
    entries = Map.get(foreign.entries, package, [])

    Map.merge(verdict, %{
      foreign_priv: if(status == :pass, do: entries),
      foreign_priv_rule: if(status == :pass and entries != [], do: foreign.gate.rule.id)
    })
  end

  @doc "A verdict demoted from a pass: both foreign fields nil, where it has them."
  @spec unpass(map()) :: map()
  def unpass(verdict) do
    Enum.reduce([:foreign_priv, :foreign_priv_rule], verdict, fn key, acc ->
      if Map.has_key?(acc, key), do: Map.put(acc, key, nil), else: acc
    end)
  end
end
