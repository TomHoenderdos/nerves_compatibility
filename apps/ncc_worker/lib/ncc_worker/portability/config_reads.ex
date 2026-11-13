defmodule NccWorker.Portability.ConfigReads do
  @moduledoc """
  Compile-time application config reads (precompiled portability spec, R5):
  which of the trace's `config_reads` observations become `compile_env`
  items of the build, and the value each item carries.

  Every read in the package's closure counts: in the package's window, in a
  closure dependency's window, or outside every window. A dependency that
  reads config at its own compile and exposes the result lets the package
  inline it, and a client checks the dependency's build and the package's
  separately, so the dependency's reads are the package's match conditions
  too. Of those reads:

    * one whose first frame after the `Application` wrappers is package or
      dependency code, toolchain glue it reached the read through (`Enum`,
      `erl_eval`, a macro or callback dispatcher), or no frame at all, is
      recorded;
    * one the toolchain's own code makes (`first_kind` "toolchain": Logger's
      macros, Mix's shell) is recorded when `{app, key}` is on the
      toolchain's reviewed `record` list (Logger's compile-time keys),
      dropped when `{first frame, app, key}` is on its reviewed `drop` list
      (`:elixir, :ansi_enabled` as read for `Mix.Shell.IO`, Logger's
      handler, the compiler's diagnostics printer and the type checker's
      warning formatter, which colour terminal output and generate no
      code), and rebar3's `{rebar, log}` from `rebar_log` and
      `{cf, colour_term}` from `cf`, which only shape rebar3's console
      output), refused when `{first frame, app, key}` is on its reviewed
      `refuse` list (OTP's certificate store, TLS version table and socket
      options, which read their key only on the way to the host's CA
      store, its crypto library or the network: the compile reached the
      host), and otherwise cannot be judged: an
      unknown toolchain read may change code, so the build does not
      publish. It is also listed in `unreviewed` for the review. A toolchain
      with no reviewed lists judges no build with such a read. The tracer
      attributes a read made through `IO.ANSI` or `Logger.Formatter` to the
      frame that called it: `IO.ANSI.format/1,2` and
      `Logger.Formatter.format/2` return escape codes, or none, by that key,
      so package code calling them reads the key itself and the read is
      recorded;
    * the type checker's read is dropped only in a window where package
      code neither started a compile nor captured diagnostics itself
      (`Context.nested`): there the coloured warning goes to Mix alone.
      In a window where it did, the warning can come back to the package
      (`Code.with_diagnostics/2`, `Kernel.ParallelCompiler`'s results), so
      the read cannot be judged;
    * `application:get_all_env/0,1` from package code refuses (there is no
      key to match on); from the toolchain's own code it cannot be judged;
    * `application:get_env/1` (the caller's own application, which no
      compile process has) is ignored;
    * a read naming a non-atom application or key refuses;
    * a read of Hex's own config (`:hex`, any key) cannot be judged, from
      any frame: Hex's config is the builder's (its API and mirror URLs,
      repos, proxies and keys), a beam that depends on it is not portable,
      and its value must never reach a public manifest. Mix keeps no such
      value in its application env (`:colors` and `:listeners`; Mix reads
      its proxies from the environment), so its reads are judged like any
      other.

  ## Values

  A client compares each item with `Application.fetch_env/2` in the
  consumer's Mix VM before any dependency compiles: the project's config
  and the env of the applications Mix itself has loaded, and no
  dependency's `.app`. An item's value is that same lookup in the traced
  compile's Mix VM: the tracer's snapshot of the application env taken
  before anything compiled (`NccWorker.Tracer.Report`'s `config_env`). The
  value the read returned during the compile is used only for
  `config_order` inputs (below): `get_env/3` folds its default in.

  A key the snapshot holds is recorded with the snapshot's value: config is
  persistent, so it wins over every `.app` default in both VMs.

  A key the snapshot does not hold is where the two lookups can agree while
  the compiles differ. Mix loads a dependency's `.app`, and with it the
  dependency's env defaults, once it has compiled it, and keeps it loaded
  for the rest of the VM. What a compile-time read of an unset key returns
  therefore depends on whether that application happened to compile first:

    * the reader's own application is not loaded while it compiles, in
      either VM;
    * an application in the reader's dependency tree is always loaded
      before the reader compiles, at the version the lock pins (a client
      matches the build's closure against its own lock);
    * an application Mix loads before every compile (`:elixir`, `:mix`,
      `:ex_unit`, `:iex`, `:logger`) is loaded in both;
    * any other application is loaded only when the consumer's dependency
      graph compiles it first.

  So an unset key is recorded as `:error` (`unset/0`) only when every one of
  its readers reads its own application, one in its dependency tree
  (`trees/1`), or one Mix preloads. Any other reader of an unset key saw
  the application's `.app` default only if the consumer's compile order
  loaded that `.app` first. So each such reader gets a `config_order` input
  (compile-time inputs spec, option 2): the application's `.app` default at
  the locked version (`app_defaults/1`) and what the reader's read returned,
  as the tracer captured it. The client predicts its own compile order and
  compares. A reader outside every window cannot be ordered and records
  `config_unrecorded`. A value over the cap, or not plain ETF, is
  `"unrecordable"`, which matches nothing. A key missing from a truncated
  snapshot, or more than 500 keys, records a `config_unrecorded` input
  instead of items. None of these stops the build from publishing.

  A key with readers of both kinds keeps its unset item for the readers
  loaded alike and a `config_order` input for each of the others; a key
  whose readers are all ordered has no item, since the client's
  `compile_env` check would compare it with the wrong value. More than 96
  `config_order` inputs (`Compatibility.CompileInputs.max_config_order_items/0`)
  record `config_unrecorded` instead, and so does one whose application,
  key or reader is a name no item may carry
  (`Compatibility.CompileInputs.name?/1`).

  The items never enter the published `.app`: `merge/2` adds them to the
  build's `compile_env` list only.
  """

  alias Compatibility.{CompileInputs, RecordedValue}
  alias NccWorker.Portability.Context

  @prefix "compile-time config read: "

  # OTP's certificate, TLS and socket reads (`@host_reads` below) are
  # themselves a compile-time host read (R1, `Compatibility.Portability`):
  # the package's own compile reached the host's CA store, crypto library
  # or the network. They carry that refusal's prefix, not `@prefix`, so
  # they withdraw an earlier `pure_elixir` publication the way any other
  # host read does.
  @host_read_prefix "compile-time host read: "

  @logger_compile_keys [
    {"logger", "always_evaluate_messages"},
    {"logger", "compile_time_application"},
    {"logger", "compile_time_purge_level"},
    {"logger", "compile_time_purge_matching"}
  ]

  # `Mix.Shell.IO.info/1`, `error/1` (which a dependency's Mix compiler
  # calls through `Mix.shell()`, as elixir_make does) pass
  # `IO.ANSI.format/1`'s result straight to `IO.puts/1,2` and return `:ok`:
  # the key only selects the escape codes in Mix's terminal output and
  # never reaches the beam.
  @mix_shell_ansi {"Elixir.Mix.Shell.IO", "elixir", "ansi_enabled"}

  # A message logged at compile time is formatted in the logging process:
  # `:logger_h_common` hands it to `Logger.Formatter.format/2`, which colours
  # it by `IO.ANSI.enabled?/0`, and writes the result to the handler's
  # device. The key only colours console output and never reaches the beam.
  # Keyed on the handler frame, not the formatter's: package code calling
  # `Logger.Formatter.format/2` itself gets the coloured text back, and its
  # read is its own.
  @logger_handler_ansi {"logger_h_common", "elixir", "ansi_enabled"}

  # The compiler prints a warning or error through `:elixir_errors`, which
  # colours the diagnostic by the key while formatting it and writes the
  # text to standard error: the key only colours compiler output and never
  # reaches the beam. A checker warning is printed in a process the
  # package's own top-level code spawned, so the read lands in its window.
  # The tracer keeps `:elixir_errors` as the first frame only while one of
  # its printing functions is on the stack; formatted text returned to a
  # caller (`SyntaxError.message/1`) is the caller's read.
  @compiler_diagnostic_ansi {"elixir_errors", "elixir", "ansi_enabled"}

  # The type checker colours the offending argument of a bad call by the key
  # while formatting a warning (`Module.Types.Apply`), and the checker prints
  # the warning and returns it to the compiler, which Mix keeps in its
  # manifest under `.mix`. A build publishes `ebin` and `priv` only, so the
  # key only colours compiler output. The tracer keeps the frame first only
  # on that path; text formatted for anyone else is the asker's read. A
  # compile the package starts itself returns the warnings to the package,
  # so the drop holds only in a window without one (`@diagnostic_drops`).
  @type_checker_ansi {"Elixir.Module.Types.Apply", "elixir", "ansi_enabled"}

  # rebar3 (Mix's own escript under `MIX_HOME`, so toolchain code in the
  # child VM the tracer follows) logs through `rebar_log:log/3`, which reads
  # its `ec_cmd_log` state from `{rebar, log}`, prints the message with it
  # and returns `ok`; and colours text through `cf`, whose `colour_term/0`
  # reads `{cf, colour_term}` to pick escape codes, or none, for the
  # console. Neither value reaches a beam rebar3 compiles. Keyed on those
  # two frames only: rebar3's other keys (`log_level`, `color_intensity`)
  # and the same keys read from any other frame stay unreviewed.
  @rebar3_log {"rebar_log", "rebar", "log"}
  @rebar3_colour {"cf", "cf", "colour_term"}

  # Drops whose text reaches the diagnostics a compile returns, not only
  # its output.
  @diagnostic_drops [@type_checker_ansi]

  # OTP's own reads on the way to the host, each in one function of its
  # module (pinned per toolchain by ConfigReadsTest), and each beside the
  # host read the same call makes, which a toolchain read must not hide as
  # unreviewed:
  #
  #   * `pubkey_os_cacerts:get/0` (`:public_key.cacerts_get/0`, Mint's,
  #     RustlerPrecompiled's and Hex's TLS setup) picks the CA file to load
  #     by `cacerts_path`, then loads the host's CA store and returns it;
  #   * `tls_record` and `dtls_record`'s `supported_protocol_versions/0`
  #     (`:ssl.versions/0` and every TLS connection's options) check this
  #     host's crypto library for each version the key allows;
  #   * `inet:connect_options/2` builds the socket options of an outgoing
  #     connection (`:gen_tcp.connect`, and so every TLS connection).
  #
  # The value never decides only output: the CA store, the versions or the
  # connection come back to the caller. So these refuse, from those frames
  # only; a package reading the same key itself records it.
  @host_reads [
    {"pubkey_os_cacerts", "public_key", "cacerts_path"},
    {"tls_record", "ssl", "protocol_version"},
    {"dtls_record", "ssl", "dtls_protocol_version"},
    {"inet", "kernel", "inet_default_connect_options"}
  ]

  # Per Elixir minor, the toolchain's own compile-time config reads, reviewed
  # against real compiles: `record` ({app, key}) changes generated code;
  # `drop` ({first frame module, app, key}) does not; `refuse` (the same
  # shape) means the compile reached the host.
  @reviewed %{
    "1.19" => %{
      record: @logger_compile_keys,
      drop: [
        @mix_shell_ansi,
        @logger_handler_ansi,
        @compiler_diagnostic_ansi,
        @type_checker_ansi,
        @rebar3_log,
        @rebar3_colour
      ],
      refuse: @host_reads
    },
    "1.20" => %{
      record: @logger_compile_keys,
      drop: [
        @mix_shell_ansi,
        @logger_handler_ansi,
        @compiler_diagnostic_ansi,
        @type_checker_ansi,
        @rebar3_log,
        @rebar3_colour
      ],
      refuse: @host_reads
    }
  }

  # Loaded before every compile: Mix's own extra applications
  # (`Mix.AppLoader`) and Logger, which Mix starts.
  @preloaded ~w(elixir mix ex_unit iex logger)

  @max_items 500
  @unrecorded %{"kind" => "config_unrecorded"}
  @max_app_bytes 1_048_576

  @type item :: %{app: String.t(), path: [String.t()], value: String.t()}
  @type trees :: %{String.t() => [String.t()]}
  @type defaults :: (String.t(), String.t() -> String.t()) | nil
  @type result :: %{
          items: [item()],
          refusals: [{term(), {:refuse, String.t()}}],
          problems: [String.t()],
          unreviewed: [map()],
          dropped: non_neg_integer(),
          inputs: [map()]
        }

  @doc "The reviewed toolchain reads for Elixir version `elixir`, or nil."
  @spec reviewed(term()) ::
          %{
            record: [{String.t(), String.t()}],
            drop: [{String.t(), String.t(), String.t()}],
            refuse: [{String.t(), String.t(), String.t()}]
          }
          | nil
  def reviewed(elixir) when is_binary(elixir) do
    case Version.parse(elixir) do
      {:ok, %Version{major: major, minor: minor}} -> Map.get(@reviewed, "#{major}.#{minor}")
      :error -> nil
    end
  end

  def reviewed(_elixir), do: nil

  @doc "The value of a key the project leaves unset, as a client decodes it: `:error`."
  @spec unset() :: String.t()
  def unset, do: encode(:error)

  @doc """
  Every closure dependency of `ctx` with its dependency tree: itself and
  every closure dependency it reaches (`Context.closure_of/2`).
  """
  @spec trees(Context.t()) :: trees()
  def trees(%Context{deps: deps} = ctx),
    do: Map.new(Map.keys(deps), &{&1, Context.closure_of(ctx, &1)})

  @doc """
  The items, refusals and problems of the `config_reads` observations in
  `decided` (`{owner, decision}`, already limited to the package's closure),
  for a trace made on Elixir `elixir` whose snapshot is `snapshot`; `trees`
  is every owner's dependency tree (`trees/1`), `nested` the windows
  package code started a compile or a capture of diagnostics in
  (`Context.nested`), and `defaults` the `.app` env defaults of the traced
  build (`app_defaults/1`), or nil when there are none to read: every
  `config_order` input's `default` is then `"unrecordable"`.
  """
  @spec judge([{term(), term()}], String.t() | nil, term(), trees(), map(), defaults()) ::
          result()
  def judge(decided, elixir, snapshot, trees, nested, defaults \\ nil)
      when is_map(trees) and is_map(nested) do
    toolchain = {elixir, reviewed(elixir)}
    acc = %{keys: %{}, returns: %{}, refusals: [], problems: [], unreviewed: [], dropped: 0}

    decided
    |> Enum.reduce(acc, fn
      {owner, {:observe, "config_reads", item}}, acc ->
        add(acc, owner, item, nested_drop(classify(item, toolchain), owner, nested))

      _other, acc ->
        acc
    end)
    |> finish(snapshot, trees, defaults)
  end

  @doc """
  The `.app` env default of `{app, key}` in the traced build, as a recorded
  value: `{:ok, value}` when `app`'s `_build/<env>/lib/<app>/ebin/<app>.app`
  declares `key`, `:error` when it does not. `"unrecordable"` when `app` is
  not a closure dependency, its `.app` is missing, over 1 MiB or not a
  single application term, or the value cannot be encoded. Keys compare by
  name, so no atom is made from the trace.
  """
  @spec app_defaults(Context.t()) :: (String.t(), String.t() -> String.t())
  def app_defaults(%Context{} = ctx) do
    fn app, key -> app_default(Context.ebin(ctx, app), app, key) end
  end

  # `ebin` is a closure dependency's build dir in the traced build
  # (`Context.ebin/2`) and `app` that dependency's name.
  # sobelow_skip ["Traversal.FileModule"]
  defp app_default(ebin, app, key) when is_binary(ebin) do
    path = Path.join(ebin, app <> ".app")

    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_app_bytes <-
           File.stat(path),
         {:ok, [{:application, _name, props}]} when is_list(props) <- :file.consult(path),
         env when is_list(env) <- Keyword.get(props, :env, []) do
      case Enum.find(env, &named?(&1, key)) do
        {_key, value} -> recordable(encode({:ok, value}))
        nil -> unset()
      end
    else
      _ -> CompileInputs.unrecordable()
    end
  end

  defp app_default(_ebin, _app, _key), do: CompileInputs.unrecordable()

  defp named?({k, _v}, key) when is_atom(k), do: Atom.to_string(k) == key
  defp named?(_entry, _key), do: false

  @doc """
  The build's `compile_env`: the `.app`'s own items (`NccWorker.AppFile`),
  then every R5 item whose `{app, path}` the `.app` does not list. A `.app`
  that could not be read (`nil`) stays `nil`, which no client matches.
  """
  @spec merge([map()] | nil, [item()]) :: [map()] | nil
  def merge(nil, _items), do: nil

  def merge(app_items, items) when is_list(app_items) do
    taken = MapSet.new(app_items, &{&1.app, &1.path})
    app_items ++ Enum.reject(items, &MapSet.member?(taken, {&1.app, &1.path}))
  end

  # A diagnostic drop in a window with a nested compile: the warning text
  # can reach the package there.
  defp nested_drop({:drop, entry}, owner, nested) when entry in @diagnostic_drops do
    case Map.fetch(nested, owner) do
      {:ok, mfa} ->
        {_first, app, key} = entry

        {:unjudged,
         "toolchain config read in a window with a nested compile (#{mfa}): " <>
           "#{app} #{key} from #{elem(entry, 0)}"}

      :error ->
        :drop
    end
  end

  defp nested_drop({:drop, _entry}, _owner, _nested), do: :drop
  defp nested_drop(decision, _owner, _nested), do: decision

  defp add(acc, owner, item, {:record, key}) do
    capture = {owner, item["returned"]}

    acc
    |> put_key(owner, key)
    |> Map.update!(:returns, &Map.update(&1, key, [capture], fn r -> [capture | r] end))
  end

  defp add(acc, owner, item, {:unreviewed, what}) do
    why = "unreviewed toolchain config read: #{what} from #{first(item)}"
    %{flag(acc, owner, item) | problems: [why | acc.problems]}
  end

  defp add(acc, _owner, _item, :drop), do: %{acc | dropped: acc.dropped + 1}
  defp add(acc, _owner, _item, :ignore), do: acc

  defp add(acc, owner, _item, {:refuse, reason}),
    do: %{acc | refusals: [{owner, {:refuse, reason}} | acc.refusals]}

  defp add(acc, _owner, _item, {:unjudged, why}), do: %{acc | problems: [why | acc.problems]}

  defp put_key(acc, owner, key),
    do: %{acc | keys: Map.update(acc.keys, key, MapSet.new([owner]), &MapSet.put(&1, owner))}

  # The unreviewed list is published for review: without the value the read
  # returned, which only a compile_inputs item may carry.
  defp flag(acc, owner, item) do
    flagged = item |> Map.delete("returned") |> Map.put("owner", name(owner))
    %{acc | unreviewed: [flagged | acc.unreviewed]}
  end

  defp classify(%{"mfa" => "application:get_env/1"}, _toolchain), do: :ignore

  defp classify(%{"mfa" => "application:get_all_env/" <> _} = item, _toolchain) do
    if toolchain?(item),
      do: {:unreviewed, "#{item["mfa"]} (#{get_in(item, ["arg", "app"])})"},
      else: {:refuse, reason(item, "has no key to match on")}
  end

  defp classify(
         %{"arg" => %{"atoms" => true, "app_name" => "hex", "key_name" => key}},
         _toolchain
       )
       when is_binary(key),
       do: {:unjudged, "builder config read: hex #{key}"}

  defp classify(
         %{"arg" => %{"atoms" => true, "app_name" => app, "key_name" => key}} = item,
         toolchain
       )
       when is_binary(app) and is_binary(key) do
    if toolchain?(item),
      do: toolchain_read(item, {app, key}, item["first"], toolchain),
      else: {:record, {app, key}}
  end

  defp classify(item, _toolchain),
    do: {:refuse, reason(item, "names a non-atom application or key")}

  defp toolchain_read(_item, _key, _first, {elixir, nil}),
    do: {:unjudged, "no reviewed config reads for Elixir #{minor(elixir)}"}

  defp toolchain_read(item, {app, key}, first, {_elixir, reviewed}) do
    %{record: record, drop: drop, refuse: refuse} = reviewed

    cond do
      {app, key} in record ->
        {:record, {app, key}}

      {first, app, key} in drop ->
        {:drop, {first, app, key}}

      {first, app, key} in refuse ->
        {:refuse,
         reason(
           item,
           "#{key} is read by OTP's certificate, TLS or socket code (#{first}): " <>
             "the compile reached the host's CA store, crypto or network",
           @host_read_prefix
         )}

      true ->
        {:unreviewed, "#{app} #{key}"}
    end
  end

  defp first(%{"first" => first}) when is_binary(first), do: first
  defp first(_item), do: "(no frame)"

  defp toolchain?(%{"first_kind" => "toolchain"}), do: true
  defp toolchain?(_item), do: false

  defp finish(acc, snapshot, trees, defaults) do
    {items, problems, inputs} =
      items(Enum.sort(acc.keys), snapshot, trees, acc.returns, defaults)

    %{
      items: items,
      refusals: Enum.reverse(acc.refusals),
      problems: Enum.uniq(Enum.reverse(acc.problems) ++ problems),
      unreviewed: Enum.reverse(acc.unreviewed),
      dropped: acc.dropped,
      inputs: inputs
    }
  end

  defp items([], _snapshot, _trees, _returns, _defaults), do: {[], [], []}

  defp items(keys, _snapshot, _trees, _returns, _defaults) when length(keys) > @max_items,
    do: {[], [], [@unrecorded]}

  defp items(keys, %{entries: entries, truncated: truncated}, trees, returns, defaults)
       when is_map(entries) do
    {items, inputs} =
      Enum.reduce(keys, {[], []}, fn {{app, key}, readers}, {items, inputs} ->
        captures = Map.get(returns, {app, key}, [])
        {item, more} = value(entries, {app, key}, truncated, readers, trees, captures, defaults)
        {if(item, do: [item | items], else: items), Enum.reverse(more, inputs)}
      end)

    {Enum.reverse(items), [], inputs |> Enum.reverse() |> Enum.uniq() |> cap_orders()}
  end

  defp items(_keys, _snapshot, _trees, _returns, _defaults),
    do: {[], ["no config snapshot"], []}

  defp cap_orders(inputs) do
    {orders, others} = Enum.split_with(inputs, &(&1["kind"] == "config_order"))

    if length(orders) > CompileInputs.max_config_order_items(),
      do: Enum.uniq(others ++ [@unrecorded]),
      else: inputs
  end

  defp value(entries, {app, key}, truncated, readers, trees, captures, defaults) do
    case Map.fetch(entries, {app, key}) do
      {:ok, :oversize} -> {item(app, key, CompileInputs.unrecordable()), []}
      {:ok, value} -> {item(app, key, recordable(value)), []}
      :error when truncated -> {nil, [@unrecorded]}
      :error -> unset_value(app, key, readers, trees, captures, defaults)
    end
  end

  defp item(app, key, value), do: %{app: app, path: [key], value: value}

  # A snapshot value is already the base64url text the manifest records
  # (R5's own `encode/1` or the tracer's; see the moduledoc). One that is
  # not plain, small ETF (compressed, over 64 KiB, or holding a fun, pid,
  # port or reference) is recorded as matching nothing, like an
  # `:oversize` entry.
  defp recordable(value) do
    if RecordedValue.acceptable?(value), do: value, else: CompileInputs.unrecordable()
  end

  # An unset key reads the same in both VMs only when its application's
  # .app is loaded, or not, in both (see the moduledoc): those readers keep
  # the unset item. For every other reader, whether the .app default was
  # loaded depends on the consumer's compile order, so the build records
  # the default and what the reader saw, and the client predicts the rest.
  defp unset_value(app, key, readers, trees, captures, defaults) do
    {alike, ordered} = Enum.split_with(readers, &loaded_alike?(app, &1, trees))
    item = if alike != [] or ordered == [], do: item(app, key, unset())
    default = default_of(defaults, app, key)
    {item, ordered |> Enum.sort() |> Enum.map(&order_item(app, key, &1, default, captures))}
  end

  # A name no compile_inputs item may carry (`CompileInputs.name?/1`: an
  # atom that is empty, holds `=` or NUL, or runs over 256 bytes) would make
  # the portal reject the whole list: it records config_unrecorded instead,
  # which a client must still check.
  defp order_item(app, key, reader, default, captures) when is_binary(reader) do
    if Enum.all?([app, key, reader], &CompileInputs.name?/1),
      do: named_order_item(app, key, reader, default, captures),
      else: @unrecorded
  end

  # A read outside every window has no place in a compile order.
  defp order_item(_app, _key, _reader, _default, _captures), do: @unrecorded

  defp named_order_item(app, key, reader, default, captures) do
    %{
      "kind" => "config_order",
      "app" => app,
      "path" => [key],
      "reader" => reader,
      "default" => default,
      "seen" => seen(for({^reader, r} <- captures, do: r))
    }
  end

  # What one reader saw: the one value all its captures agree on.
  # "default": the read got its own fallback, which is what an unset key
  # gives it. A capture without "returned" (an older tracer) stays
  # "unrecordable".
  defp seen(captures) do
    unrecordable = CompileInputs.unrecordable()

    case Enum.uniq(captures) do
      ["default"] -> unset()
      [value] when is_binary(value) and value != unrecordable -> recordable(value)
      _ -> unrecordable
    end
  end

  defp default_of(nil, _app, _key), do: CompileInputs.unrecordable()
  defp default_of(defaults, app, key), do: defaults.(app, key)

  defp loaded_alike?(app, _reader, _trees) when app in @preloaded, do: true

  defp loaded_alike?(app, reader, trees) when is_binary(reader),
    do: app in Map.get(trees, reader, [])

  defp loaded_alike?(_app, _reader, _trees), do: false

  defp reason(item, what, prefix \\ @prefix) do
    "#{prefix}#{item["mfa"]} (#{get_in(item, ["arg", "app"])}) #{what}#{where(item)}"
  end

  defp where(%{"module" => module, "file" => file, "line" => line}) when is_binary(module),
    do: " in #{display(module)} (#{file}:#{line})"

  defp where(_item), do: ""

  defp display("Elixir." <> name), do: name
  defp display(name), do: name

  defp minor(elixir) when is_binary(elixir),
    do: elixir |> String.split(".") |> Enum.take(2) |> Enum.join(".")

  defp minor(_elixir), do: "(unknown)"

  defp name(owner) when is_binary(owner), do: owner
  defp name(owner) when is_atom(owner), do: Atom.to_string(owner)
  defp name(owner), do: inspect(owner)

  defp encode(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)
end
