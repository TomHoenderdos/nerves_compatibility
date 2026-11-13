defmodule NccWorker.Portability.MixExsSlice do
  @moduledoc """
  Spec R4: whether a host observation made while a dependency's `mix.exs`
  ran (its first user frame on line `line` of that file) can reach a key of
  `project/0` that changes the compile, or `application/0`.

  Syntactic and strict; whatever it cannot follow refuses:

    * `project/0` must be one plain definition whose body is a keyword-list
      literal, optionally joined with `++` to zero-arity local functions
      whose bodies are keyword-list literals.
    * The observation's line must sit in a `def`/`defp`, a module attribute,
      or the condition of a module-body conditional that defines either. A
      line anywhere else (a bare module-body statement, code outside the
      module, a line the file does not have) refuses, since its value can
      reach `project/0` through a channel the slice does not follow.
    * Taint spreads by name, not arity (default arguments and captures
      cannot hide a helper): a function is tainted when it contains the
      line, sits inside a module-body conditional that contains it or
      refers to taint, or calls a tainted function; an attribute is tainted
      the same way. A module-body statement referring to taint refuses.
    * A compile-relevant key (or `application/0`) refuses when it contains
      the line, refers to taint, or reaches code calling anything outside a
      fixed set of pure or traced modules and defined local functions:
      reads of untraced stores (`Process.get/1`, `:persistent_term`, ETS,
      ...) carry host values the tracer saw written elsewhere.
      `Application` is allowed: its reads are traced observations.
    * The judged module is the one top-level module that does
      `use Mix.Project`. The source is bounded (size and AST depth) and
      parsed once per file (`analyse/1`); nothing raises, anything
      unexpected refuses.
    * A `mix.exs` that evaluates code dynamically anywhere (`Code`,
      `Module`, `quote`/`unquote`, macros, `apply`, `Mix.Project.config/0`)
      refuses outright.
  """

  @not_compile_relevant ~w(deps docs package description name source_url homepage_url
    test_paths test_coverage test_ignore_filters dialyzer preferred_cli_env cli lockfile
    elixir start_permanent build_embedded)a

  @conditionals [:if, :unless, :case, :cond]

  @dynamic_modules [Code, Module, Mix.Project, Mix.ProjectStack, :erl_eval, :elixir]
  @dynamic_locals [
    :quote,
    :unquote,
    :unquote_splicing,
    :defmacro,
    :defmacrop,
    :apply,
    :binding,
    :var!
  ]

  # Modules a compile-relevant key may call: pure, or whose host reads the
  # tracer sees as observations of their own.
  @allowed_modules [
    Access,
    Application,
    Atom,
    Bitwise,
    Enum,
    File,
    Float,
    Integer,
    Keyword,
    List,
    Map,
    MapSet,
    Path,
    Range,
    Regex,
    Stream,
    String,
    System,
    Tuple,
    Version,
    :binary,
    :filename,
    :lists,
    :maps,
    :os,
    :proplists,
    :string,
    :unicode
  ]
  @allowed_remote [{Mix, :env}, {Mix, :target}, {Mix, :compilers}]

  @denied_kernel [
    :apply,
    :send,
    :spawn,
    :spawn_link,
    :spawn_monitor,
    :binding,
    :var!,
    :quote,
    :unquote,
    :unquote_splicing,
    :receive,
    :import,
    :require,
    :alias,
    :super,
    :defmodule,
    :defmacro,
    :defmacrop,
    :defdelegate,
    :defoverridable,
    :use
  ]
  @kernel_locals (Kernel.__info__(:functions) ++
                    Kernel.__info__(:macros) ++
                    Kernel.SpecialForms.__info__(:macros))
                 |> Enum.map(&elem(&1, 0))
                 |> Kernel.++([:->, :|, :when, :"::"])
                 |> Kernel.--(@denied_kernel)
                 |> MapSet.new()

  @max_source_bytes 256 * 1024
  @max_depth 200

  @enforce_keys [:index]
  defstruct [:index, ast: nil]

  @typedoc "A parsed and indexed `mix.exs`, judged once per observation."
  @type t :: %__MODULE__{index: map(), ast: Macro.t()}
  @type why :: String.t()

  @doc """
  Parses and indexes `source` once (bounded: #{div(@max_source_bytes, 1024)} KiB, AST depth
  #{@max_depth}) so every observation in that file can be judged against it.
  """
  @spec analyse(String.t()) :: {:ok, t()} | {:refuse, why}
  def analyse(source) when is_binary(source), do: guarded(fn -> do_analyse(source) end)

  @doc """
  Judges the observation on `line`, from a source string or an `analyse/1` result.
  Never raises: anything unexpected refuses.
  """
  @spec judge(String.t() | t(), pos_integer()) :: :ok | {:refuse, why}
  def judge(source, line) when is_binary(source) and is_integer(line) do
    with {:ok, analysis} <- analyse(source), do: judge(analysis, line)
  end

  def judge(%__MODULE__{index: index}, line) when is_integer(line) do
    guarded(fn ->
      with {:ok, tainted} <- taint(index, line),
           :ok <- body_statements(index, tainted) do
        check(index, tainted, line)
      end
    end)
  end

  @version_mfas %{
    "System.version/0" => :read,
    "Version.match?/2" => {:call, :match?},
    "Version.compare/2" => {:call, :compare}
  }

  @doc """
  Whether the Elixir-version observation `mfa` made on `line` is one of a
  direct, literal comparison, which `NccWorker.Portability.ElixirVersion`
  can then judge over the build's whole minor series (`"series"`) instead
  of the slice refusing it: `System.version/0`, `Version.match?/2` or
  `Version.compare/2` only, and on that line

    * every `System.version()` is an argument of a `Version.match?/2` or
      `Version.compare/2` call whose other argument is a string literal,
    * every such `Version` call has exactly that shape, every other
      `System` or `Version` call is absent, and the line holds one of the
      observation's kind;

  and nothing in the file can make `Version` or `System` name another
  module: no `alias`, `import` or `require` naming either, no module
  defined under either name. `Elixir.Version` and captures are not direct
  calls. Anything unexpected is `false`.
  """
  @spec direct_version_line?(t(), pos_integer(), String.t()) :: boolean()
  def direct_version_line?(%__MODULE__{ast: ast}, line, mfa)
      when is_integer(line) and is_map_key(@version_mfas, mfa) and ast != nil do
    kind = Map.fetch!(@version_mfas, mfa)

    guarded(fn ->
      nodes = for {node_kind, ^line, ok?} <- version_nodes(ast, []), do: {node_kind, ok?}

      not renames_version?(ast) and Enum.all?(nodes, &elem(&1, 1)) and
        Enum.any?(nodes, &(elem(&1, 0) == kind))
    end) == true
  end

  def direct_version_line?(_analysis, _line, _mfa), do: false

  # `{kind, line, ok?}` for every `System` and `Version` call or reference
  # in `ast`: a `System.version()` read is ok only as a direct argument of
  # a literal comparison, a `Version` call only when it is one; any other
  # call on either module, and either name used any other way (a bare
  # `System`, `Elixir.Version`), never is.
  defp version_nodes({{:., _, [mod, fun]}, meta, args}, acc)
       when is_atom(fun) and is_list(args) do
    line = meta[:line]

    case {exact_alias(mod), fun, args} do
      {:System, :version, []} ->
        [{:read, line, false} | acc]

      {:Version, fun, [a, b]} when fun in [:match?, :compare] ->
        if literal_comparison?(a, b),
          do: [{:read, read_line(a, b), true}, {{:call, fun}, line, true} | acc],
          else: version_nodes(args, [{{:call, fun}, line, false} | acc])

      {nil, _fun, _args} ->
        version_nodes(args, version_nodes(mod, acc))

      {_system_or_version, _fun, _args} ->
        version_nodes(args, [{:other, line, false} | acc])
    end
  end

  defp version_nodes({:__aliases__, meta, parts}, acc) when is_list(parts) do
    if Enum.any?(parts, &(&1 in [:System, :Version])),
      do: [{:other, meta[:line], false} | acc],
      else: acc
  end

  defp version_nodes({a, _meta, b}, acc), do: version_nodes(b, version_nodes(a, acc))
  defp version_nodes({a, b}, acc), do: version_nodes(b, version_nodes(a, acc))
  defp version_nodes(list, acc) when is_list(list), do: Enum.reduce(list, acc, &version_nodes/2)
  defp version_nodes(_leaf, acc), do: acc

  defp literal_comparison?(a, b),
    do: (version_read?(a) and is_binary(b)) or (is_binary(a) and version_read?(b))

  defp version_read?({{:., _, [mod, :version]}, _, []}), do: exact_alias(mod) == :System
  defp version_read?(_node), do: false

  defp read_line(a, b), do: if(is_binary(a), do: elem(b, 1)[:line], else: elem(a, 1)[:line])

  defp exact_alias({:__aliases__, _, [name]}) when name in [:System, :Version], do: name
  defp exact_alias(_mod), do: nil

  # An `alias`, `import` or `require` whose arguments name `Version` or
  # `System` anywhere (`alias A.Version`, `as: System`, `A.{Version}`), or
  # a module defined under either name.
  defp renames_version?(ast) do
    walk_any?(ast, fn
      {form, _, args} when form in [:alias, :import, :require] and is_list(args) ->
        walk_any?(args, &names_version_part?/1)

      {:defmodule, _, [name | _]} ->
        names_version_part?(name)

      _ ->
        false
    end)
  end

  defp names_version_part?({:__aliases__, _, parts}) when is_list(parts),
    do: Enum.any?(parts, &(&1 in [:Version, :System]))

  defp names_version_part?(_node), do: false

  defp guarded(fun) do
    fun.()
  rescue
    _ -> {:refuse, "mix.exs could not be analysed"}
  catch
    _, _ -> {:refuse, "mix.exs could not be analysed"}
  end

  defp do_analyse(source) when byte_size(source) > @max_source_bytes,
    do: {:refuse, "mix.exs is too large"}

  defp do_analyse(source) do
    with {:ok, ast} <- parse(source),
         :ok <- shallow(ast),
         {:ok, body} <- module_body(ast),
         :ok <- static(ast),
         index = index(body),
         :ok <- named(index) do
      {:ok, %__MODULE__{index: index, ast: ast}}
    end
  end

  defp parse(source) do
    case Code.string_to_quoted(source) do
      {:ok, ast} -> {:ok, ast}
      {:error, _} -> {:refuse, "mix.exs does not parse"}
    end
  end

  defp shallow(ast) do
    if within_depth?(ast, 0), do: :ok, else: {:refuse, "mix.exs is too deeply nested"}
  end

  defp within_depth?(_ast, depth) when depth > @max_depth, do: false

  defp within_depth?({a, _meta, b}, depth),
    do: within_depth?(a, depth + 1) and within_depth?(b, depth + 1)

  defp within_depth?({a, b}, depth),
    do: within_depth?(a, depth + 1) and within_depth?(b, depth + 1)

  defp within_depth?(list, depth) when is_list(list),
    do: Enum.all?(list, &within_depth?(&1, depth + 1))

  defp within_depth?(_leaf, _depth), do: true

  # The one top-level module that does `use Mix.Project`.
  defp module_body(ast) do
    modules = for {:defmodule, _, [_name, [do: body]]} <- top_level(ast), do: statements(body)

    case {modules, Enum.filter(modules, &Enum.any?(&1, fn stmt -> mix_project_use?(stmt) end))} do
      {[], _} -> {:refuse, "mix.exs defines no module"}
      {_, []} -> {:refuse, "mix.exs defines no Mix.Project module"}
      {_, [body]} -> {:ok, body}
      {_, _several} -> {:refuse, "mix.exs defines several Mix.Project modules"}
    end
  end

  defp top_level({:__block__, _, forms}), do: forms
  defp top_level(form), do: [form]

  defp mix_project_use?({:use, _, [{:__aliases__, _, [:Mix, :Project]} | _]}), do: true
  defp mix_project_use?(_stmt), do: false

  defp statements({:__block__, _, stmts}), do: stmts
  defp statements(stmt), do: [stmt]

  defp named(index) do
    if Map.has_key?(index.defs, :unknown),
      do: {:refuse, "mix.exs defines a function the slice cannot name"},
      else: :ok
  end

  ## Dynamic evaluation anywhere in the file

  defp static(ast) do
    if walk_any?(ast, &dynamic?/1),
      do: {:refuse, "mix.exs evaluates code dynamically"},
      else: :ok
  end

  defp dynamic?({{:., _, [mod, fun]}, _, _}) when is_atom(fun) do
    module = module_of(mod)
    module in @dynamic_modules or {module, fun} in [{Kernel, :apply}, {:erlang, :apply}]
  end

  defp dynamic?({:&, _, [{:/, _, [{name, _, ctx}, _arity]}]}) when is_atom(name) and is_atom(ctx),
    do: name in @dynamic_locals

  defp dynamic?({name, _, args}) when is_atom(name) and is_list(args),
    do: name in @dynamic_locals

  defp dynamic?(_node), do: false

  defp module_of({:__aliases__, _, parts}) when is_list(parts) do
    if Enum.all?(parts, &is_atom/1), do: Module.concat(parts), else: :unknown
  end

  defp module_of({:__MODULE__, _, ctx}) when is_atom(ctx), do: :self
  defp module_of(atom) when is_atom(atom), do: atom
  defp module_of(_expr), do: :unknown

  ## Index of the module body

  # %{defs: %{{name, arity} => [entry]}, attrs: %{name => [entry]}, others: [entry]}
  # with entry = %{ast, guard}; `guard` is the module-body conditional the
  # statement sits in (the outermost one), or nil.
  defp index(stmts),
    do: Enum.reduce(stmts, %{defs: %{}, attrs: %{}, others: []}, &index_stmt(&1, &2, nil))

  defp index_stmt({kind, _, [head | _]} = ast, acc, guard) when kind in [:def, :defp] do
    entry = %{ast: ast, guard: guard}
    %{acc | defs: Map.update(acc.defs, signature(head), [entry], &[entry | &1])}
  end

  defp index_stmt({:@, _, [{name, _, [expr]}]}, acc, guard) when is_atom(name) do
    entry = %{ast: expr, guard: guard}
    %{acc | attrs: Map.update(acc.attrs, name, [entry], &[entry | &1])}
  end

  defp index_stmt({kind, _, args} = node, acc, guard)
       when kind in @conditionals and is_list(args) do
    node |> nested_statements() |> Enum.reduce(acc, &index_stmt(&1, &2, guard || node))
  end

  defp index_stmt({:__block__, _, stmts}, acc, guard),
    do: Enum.reduce(stmts, acc, &index_stmt(&1, &2, guard))

  defp index_stmt(other, acc, guard),
    do: %{acc | others: [%{ast: other, guard: guard} | acc.others]}

  defp nested_statements({_kind, _, args}) do
    Enum.flat_map(args, fn
      kw when is_list(kw) -> Enum.flat_map(kw, &branch/1)
      _ -> []
    end)
  end

  defp branch({key, clauses}) when key in [:do, :else] and is_list(clauses),
    do: Enum.flat_map(clauses, &clause_body/1)

  defp branch({key, body}) when key in [:do, :else], do: statements(body)
  defp branch(_other), do: []

  defp clause_body({:->, _, [_patterns, body]}), do: statements(body)
  defp clause_body(_other), do: []

  defp signature({:when, _, [call | _]}), do: signature(call)
  defp signature({name, _, args}) when is_atom(name) and is_list(args), do: {name, length(args)}
  defp signature({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: {name, 0}
  defp signature(_head), do: :unknown

  defp def_entries(index),
    do: for({{name, _arity}, entries} <- index.defs, entry <- entries, do: {name, entry})

  defp attr_entries(index),
    do: for({name, entries} <- index.attrs, entry <- entries, do: {name, entry})

  defp defined_names(index), do: MapSet.new(index.defs, fn {{name, _}, _} -> name end)

  ## Taint

  defp taint(index, line) do
    seeded? = fn %{ast: ast, guard: guard} -> has_line?(ast, line) or has_line?(guard, line) end
    funs = for {name, entry} <- def_entries(index), seeded?.(entry), into: MapSet.new(), do: name

    attrs =
      for {name, entry} <- attr_entries(index), seeded?.(entry), into: MapSet.new(), do: name

    if MapSet.size(funs) == 0 and MapSet.size(attrs) == 0,
      do: {:refuse, "observation outside every definition"},
      else: {:ok, spread(index, %{funs: funs, attrs: attrs})}
  end

  defp spread(index, tainted) do
    hit? = fn %{ast: ast, guard: guard} -> refers?(ast, tainted) or refers?(guard, tainted) end

    next = %{
      funs: for({name, entry} <- def_entries(index), hit?.(entry), into: tainted.funs, do: name),
      attrs:
        for({name, entry} <- attr_entries(index), hit?.(entry), into: tainted.attrs, do: name)
    }

    if next == tainted, do: tainted, else: spread(index, next)
  end

  defp body_statements(index, tainted) do
    if Enum.any?(index.others, &(refers?(&1.ast, tainted) or refers?(&1.guard, tainted))),
      do: {:refuse, "reaches a module-body statement"},
      else: :ok
  end

  ## project/0 and application/0

  defp check(index, tainted, line) do
    with {:ok, entries} <- project_entries(index),
         :ok <- check_entries(entries, index, tainted, line) do
      check_application(index, tainted)
    end
  end

  defp check_application(index, tainted) do
    asts = for {{:application, _}, entries} <- index.defs, entry <- entries, do: entry.ast

    if MapSet.member?(tainted.funs, :application) or not Enum.all?(asts, &closed?(&1, index)),
      do: {:refuse, "reaches application/0"},
      else: :ok
  end

  defp project_entries(index) do
    case Map.get(index.defs, {:project, 0}) do
      [%{ast: ast, guard: nil}] -> ast |> def_body() |> keyword_entries(index, 0)
      _ -> {:refuse, "project/0 is not one plain definition"}
    end
  end

  defp def_body({_kind, _, [_head, [do: body]]}), do: body
  defp def_body(_ast), do: :invalid

  @not_literal {:refuse, "project/0 is not a keyword list literal"}

  defp keyword_entries(_ast, _index, depth) when depth > 8, do: @not_literal

  defp keyword_entries(list, _index, _depth) when is_list(list) do
    if Enum.all?(list, &match?({key, _} when is_atom(key), &1)),
      do: {:ok, list},
      else: @not_literal
  end

  defp keyword_entries({:++, _, [left, right]}, index, depth) do
    with {:ok, l} <- keyword_entries(left, index, depth + 1),
         {:ok, r} <- keyword_entries(right, index, depth + 1),
         do: {:ok, l ++ r}
  end

  defp keyword_entries({name, _, args}, index, depth) when is_atom(name) and args in [[], nil] do
    case Map.get(index.defs, {name, 0}) do
      [%{ast: ast, guard: nil}] -> keyword_entries(def_body(ast), index, depth + 1)
      _ -> @not_literal
    end
  end

  defp keyword_entries(_ast, _index, _depth), do: @not_literal

  defp check_entries(entries, index, tainted, line) do
    case Enum.find(entries, &tainted_entry?(&1, index, tainted, line)) do
      nil -> :ok
      {key, _value} -> {:refuse, "sets #{key}"}
    end
  end

  defp tainted_entry?({key, value}, index, tainted, line) do
    relevant?(key, value, index) and
      (has_line?(value, line) or refers?(value, tainted) or not closed?(value, index))
  end

  defp relevant?(:aliases, value, index) do
    case keyword_entries(value, index, 0) do
      {:ok, aliases} -> Enum.any?(aliases, fn {k, _} -> compile_alias?(k) end)
      _ -> true
    end
  end

  defp relevant?(key, _value, _index), do: key not in @not_compile_relevant

  defp compile_alias?(key), do: key |> Atom.to_string() |> String.starts_with?("compile")

  ## Closedness: everything a key reaches calls only allowed code

  defp closed?(ast, index) do
    defined = defined_names(index)
    index |> reach([ast], MapSet.new(), MapSet.new()) |> Enum.all?(&calls_allowed?(&1, defined))
  end

  # Every AST the value reaches through local calls and attributes, with the
  # module-body conditions those definitions sit under.
  defp reach(_index, [], _seen, acc), do: MapSet.to_list(acc)

  defp reach(index, [ast | rest], seen, acc) do
    if MapSet.member?(acc, ast) do
      reach(index, rest, seen, acc)
    else
      refs = references(ast) |> Enum.reject(&MapSet.member?(seen, &1))
      seen = Enum.into(refs, seen)
      reach(index, Enum.flat_map(refs, &code_of(index, &1)) ++ rest, seen, MapSet.put(acc, ast))
    end
  end

  defp code_of(index, {:fun, name}) do
    for {{^name, _}, entries} <- index.defs,
        entry <- entries,
        part <- [entry.ast, entry.guard],
        part != nil,
        do: part
  end

  defp code_of(index, {:attr, name}) do
    for entry <- Map.get(index.attrs, name, []),
        part <- [entry.ast, entry.guard],
        part != nil,
        do: part
  end

  defp references(ast) do
    {_ast, refs} = Macro.prewalk(ast, MapSet.new(), &collect_ref/2)
    refs
  end

  defp collect_ref({:@, _, [{name, _, ctx}]} = node, refs) when is_atom(name) and is_atom(ctx),
    do: {node, MapSet.put(refs, {:attr, name})}

  defp collect_ref({:., _, [_mod, fun]} = node, refs) when is_atom(fun),
    do: {node, MapSet.put(refs, {:fun, fun})}

  defp collect_ref({name, _, args} = node, refs)
       when is_atom(name) and (is_list(args) or is_atom(args)),
       do: {node, MapSet.put(refs, {:fun, name})}

  defp collect_ref(node, refs), do: {node, refs}

  defp calls_allowed?(ast, defined), do: not walk_any?(ast, &disallowed_call?(&1, defined))

  defp disallowed_call?({{:., _, [mod, fun]}, _, args}, defined)
       when is_atom(fun) and is_list(args),
       do: not remote_allowed?(module_of(mod), fun, defined)

  defp disallowed_call?({:&, _, [{:/, _, [{name, _, ctx}, _arity]}]}, defined)
       when is_atom(name) and is_atom(ctx),
       do: not local_allowed?(name, defined)

  defp disallowed_call?({:receive, _, _}, _defined), do: true

  defp disallowed_call?({name, _, args}, defined) when is_atom(name) and is_list(args),
    do: not local_allowed?(name, defined)

  defp disallowed_call?(_node, _defined), do: false

  defp remote_allowed?(:self, fun, defined), do: MapSet.member?(defined, fun)

  defp remote_allowed?(module, fun, _defined),
    do: module in @allowed_modules or {module, fun} in @allowed_remote

  defp local_allowed?(name, defined),
    do: MapSet.member?(defined, name) or MapSet.member?(@kernel_locals, name)

  ## AST walks

  defp walk_any?(nil, _pred), do: false

  defp walk_any?(ast, pred) do
    {_ast, found?} =
      Macro.prewalk(ast, false, fn
        node, true -> {node, true}
        node, false -> {node, pred.(node)}
      end)

    found?
  end

  defp has_line?(ast, line), do: walk_any?(ast, &on_line?(&1, line))

  defp on_line?({_, meta, _}, line) when is_list(meta), do: Keyword.get(meta, :line) == line
  defp on_line?(_node, _line), do: false

  defp refers?(ast, tainted), do: walk_any?(ast, &tainted_ref?(&1, tainted))

  defp tainted_ref?({:@, _, [{name, _, ctx}]}, %{attrs: attrs})
       when is_atom(name) and is_atom(ctx),
       do: MapSet.member?(attrs, name)

  # A remote call by a tainted name (`__MODULE__.version()`, or any module:
  # over-approximation) and every local call, capture or no-parens
  # reference, by name whatever the arity.
  defp tainted_ref?({:., _, [_mod, fun]}, %{funs: funs}) when is_atom(fun),
    do: MapSet.member?(funs, fun)

  defp tainted_ref?({name, _, args}, %{funs: funs})
       when is_atom(name) and (is_list(args) or is_atom(args)),
       do: MapSet.member?(funs, name)

  defp tainted_ref?(_node, _tainted), do: false
end
