defmodule NccWorker.Portability.Guarded do
  @moduledoc """
  Guarded modules (coverage drop 2026-11-22, F4): a closure dependency P
  whose compile-time probe of a module outside its closure only decides
  whether P defines a set of modules A. websock_adapter 0.5.0 to 0.7.2:

      if Code.ensure_loaded?(:cowboy_websocket) do
        defmodule WebSockAdapter.CowboyAdapter do ... end
      end

  P's own build refuses as before: a Mix.install user who has the probed
  module gets A, the builder does not. A dependent whose beams are the
  same whether A exists or not is not tainted by P's refusal. That is
  proved by building, never by the conditions below alone (S9 review B1,
  B2: the type checker reads A's signature through a value of A's atom's
  type, untraced, and P's Mix manifest lists A): a pass these conditions
  waive is held, and `NccWorker.Portability.GuardedProof` builds the
  package again with the entry's guarded package present (`present`:
  added to the closure, compiled first, on an unpruned code path) and
  passes it only when its app is the same. The conditions are a cheap
  pre-filter: a dependent that fails one refuses without that build. Each
  reviewed site (`@entries`) names P, the
  releases read (oldest and newest: a newer one refuses until it is read),
  the probe (P's file, the probed module, a top-level form of that file)
  and A (exact module names, or `{:prefix, name}` for a name and every
  module under it). The review holds that the probe's form wraps only A's
  definitions, so the rest of P is the same in both worlds.

  For a dependency P of the package (never the package itself, and not in
  a firmware target's or host-native verdict, which refuses on any
  refusal of the closure), its refusals of a reviewed site are waived when
  every occurrence of that refusal text in P's window is the site's probe,
  at a reviewed release, and:

    * no closure application's ebin holds a module of A: the builder took
      the branch without A;
    * no Elixir beam of the closure outside A (the package's, P's and every
      other dependency's) refers to a module of A by a remote call, a
      capture, `apply` or `make_fun` with A as a literal, read from the
      beam's Elixir debug info: the expanded code before the Erlang
      compiler optimises any of it away, which is what Elixir 1.20's type
      checker read. It reads the signature of what a module calls, and the
      inferred types go into its `ExCk` chunk; a bare atom (websock_adapter's
      `{WebSockAdapter.CowboyAdapter, ...}` tuple) reads none. A beam
      without Elixir debug info fails. Erlang beams are not read: `erlc`
      reads no other module's code;
    * no traced probe of a module of A, in any window or outside every
      window. A compile-time call of A is such a probe: A is absent here,
      and Elixir's error handler ensure-loads it (`Kernel.ErrorHandler`);
      so are `Code.ensure_loaded?/1`, `function_exported?/3` and a
      `@behaviour` lookup. A `require`, `import`, `use`, struct or `@derive`
      of an absent module fails the compile;
    * no traced application probe of P's application: P's `.app` lists A
      among its `modules`;
    * no traced file event (a read, a listing, a stat) of P's ebin or a file
      in it, from any window: there the other world has A's beams. A read of
      P's `include` (joken's of jose's headers) is the same either way.

  A rebar3 child VM traces probes of the modules its own tracer loaded
  only (review N3), and its code path holds every built dependency's
  ebin, P's included, so a parse transform's probe of A there is no
  event. The pre-filter does not see it; the proof build does when it
  changes what the package publishes, and the rebar3 app's own build is
  judged in its own closure.

  Never raises: a beam or debug info that cannot be read fails the waiver.
  """

  alias NccWorker.Portability.{Context, Etf}

  @entries [
    # websock_adapter 0.5.0 to 0.7.2 (read 2026-11-22): the file is one
    # top-level `if` around one `defmodule`; `WebSockAdapter.tuple_for/4`
    # names the module only as an atom. 0.4.5 not read.
    %{
      id: "websock_adapter:cowboy_adapter",
      app: "websock_adapter",
      range: {"0.5.0", "0.7.2"},
      sites: [{"lib/websock_adapter/cowboy_adapter.ex", "cowboy_websocket"}],
      guards: ["Elixir.WebSockAdapter.CowboyAdapter"],
      present: %{deps: [~s({:cowboy, ">= 0.0.0"})], first: ["cowboy"]}
    },
    # jose 1.11.0 to 1.11.13: each file is one top-level `if` around the
    # `defmodule`, `defprotocol` and `defimpl` of `JOSE.Poison*` only; no
    # other Elixir file names `JOSE.Poison` (the Erlang callers,
    # `jose_server` and `jose_json_poison_lexical_encoder`, call it at run
    # time). The `Poison.EncodeError` probe inside the second `if` runs
    # only where Poison is found.
    %{
      id: "jose:poison",
      app: "jose",
      range: {"1.11.0", "1.11.13"},
      sites: [
        {"lib/jose/poison.ex", "Elixir.Poison"},
        {"lib/jose/poison/lexical_encoder.ex", "Elixir.Poison"}
      ],
      guards: [{:prefix, "Elixir.JOSE.Poison"}],
      present: %{deps: [~s({:poison, ">= 0.0.0"})], first: ["poison"]}
    },
    # ymlr 5.1.4 to 5.1.6: the last top-level form of the file is an `if`
    # around one `defimpl Ymlr.Encoder, for: Decimal`, and no other form
    # probes. A dependency compiles against the unconsolidated protocol,
    # which is the same either way. 5.0.0 to 5.1.3 define the impl without
    # a probe.
    %{
      id: "ymlr:decimal",
      app: "ymlr",
      range: {"5.1.4", "5.1.6"},
      sites: [{"lib/ymlr/encoder.ex", "Elixir.Decimal"}],
      guards: ["Elixir.Ymlr.Encoder.Decimal"],
      present: %{deps: [~s({:decimal, ">= 0.0.0"})], first: ["decimal"]}
    }
  ]

  @max_beam_bytes 256 * 1024 * 1024
  @max_inflated_bytes 64 * 1024 * 1024

  @typedoc "Per closure dependency, the refusal texts waived and the entries that waived them."
  @type waivers :: %{String.t() => %{reasons: MapSet.t(String.t()), entries: [String.t()]}}

  @doc "The reviewed entries."
  @spec entries() :: [map()]
  def entries, do: @entries

  @doc """
  The id of the reviewed entry whose site `event` is, made in `owner`'s
  window (a closure dependency) at a reviewed release, or `nil`: a
  package-made `code:ensure_loaded/1` through `Code.ensure_loaded?/1` of
  the site's probed module, from a top-level form of the site's file.
  """
  @spec site(map(), Context.t(), term()) :: String.t() | nil
  def site(
        %{
          "channel" => "probe",
          "mfa" => "code:ensure_loaded/1",
          "caller" => %{"module" => "Elixir.Code", "function" => "ensure_loaded?", "arity" => 1},
          "user" => %{"function" => "__FILE__", "file" => file},
          "arg" => %{"module" => module, "by_package" => true}
        },
        %Context{} = ctx,
        owner
      )
      when is_binary(owner) and is_binary(file) and is_binary(module) do
    Enum.find_value(@entries, fn entry ->
      if entry.app == owner and {file, module} in entry.sites and Context.dep?(ctx, owner) and
           reviewed_release?(ctx, owner, entry.range),
         do: entry.id
    end)
  end

  def site(_event, _ctx, _owner), do: nil

  @doc """
  The waivers of a judge run: `tags` are `{owner, refusal_text, entry_id |
  nil}` for every refusal it decided, `report` its trace report. Only
  closure dependencies other than the package, and only refusal texts
  every occurrence of which is a reviewed site whose conditions hold (see
  the moduledoc).
  """
  @spec waivers(Context.t(), map(), [{term(), String.t(), String.t() | nil}]) :: waivers()
  def waivers(%Context{} = ctx, report, tags) do
    scope = Context.closure_of(ctx, ctx.package)

    candidates =
      for {owner, reason, _tag} <- tags,
          is_binary(owner) and owner != ctx.package and owner in scope,
          uniq: true,
          do: {owner, reason}

    waive_all(candidates, tags, {ctx, scope, report})
  rescue
    _ -> %{}
  end

  defp waive_all([], _tags, _run), do: %{}

  defp waive_all(candidates, tags, {ctx, scope, report}) do
    run = {ctx, scope, events(ctx, report)}

    {waivers, _checked} =
      Enum.reduce(candidates, {%{}, %{}}, fn {owner, reason}, {acc, checked} ->
        ids = for {^owner, ^reason, tag} <- tags, do: tag
        waive(owner, reason, ids, acc, checked, run)
      end)

    waivers
  end

  # A refusal text is waived only when every occurrence of it is a site
  # (`nil` is not) whose entries hold.
  defp waive(owner, reason, ids, acc, checked, {ctx, scope, events}) do
    if nil in ids do
      {acc, checked}
    else
      {ok?, checked} = entries_hold?(Enum.uniq(ids), ctx, scope, events, checked)
      {if(ok?, do: add(acc, owner, reason, ids), else: acc), checked}
    end
  end

  defp add(acc, owner, reason, ids) do
    Map.update(acc, owner, %{reasons: MapSet.new([reason]), entries: Enum.uniq(ids)}, fn w ->
      %{w | reasons: MapSet.put(w.reasons, reason), entries: Enum.uniq(w.entries ++ ids)}
    end)
  end

  # Each entry is checked once per run.
  defp entries_hold?(ids, ctx, scope, events, checked) do
    Enum.reduce(ids, {true, checked}, fn id, {ok?, checked} ->
      case Map.fetch(checked, id) do
        {:ok, holds} ->
          {ok? and holds, checked}

        :error ->
          holds = holds?(Enum.find(@entries, &(&1.id == id)), ctx, scope, events)
          {ok? and holds, Map.put(checked, id, holds)}
      end
    end)
  end

  defp holds?(nil, _ctx, _scope, _events), do: false

  defp holds?(entry, ctx, scope, events) do
    guards = entry.guards

    not built?(ctx, scope, guards) and not probed?(events, guards, entry.app) and
      not ebin_read?(ctx, events, entry.app) and not referred?(ctx, scope, guards)
  end

  # `{owner, event}`: the Mix VM's by `Context.owner/2`, a child VM's by
  # its app, as the judge attributes them.
  defp events(ctx, report),
    do:
      Enum.concat(
        Enum.map(Map.get(report, :events, []), &{Context.owner(ctx, &1), &1}),
        Enum.flat_map(Map.get(report, :children, %{}), fn {app, c} ->
          Enum.map(c.events, &{app, &1})
        end)
      )

  # A module of A in a closure application's ebin.
  defp built?(ctx, scope, guards) do
    Enum.any?(ctx.modules, fn {module, app} -> app in scope and guarded?(module, guards) end)
  end

  # A traced probe of a module of A, or an application probe of P's
  # application, anywhere in the trace.
  defp probed?(events, guards, app) do
    events
    |> Enum.map(&elem(&1, 1))
    |> Enum.any?(fn
      %{"channel" => "probe", "arg" => %{"module" => m}} when is_binary(m) -> guarded?(m, guards)
      %{"channel" => "app_probe", "arg" => %{"app" => ^app}} -> true
      %{"channel" => "app_probe", "arg" => %{"app" => a}} when not is_binary(a) -> true
      _ -> false
    end)
  end

  # A traced file event (a read, a listing, a stat, a write, a copy's
  # source) of P's ebin or a file in it, from any window or VM: in the other
  # world it holds A's beams and an `.app` that lists them. A relative path
  # is the owner's compile's (Mix compiles a dependency in its source dir);
  # one that cannot be placed, or an unreadable path, counts, and so does a wildcard whose literal prefix
  # reaches the ebin (`_build/host/lib/*/ebin`). P's `include` and `priv`
  # are the same either way, and `file:get_cwd/0` names no file.
  defp ebin_read?(ctx, events, app) do
    case Context.ebin(ctx, app) do
      ebin when is_binary(ebin) ->
        Enum.any?(events, fn
          {owner, %{"channel" => ch, "arg" => arg}}
          when ch in ["file_read", "file_write"] and is_map(arg) ->
            arg
            |> Map.take(["path", "from"])
            |> Map.values()
            |> Enum.any?(&reaches?(&1, ebin, ctx, owner))

          {_owner, %{"channel" => ch}} when ch in ["file_read", "file_write"] ->
            true

          _ ->
            false
        end)

      _ ->
        true
    end
  end

  # A relative path is the owner's compile's (`Context.resolve/3`).
  defp reaches?(path, ebin, ctx, owner) when is_binary(path) do
    case :binary.match(path, ["*", "?", "{", "["]) do
      :nomatch ->
        in_ebin?(Context.resolve(ctx, path, owner), ebin)

      {at, _} ->
        dir = Path.dirname(binary_part(path, 0, at) <> "x")
        glob_reaches?(Context.resolve(ctx, dir, owner), ebin)
    end
  end

  defp reaches?(_path, _ebin, _ctx, _owner), do: true

  defp in_ebin?(real, ebin) when is_binary(real), do: under?(real, ebin)
  defp in_ebin?(nil, _ebin), do: true

  # The wildcard's literal dir: the ebin under it, or it under the ebin.
  defp glob_reaches?(real, ebin) when is_binary(real),
    do: under?(ebin, real) or under?(real, ebin)

  defp glob_reaches?(nil, _ebin), do: true

  defp under?(path, dir),
    do: path == dir or String.starts_with?(path, String.trim_trailing(dir, "/") <> "/")

  # An Elixir beam of the closure outside A that refers to a module of A.
  defp referred?(ctx, scope, guards) do
    Enum.any?(ctx.modules, fn {module, app} ->
      app in scope and String.starts_with?(module, "Elixir.") and not guarded?(module, guards) and
        refers?(beam_path(ctx, app, module), guards)
    end)
  end

  defp beam_path(ctx, app, module) do
    case Context.ebin(ctx, app) do
      ebin when is_binary(ebin) -> Path.join(ebin, module <> ".beam")
      _ -> nil
    end
  end

  @doc false
  # Public for tests: whether the beam at `path` refers to a module of
  # `guards` (see the moduledoc); `true` when it cannot be read. Read from
  # the Elixir debug info, the expanded code before the Erlang compiler
  # optimises any of it away, which is what the type checker read: a
  # capture is a literal (`LitT`) and code the compiler drops is in no
  # chunk but this one. The inflated term is searched for each guarded
  # name first, and only one that holds a name is decoded. A beam without
  # Elixir debug info refers to it.
  @spec refers?(String.t() | nil, list()) :: boolean()
  def refers?(nil, _guards), do: true

  def refers?(path, guards) do
    with {:ok, chunks} <- chunks(path),
         {:ok, term} <- debug_term(chunks["Dbgi"]),
         true <- :binary.match(term, "elixir_v1") != :nomatch do
      if Enum.any?(guards, &(:binary.match(term, guard_name(&1)) != :nomatch)),
        do: refers_in_debug_info?(term, guards),
        else: false
    else
      _ -> true
    end
  end

  # The debug info chunk's external term, inflated (bounded) when compressed.
  defp debug_term(<<131, 80, size::32, compressed::binary>>) do
    case Etf.inflate(compressed, size) do
      {:ok, inner} -> {:ok, <<131, inner::binary>>}
      _ -> :error
    end
  end

  defp debug_term(<<131, _::binary>> = term), do: {:ok, term}
  defp debug_term(_other), do: :error

  defp refers_in_debug_info?(term, guards) do
    case Etf.decode(term) do
      {:ok,
       {:tuple,
        [
          {:atom, "debug_info_v1"},
          {:atom, "elixir_erl"},
          {:tuple, [{:atom, "elixir_v1"}, _map, _specs]} = info
        ]}} ->
        walk(info, guards)

      _ ->
        true
    end
  end

  # `{:., _, [m, f]}`: a remote call or a capture; `:erlang.apply/2,3` and
  # `:erlang.make_fun/3` (what `apply/3` and `Function.capture/3` expand to)
  # with `m` literal.
  defp walk({:tuple, [{:atom, "."}, _meta, {:list, [{:atom, m}, {:atom, _f}], _tail}]}, guards),
    do: guarded?(m, guards)

  defp walk(
         {:tuple,
          [
            {:tuple, [{:atom, "."}, _, {:list, [{:atom, "erlang"}, {:atom, f}], _}]} = dot,
            meta,
            {:list, [{:atom, m} | _] = args, tail}
          ]},
         guards
       )
       when f in ["apply", "make_fun"] do
    guarded?(m, guards) or walk(dot, guards) or walk(meta, guards) or
      Enum.any?(args, &walk(&1, guards)) or walk(tail, guards)
  end

  defp walk({:tuple, items}, guards), do: Enum.any?(items, &walk(&1, guards))

  defp walk({:list, items, tail}, guards),
    do: Enum.any?(items, &walk(&1, guards)) or walk(tail, guards)

  defp walk({:map, pairs}, guards),
    do: Enum.any?(pairs, fn {k, v} -> walk(k, guards) or walk(v, guards) end)

  defp walk({:export, {:atom, m}, _f, _a}, guards), do: guarded?(m, guards)
  defp walk(_leaf, _guards), do: false

  @doc false
  # Whether `module` (an atom's text) is one of `guards`: an exact name, or
  # `{:prefix, name}` for the name and every module under it.
  @spec guarded?(term(), list()) :: boolean()
  def guarded?(module, guards) when is_binary(module) do
    Enum.any?(guards, fn
      {:prefix, p} -> module == p or String.starts_with?(module, p <> ".")
      name -> module == name
    end)
  end

  def guarded?(_module, _guards), do: false

  defp guard_name({:prefix, p}), do: p
  defp guard_name(name), do: name

  defp reviewed_release?(%Context{hex: {_home, releases}}, app, {oldest, newest})
       when is_map(releases) do
    with %{version: v} when is_binary(v) <- Map.get(releases, app),
         {:ok, version} <- Version.parse(v) do
      Version.compare(version, oldest) != :lt and Version.compare(version, newest) != :gt
    else
      _ -> false
    end
  end

  defp reviewed_release?(_ctx, _app, _range), do: false

  # The `Dbgi` chunk of an untrusted beam, by a
  # bounded IFF reader (no `:beam_lib`, which creates the beam's atoms and
  # gunzips without a bound), as `NccWorker.Portability.BuildRoot` reads
  # beams.
  # sobelow_skip ["Traversal.FileModule"]
  defp chunks(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_beam_bytes <-
           File.stat(path),
         {:ok, binary} <- File.read(path),
         {:ok, plain} <- container(binary),
         <<"FOR1", size::32, "BEAM", body::binary>> when size == byte_size(body) + 4 <- plain do
      chunk_list(body, %{})
    else
      _ -> :error
    end
  end

  defp container(<<31, 139, _::binary>> = gz) do
    case Etf.gunzip(gz, @max_inflated_bytes) do
      {:ok, <<"FOR1", _::binary>> = inflated} -> {:ok, inflated}
      _ -> :error
    end
  end

  defp container(binary), do: {:ok, binary}

  defp chunk_list(<<>>, acc), do: {:ok, acc}

  defp chunk_list(<<id::binary-size(4), len::32, data::binary-size(len), rest::binary>>, acc) do
    pad = rem(4 - rem(len, 4), 4)

    cond do
      id == "Dbgi" and Map.has_key?(acc, id) -> :error
      byte_size(rest) < pad and rest != <<>> -> :error
      true -> chunk_list(skip(rest, pad), keep(acc, id, data))
    end
  end

  defp chunk_list(_truncated, _acc), do: :error

  defp skip(rest, pad) when byte_size(rest) >= pad,
    do: binary_part(rest, pad, byte_size(rest) - pad)

  defp skip(_rest, _pad), do: <<>>

  defp keep(acc, "Dbgi", data), do: Map.put(acc, "Dbgi", data)
  defp keep(acc, _id, _data), do: acc
end
