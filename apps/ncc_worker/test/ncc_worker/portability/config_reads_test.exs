defmodule NccWorker.Portability.ConfigReadsTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability.{ConfigReads, Context}

  @elixir "1.19.5"

  # Every owner's dependency tree, as `ConfigReads.trees/1` gives it.
  @trees %{
    "pkg" => ["dep", "fx", "phoenix_live_view", "pkg"],
    "dep" => ["dep", "phoenix_live_view"]
  }

  defp read(app, key, opts \\ []) do
    %{
      "mfa" => Keyword.get(opts, :mfa, "application:get_env/2"),
      "arg" => %{
        "app" => app,
        "key" => key,
        "app_name" => app,
        "key_name" => key,
        "atoms" => Keyword.get(opts, :atoms, true)
      },
      "module" => "Elixir.Pkg",
      "file" => "lib/pkg.ex",
      "line" => 3,
      "first" => Keyword.get(opts, :first, "Elixir.Pkg"),
      "first_kind" => Keyword.get(opts, :kind, "user"),
      "extent" => "frame"
    }
  end

  defp obs(owner, item), do: {owner, {:observe, "config_reads", item}}
  defp snap(entries, truncated \\ false), do: %{entries: entries, truncated: truncated}

  defp enc(term),
    do: term |> :erlang.term_to_binary([:deterministic]) |> Base.url_encode64(padding: false)

  defp keys(result), do: Enum.map(result.items, &{&1.app, &1.path})
  defp judge(decided, snapshot), do: ConfigReads.judge(decided, @elixir, snapshot, @trees, %{})

  test "the closure's reads are recorded once, valued from the snapshot, :error when unset" do
    decided = [
      obs("pkg", read("fx", "k")),
      obs("dep", read("phoenix_live_view", "root_tag_attribute")),
      obs("pkg", read("fx", "k")),
      {"pkg", :ignore}
    ]

    result = judge(decided, snap(%{{"fx", "k"} => enc({:ok, 42})}))

    assert %{refusals: [], problems: [], unreviewed: []} = result

    assert result.items == [
             %{app: "fx", path: ["k"], value: enc({:ok, 42})},
             %{app: "phoenix_live_view", path: ["root_tag_attribute"], value: enc(:error)}
           ]

    assert ConfigReads.unset() == enc(:error)
  end

  test "a key the snapshot holds records its value, whoever reads it" do
    decided = [obs(:outside, read("other", "k")), obs("dep", read("fx", "k"))]
    entries = %{{"other", "k"} => enc({:ok, :set}), {"fx", "k"} => enc({:ok, 1})}

    assert %{problems: [], items: items} = judge(decided, snap(entries))

    assert items == [
             %{app: "fx", path: ["k"], value: enc({:ok, 1})},
             %{app: "other", path: ["k"], value: enc({:ok, :set})}
           ]
  end

  # The two-dependency closure that shows the compile-order dependence: `a`
  # sets `k` in its .app env, `r` reads `Application.get_env(:a, :k)` at
  # compile time. Mix loads a dependency's .app once it has compiled it, so
  # `r` sees the default when `a` is in its tree (always compiled first) and
  # otherwise only when the consumer's dependency graph happens to compile
  # `a` first.
  describe "a read of a key the project leaves unset" do
    defp ctx(r_children) do
      dep = %{dest: nil, build: nil, manager: "mix", native?: false, hex_files: nil}

      %Context{
        deps: %{
          "a" => Map.put(dep, :children, []),
          "r" => Map.put(dep, :children, r_children)
        }
      }
    end

    test "is unset when the app is in the reader's dependency tree" do
      trees = ConfigReads.trees(ctx(["a"]))
      assert trees == %{"a" => ["a"], "r" => ["a", "r"]}

      result = ConfigReads.judge([obs("r", read("a", "k"))], @elixir, snap(%{}), trees, %{})
      assert %{problems: [], items: [%{app: "a", path: ["k"], value: value}]} = result
      assert value == ConfigReads.unset()
    end

    test "is unset when the reader reads its own app" do
      trees = ConfigReads.trees(ctx([]))
      result = ConfigReads.judge([obs("r", read("r", "k"))], @elixir, snap(%{}), trees, %{})
      assert %{problems: [], items: [%{app: "r", value: value}]} = result
      assert value == ConfigReads.unset()
    end

    test "cannot be told when the app is outside the reader's tree" do
      trees = ConfigReads.trees(ctx([]))

      assert %{items: [], problems: ["config value cannot be told: a k"]} =
               ConfigReads.judge([obs("r", read("a", "k"))], @elixir, snap(%{}), trees, %{})
    end

    test "cannot be told when any of its readers has the app outside its tree" do
      trees = ConfigReads.trees(ctx([]))
      decided = [obs("a", read("a", "k")), obs("r", read("a", "k"))]

      assert %{items: [], problems: ["config value cannot be told: a k"]} =
               ConfigReads.judge(decided, @elixir, snap(%{}), trees, %{})
    end

    test "cannot be told outside every window" do
      assert %{items: [], problems: ["config value cannot be told: fx k"]} =
               judge([obs(:outside, read("fx", "k"))], snap(%{}))
    end

    test "is unset for an application Mix loads before every compile" do
      decided =
        for app <- ~w(elixir mix ex_unit iex logger),
            owner <- [:outside, "dep"],
            do: obs(owner, read(app, "unset_key"))

      result = judge(decided, snap(%{}))
      assert result.problems == []
      assert length(result.items) == 5
      assert Enum.all?(result.items, &(&1.value == ConfigReads.unset()))
    end
  end

  # Hex's config is the builder's: its API and mirror URLs, repos, proxies
  # and keys. A beam that depends on it is not portable, and its value must
  # never reach a public manifest, set or not.
  test "a read of Hex's config cannot be judged, from any frame" do
    entries = %{
      {"hex", "api_url"} => enc({:ok, "https://hex.example.invalid/api"}),
      {"hex", "mirror_url"} => enc({:ok, "https://mirror.example.invalid"})
    }

    for key <- ~w(api_url mirror_url repos http_proxy),
        {kind, first} <- [{"user", "Elixir.Pkg"}, {"toolchain", "Elixir.Mix.Project"}],
        owner <- [:outside, "pkg", "dep"] do
      result = judge([obs(owner, read("hex", key, kind: kind, first: first))], snap(entries))

      assert %{items: [], refusals: [], problems: [problem]} = result
      assert problem == "builder config read: hex #{key}"
      refute inspect(result) =~ "example.invalid"
    end

    # The rest of the closure's reads are judged as before, and only Hex's
    # hold the build back.
    decided = [obs("pkg", read("fx", "k")), obs("pkg", read("hex", "api_url"))]
    result = judge(decided, snap(Map.put(entries, {"fx", "k"}, enc({:ok, 1}))))
    assert keys(result) == [{"fx", ["k"]}]
    assert result.problems == ["builder config read: hex api_url"]
  end

  test "toolchain reads: reviewed ones recorded or dropped, any other one cannot be judged" do
    decided = [
      obs(
        "pkg",
        read("logger", "compile_time_purge_matching", kind: "toolchain", first: "Elixir.Logger")
      ),
      obs(
        "pkg",
        read("logger", "compile_time_purge_level", kind: "toolchain", first: "Elixir.Logger")
      ),
      obs(
        "pkg",
        read("elixir", "ansi_enabled", kind: "toolchain", first: "Elixir.Mix.Shell.IO")
      )
    ]

    result = judge(decided, snap(%{}))

    assert keys(result) == [
             {"logger", ["compile_time_purge_level"]},
             {"logger", ["compile_time_purge_matching"]}
           ]

    assert %{problems: [], unreviewed: [], dropped: 1} = result

    unknown = [
      obs("dep", read("mix", "unknown_key", kind: "toolchain", first: "Elixir.Mix.Project"))
    ]

    assert %{items: [], problems: [problem], unreviewed: [flagged]} = judge(unknown, snap(%{}))
    assert problem == "unreviewed toolchain config read: mix unknown_key from Elixir.Mix.Project"
    assert %{"owner" => "dep", "arg" => %{"key_name" => "unknown_key"}} = flagged
  end

  test "Mix's shell's and Logger's handler's :elixir ansi_enabled is never recorded, set or not" do
    decided =
      for first <- ["Elixir.Mix.Shell.IO", "logger_h_common"],
          do: obs("pkg", read("elixir", "ansi_enabled", kind: "toolchain", first: first))

    entries = %{{"elixir", "ansi_enabled"} => enc({:ok, true})}

    assert %{items: [], problems: [], dropped: 2} = judge(decided, snap(entries))
  end

  # The type checker's coloured text only reaches its diagnostics, which go
  # to Mix unless package code compiled something itself, or captured
  # diagnostics, in the same window: then the text can reach the package.
  describe "the type checker's :elixir ansi_enabled read" do
    defp types_obs(owner),
      do:
        obs(
          owner,
          read("elixir", "ansi_enabled", kind: "toolchain", first: "Elixir.Module.Types.Apply")
        )

    test "is dropped in a window where package code compiled nothing itself" do
      entries = %{{"elixir", "ansi_enabled"} => enc({:ok, true})}
      nested = %{"other" => "Code.compile_string/2"}

      assert %{items: [], problems: [], unreviewed: [], dropped: 1} =
               ConfigReads.judge([types_obs("pkg")], "1.20.4", snap(entries), @trees, nested)
    end

    test "cannot be judged in a window with a nested compile or a diagnostics capture" do
      nested = %{"pkg" => "Code.with_diagnostics/2"}

      assert %{items: [], dropped: 0, unreviewed: [], problems: [problem]} =
               ConfigReads.judge([types_obs("pkg")], "1.20.4", snap(%{}), @trees, nested)

      assert problem ==
               "toolchain config read in a window with a nested compile (Code.with_diagnostics/2):" <>
                 " elixir ansi_enabled from Elixir.Module.Types.Apply"
    end

    test "a mark outside every window counts for reads outside every window" do
      nested = %{outside: "Kernel.ParallelCompiler.compile/2"}

      assert %{dropped: 0, problems: [_]} =
               ConfigReads.judge([types_obs(:outside)], "1.20.4", snap(%{}), @trees, nested)
    end

    test "the other output-only drops do not depend on the window" do
      decided =
        for first <- ["Elixir.Mix.Shell.IO", "logger_h_common", "elixir_errors"],
            do: obs("pkg", read("elixir", "ansi_enabled", kind: "toolchain", first: first))

      nested = %{"pkg" => "Code.with_diagnostics/2"}

      assert %{problems: [], dropped: 3} =
               ConfigReads.judge(decided, "1.20.4", snap(%{}), @trees, nested)
    end
  end

  # IO.ANSI.format/1,2, format_fragment/1,2 and Logger.Formatter.format/2
  # bake escape codes, or none, by the same key: only the reads made for
  # Mix's shell and Logger's handler are reviewed as dropped, each matched
  # on that first frame only.
  test "another toolchain frame's :elixir ansi_enabled read cannot be judged" do
    for first <- ["Elixir.IO.ANSI", "Elixir.IO", "Elixir.Logger.Formatter", "logger_std_h"] do
      decided = [obs("pkg", read("elixir", "ansi_enabled", kind: "toolchain", first: first))]

      assert %{items: [], dropped: 0, problems: [problem]} = judge(decided, snap(%{}))
      assert problem == "unreviewed toolchain config read: elixir ansi_enabled from #{first}"
    end
  end

  # OTP's certificate store, TLS version table and socket options read
  # their own application env only on the way to the host's CA store, its
  # crypto library or the network: the compile reached the host.
  test "OTP's certificate, TLS and socket config reads refuse, from those frames only" do
    reads = [
      {"pubkey_os_cacerts", "public_key", "cacerts_path"},
      {"tls_record", "ssl", "protocol_version"},
      {"dtls_record", "ssl", "dtls_protocol_version"},
      {"inet", "kernel", "inet_default_connect_options"}
    ]

    for elixir <- ["1.19.5", "1.20.4"],
        do: assert(Enum.sort(ConfigReads.reviewed(elixir).refuse) == Enum.sort(reads))

    for {first, app, key} <- reads do
      decided = [obs("dep", read(app, key, kind: "toolchain", first: first))]

      assert %{items: [], problems: [], unreviewed: [], refusals: [{"dep", {:refuse, why}}]} =
               judge(decided, snap(%{}))

      assert why ==
               "compile-time config read: application:get_env/2 (#{app}) #{key} " <>
                 "is read by OTP's certificate, TLS or socket code (#{first}): " <>
                 "the compile reached the host's CA store, crypto or network in Pkg (lib/pkg.ex:3)"

      # Package code reading the same key itself records it, and another
      # toolchain frame's read stays unreviewed.
      set = snap(%{{app, key} => enc({:ok, 1})})
      assert keys(judge([obs("dep", read(app, key))], set)) == [{app, [key]}]

      other = [obs("dep", read(app, key, kind: "toolchain", first: "ssl_config"))]
      assert %{refusals: [], problems: [_]} = judge(other, snap(%{}))
    end
  end

  test "a read reached through glue, or with no first frame, is the package's own" do
    decided = [
      obs("pkg", read("elixir", "ansi_enabled", kind: "glue", first: "Elixir.Enum")),
      obs("pkg", read("fx", "y", kind: "none"))
    ]

    assert keys(judge(decided, snap(%{}))) == [{"elixir", ["ansi_enabled"]}, {"fx", ["y"]}]
  end

  test "a toolchain read on a toolchain with no reviewed lists cannot be judged" do
    decided = [
      obs(
        "pkg",
        read("logger", "compile_time_purge_level", kind: "toolchain", first: "Elixir.Logger")
      )
    ]

    assert %{items: [], problems: ["no reviewed config reads for Elixir 1.99"]} =
             ConfigReads.judge(decided, "1.99.0", snap(%{}), @trees, %{})

    assert ConfigReads.reviewed("1.99.0") == nil
    assert ConfigReads.reviewed(nil) == nil

    output = [
      {"Elixir.Mix.Shell.IO", "elixir", "ansi_enabled"},
      {"logger_h_common", "elixir", "ansi_enabled"},
      {"elixir_errors", "elixir", "ansi_enabled"}
    ]

    for {elixir, drop} <- [
          {"1.19.5", output ++ [{"Elixir.Module.Types.Apply", "elixir", "ansi_enabled"}]},
          {"1.20.4", output ++ [{"Elixir.Module.Types.Apply", "elixir", "ansi_enabled"}]}
        ] do
      assert %{record: [_ | _], drop: ^drop} = ConfigReads.reviewed(elixir)
    end
  end

  test "get_all_env refuses from package code, cannot be judged from the toolchain's; get_env/1 is ignored" do
    all = fn kind ->
      %{
        read("phoenix", nil, kind: kind, mfa: "application:get_all_env/1")
        | "arg" => %{"app" => "phoenix", "app_name" => "phoenix", "all" => true}
      }
    end

    assert %{refusals: [{"pkg", {:refuse, reason}}], items: []} =
             judge([obs("pkg", all.("user"))], snap(%{}))

    assert reason ==
             "compile-time config read: application:get_all_env/1 (phoenix) has no key to match on" <>
               " in Pkg (lib/pkg.ex:3)"

    assert %{refusals: [], items: [], unreviewed: [_], problems: [problem]} =
             judge([obs("pkg", all.("toolchain"))], snap(%{}))

    assert problem ==
             "unreviewed toolchain config read: application:get_all_env/1 (phoenix) from Elixir.Pkg"

    one = %{
      read(nil, "k", mfa: "application:get_env/1")
      | "arg" => %{"app" => nil, "key_name" => "k", "atoms" => false}
    }

    assert %{items: [], refusals: []} = judge([obs("pkg", one)], snap(%{}))
  end

  test "a non-atom application or key refuses" do
    assert %{refusals: [{"pkg", {:refuse, "compile-time config read: " <> _}}]} =
             judge([obs("pkg", read("fx", "k", atoms: false))], snap(%{}))
  end

  test "values that cannot be told cannot be judged" do
    decided = [obs("pkg", read("fx", "k"))]

    assert %{items: [], problems: ["no config snapshot"]} = judge(decided, nil)
    assert %{problems: ["no config snapshot"]} = judge(decided, :error)
    assert %{problems: ["config snapshot truncated"]} = judge(decided, snap(%{}, true))

    assert %{problems: ["config value too large: fx k"]} =
             judge(decided, snap(%{{"fx", "k"} => :oversize}))

    # Nothing recorded, nothing to value.
    assert %{items: [], problems: []} = judge([], nil)
  end

  test "more than 500 distinct reads cannot be judged" do
    decided = for i <- 1..501, do: obs("pkg", read("fx", "k#{i}"))

    assert %{items: [], problems: ["more than 500 config reads"]} = judge(decided, snap(%{}))
  end

  test "merge/2 keeps the .app's items first and never repeats a path" do
    app = [%{app: "fx", path: ["k"], value: "A"}, %{app: "fx", path: ["k", "sub"], value: "B"}]
    r5 = [%{app: "fx", path: ["k"], value: "C"}, %{app: "lv", path: ["x"], value: "D"}]

    assert ConfigReads.merge(app, r5) == app ++ [%{app: "lv", path: ["x"], value: "D"}]
    assert ConfigReads.merge([], r5) == r5
    assert ConfigReads.merge(nil, r5) == nil
  end

  # The reviewed `record` list pins Logger's compile-time reads: every
  # Application.get_env/fetch_env/compile_env of a literal :logger key that
  # Logger's macros run while they expand (their bodies and the module's
  # functions they call, outside `quote` but inside `unquote`), read from the
  # running Elixir's own Logger source. The `drop` list pins Mix's shell:
  # IO.ANSI's only read of `:elixir, :ansi_enabled` is `enabled?/0`, and every
  # IO.ANSI call in `Mix.Shell.IO` hands its result straight to IO.puts/write,
  # so the value reaches the terminal and never code.
  describe "the reviewed list for the running Elixir" do
    test "records exactly what Logger's macros read while they expand" do
      source = Path.join(:code.lib_dir(:logger), "lib/logger.ex")
      assert File.regular?(source), "no Logger source at #{source}"

      read = source |> File.read!() |> Code.string_to_quoted!() |> macro_reads()
      assert read != []

      %{record: record} = ConfigReads.reviewed(System.version())

      assert Enum.sort(record) == Enum.sort(read)
    end

    test "drops only Mix's shell's ansi_enabled read, whose value only reaches output" do
      ansi = source(:elixir, "lib/io/ansi.ex")
      shell = source(:mix, "lib/mix/shell/io.ex")

      assert app_reads(ansi) == [
               {:elixir, :ansi_enabled, :enabled?},
               {:elixir, :ansi_syntax_colors, :syntax_colors}
             ]

      assert app_reads(shell) == []
      assert ansi_enabled_refs(shell) == []

      {direct, all} = ansi_calls(shell)
      assert all != []
      assert direct == all

      assert {"Elixir.Mix.Shell.IO", "elixir", "ansi_enabled"} in ConfigReads.reviewed(
               System.version()
             ).drop
    end

    # Logger.Formatter reads :ansi_enabled only through the `&IO.ANSI.enabled?/0`
    # colouring default, and OTP's handler code calls a formatter only from
    # `try_format/3`, whose text `log_to_binary/2` returns for the handler
    # to write. Every drop key's module is classified afresh on each event.
    test "drops Logger's handler's ansi_enabled read, whose value only reaches output" do
      formatter = source(:logger, "lib/logger/formatter.ex")

      assert app_reads(formatter) == [
               {:logger, :translator_inspect_opts, :translator_inspect_opts},
               {:logger, :truncate, :new},
               {:logger, :utc_log, :new}
             ]

      assert ansi_enabled_refs(formatter) == [:colors]

      forms = handler_forms()

      assert formatter_callers(forms) == [:try_format]
      assert callers(forms, :try_format) == [:do_log_to_binary, :try_format]
      assert callers(forms, :do_log_to_binary) == [:log_to_binary]
      # Within the handler code, the text goes to the handler's process or
      # device: `log/2` loads it into the handler, `log_handler_info/4`
      # writes it. Callers in other modules are not pinned.
      assert callers(forms, :log_to_binary) == [:log, :log_handler_info]

      for {first, _app, _key} <- ConfigReads.reviewed(System.version()).drop,
          do: assert(String.to_atom(first) in :ncc_tracer_stack.uncached(), first)

      assert {"logger_h_common", "elixir", "ansi_enabled"} in ConfigReads.reviewed(
               System.version()
             ).drop
    end

    # The compiler's diagnostics module reads :ansi_enabled in one function,
    # reached only through `format_snippet/6`. The functions that call it
    # write the text to standard error; the tracer keeps the module first
    # only while one of them is on the stack (`printers/0`), and classifies
    # it afresh on every event. Elixir installs often ship no `src`, so the
    # forms come from the beam's abstract code then.
    test "drops the compiler diagnostics printer's ansi_enabled read, whose value only reaches output" do
      source = Path.join(:code.lib_dir(:elixir), "src/elixir_errors.erl")
      forms = module_forms(:elixir_errors, source)

      assert key_readers(forms, :ansi_enabled) == [:highlight]

      assert Enum.sort(callers(forms, :highlight)) ==
               [:highlight_at_position, :highlight_below_line, :prefix]

      for via <- [:highlight_at_position, :highlight_below_line, :prefix],
          do: assert(callers(forms, via) == [:format_snippet], inspect(via))

      assert [{:elixir_errors, printers}] = :ncc_tracer_stack.printers()
      assert Enum.sort(callers(forms, :format_snippet)) == Enum.sort(printers)

      for printer <- printers do
        assert writes_stderr?(forms, printer), inspect(printer)
        # What a printer returns is the write's result or the diagnostic it
        # was given, never the formatted text.
        assert returns_no_text?(forms, printer), inspect(printer)
      end

      assert :elixir_errors in :ncc_tracer_stack.uncached()

      assert {"elixir_errors", "elixir", "ansi_enabled"} in ConfigReads.reviewed(System.version()).drop
    end

    # The type checker asks IO.ANSI.enabled?/0 in one function of
    # Module.Types.Apply, whose text only ever becomes part of a diagnostic:
    # format_diagnostic/1, which no toolchain module calls except
    # Module.ParallelChecker's grouping function. That function is called
    # only by the one that checks a module, which hands the diagnostics to
    # the function that prints them and returns them to the compiler. The
    # forms are the beam's abstract code; the test below compares them with
    # the source where the install ships it.
    test "drops the type checker's ansi_enabled read, whose value only reaches diagnostics" do
      forms = beam_forms(Module.Types.Apply, "")

      assert remote_callers(forms, IO.ANSI, :enabled?) == [:ansi_red]
      assert callers(forms, :ansi_red) == [:args_to_quoted_string]
      assert callers(forms, :args_to_quoted_string) == [:format_diagnostic]

      checker = beam_forms(Module.ParallelChecker, "")

      assert [{Module.Types.Apply, :ansi_red, Module.ParallelChecker, groupers}] =
               :ncc_tracer_stack.diagnosers()

      assert [grouper] = Enum.filter(groupers, &defined?(checker, &1))
      assert dynamic_callers(checker, :format_diagnostic) == [grouper]
      assert remote_callers(checker, Module.Types.Apply, :format_diagnostic) == []
      # Its result goes only to the function that checks a module, which
      # pipes it into the one that prints and returns the diagnostics.
      assert callers(checker, grouper) == [:check_module]
      assert [emit] = callers_of_result(checker, :check_module, grouper)
      assert emit in [:emit_diagnostics, :emit_warnings]
      assert prints?(checker, emit)

      # No other module of the toolchain calls a format_diagnostic/1 of a
      # module it does not name, or Apply's by name.
      for module <- toolchain_modules(), module != Module.ParallelChecker do
        forms = beam_forms(module, "")
        assert dynamic_callers(forms, :format_diagnostic) == [], inspect(module)

        assert remote_callers(forms, Module.Types.Apply, :format_diagnostic) == [],
               inspect(module)
      end

      assert Module.Types.Apply in :ncc_tracer_stack.uncached()

      assert {"Elixir.Module.Types.Apply", "elixir", "ansi_enabled"} in ConfigReads.reviewed(
               System.version()
             ).drop
    end

    # The type checker's pin above runs on the beam's abstract code. Where
    # the install ships the Elixir source, its call graph must agree.
    test "the type checker's abstract code gives the same call graph as its source" do
      apply_src = Path.join(:code.lib_dir(:elixir), "lib/module/types/apply.ex")
      checker_src = Path.join(:code.lib_dir(:elixir), "lib/module/parallel_checker.ex")
      [{_, _, _, groupers}] = :ncc_tracer_stack.diagnosers()

      if File.regular?(apply_src) and File.regular?(checker_src) do
        apply_ast = apply_src |> File.read!() |> Code.string_to_quoted!()
        apply_forms = beam_forms(Module.Types.Apply, apply_src)

        assert ansi_enabled_refs(apply_ast) ==
                 Enum.sort(remote_callers(apply_forms, IO.ANSI, :enabled?))

        for target <- [:ansi_red, :args_to_quoted_string],
            do: assert(ex_callers(apply_ast, target) == Enum.sort(callers(apply_forms, target)))

        checker_ast = checker_src |> File.read!() |> Code.string_to_quoted!()
        checker_forms = beam_forms(Module.ParallelChecker, checker_src)

        assert ex_dynamic_callers(checker_ast, :format_diagnostic) ==
                 Enum.sort(dynamic_callers(checker_forms, :format_diagnostic))

        for grouper <- groupers,
            defined?(checker_forms, grouper),
            do:
              assert(
                ex_callers(checker_ast, grouper) == Enum.sort(callers(checker_forms, grouper))
              )
      else
        refute File.exists?(apply_src) and File.exists?(checker_src)

        for name <- [:ansi_red, :args_to_quoted_string, :format_diagnostic],
            do: assert(defined?(beam_forms(Module.Types.Apply, ""), name), inspect(name))
      end
    end

    # The pins above read a module's source when the install ships `src` and
    # its beam's abstract code otherwise. Where `src` exists, the two must
    # give the same call graph. Where it does not, both sides would come from
    # the beam and a comparison would be trivial, so the test says so and
    # instead requires the functions each pin is scoped to to exist, with
    # clauses, in the beam's abstract code.
    test "a module's beam abstract code gives the same call graph as its source" do
      for {module, app, rel, scoped, targets} <- [
            {:logger_h_common, :kernel, "src/logger_h_common.erl",
             [:try_format, :do_log_to_binary, :log_to_binary],
             [:try_format, :do_log_to_binary, :log_to_binary]},
            {:elixir_errors, :elixir, "src/elixir_errors.erl",
             [:highlight, :format_snippet | printer_names()],
             [:highlight, :highlight_at_position, :highlight_below_line, :prefix, :format_snippet]}
          ] do
        source = Path.join(:code.lib_dir(app), rel)
        from_beam = beam_forms(module, source)

        for name <- scoped,
            do: assert(defined?(from_beam, name), "#{module}.#{name} not in the abstract code")

        if File.regular?(source) do
          {:ok, from_source} = :epp.parse_file(String.to_charlist(source), [])

          for target <- targets,
              do:
                assert(
                  callers(from_beam, target) == callers(from_source, target),
                  inspect(target)
                )
        else
          # No `src` in this install: the pins ran on the beam's abstract
          # code, which the scoped functions above are checked to be in.
          refute File.exists?(source)
        end
      end
    end
  end

  # Each refused read's key is read in one function of its module, on the
  # way to the host: `pubkey_os_cacerts:get/0` loads the host's CA store,
  # the TLS and DTLS version tables check this host's crypto library for
  # each version, and `inet:connect_options/2` builds a connection's
  # socket options.
  test "the refused reads are each read in the one function that reaches the host" do
    for {module, app, key, reader} <- [
          {:pubkey_os_cacerts, :public_key, :cacerts_path, :get},
          {:tls_record, :ssl, :protocol_version, :supported_protocol_versions},
          {:dtls_record, :ssl, :dtls_protocol_version, :supported_protocol_versions},
          {:inet, :kernel, :inet_default_connect_options, :connect_options}
        ] do
      forms = module_forms(module, Path.join(:code.lib_dir(app), "src/#{module}.erl"))
      assert env_readers(forms, app, key) == [reader], inspect(module)

      assert {"#{module}", "#{app}", "#{key}"} in ConfigReads.reviewed(System.version()).refuse
    end

    cacerts_src = Path.join(:code.lib_dir(:public_key), "src/pubkey_os_cacerts.erl")
    assert :get in callers(module_forms(:pubkey_os_cacerts, cacerts_src), :load)

    for {module, check} <- [
          tls_record: :sufficient_support,
          dtls_record: :sufficient_dtlsv1_2_crypto_support
        ] do
      forms = module_forms(module, Path.join(:code.lib_dir(:ssl), "src/#{module}.erl"))
      assert :supported_protocol_versions in callers(forms, check), inspect(module)
    end
  end

  # OTP's `logger_h_common` forms.
  defp handler_forms,
    do:
      module_forms(:logger_h_common, Path.join(:code.lib_dir(:kernel), "src/logger_h_common.erl"))

  # A toolchain module's forms: from its source when the install carries
  # `src`, otherwise from the beam's own abstract code (OTP and Elixir
  # compile their beams with debug_info). An install with neither fails the
  # pin.
  defp module_forms(module, source) do
    if File.regular?(source) do
      {:ok, forms} = :epp.parse_file(String.to_charlist(source), [])
      forms
    else
      beam_forms(module, source)
    end
  end

  # The functions that call `application:get_env(app, key)`, or any
  # `application` env read of `app` whose key is not that literal (fail
  # closed: a computed key could be `key`).
  defp env_readers(forms, app, key) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:call, _, {:remote, _, {:atom, _, :application}, {:atom, _, f}},
           [{:atom, _, ^app}, k | _]}
          when f in [:get_env, :fetch_env, :get_all_env] ->
            not match?({:atom, _, other} when other != key, k)

          _ ->
            false
        end),
        uniq: true,
        do: name
  end

  # The functions that mention `key` as an atom.
  defp key_readers(forms, key) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:atom, _, ^key} -> true
          _ -> false
        end),
        uniq: true,
        do: name
  end

  defp printer_names do
    [{:elixir_errors, printers}] = :ncc_tracer_stack.printers()
    printers
  end

  defp defined?(forms, name),
    do: Enum.any?(forms, &match?({:function, _, ^name, _, [_ | _]}, &1))

  # Every clause of `name` ends in an `io:put_chars/2` call or in a variable
  # bound in the clause head (an argument handed back unchanged).
  defp returns_no_text?(forms, name) do
    clauses = for {:function, _, ^name, _, clauses} <- forms, clause <- clauses, do: clause

    clauses != [] and
      Enum.all?(clauses, fn {:clause, _, head, _guards, body} ->
        case List.last(body) do
          {:call, _, {:remote, _, {:atom, _, :io}, {:atom, _, :put_chars}}, [_, _]} -> true
          {:var, _, var} -> head_var?(head, var)
          _ -> false
        end
      end)
  end

  defp head_var?(head, var),
    do:
      has_call?(head, fn
        {:var, _, ^var} -> true
        _ -> false
      end)

  defp writes_stderr?(forms, name) do
    Enum.any?(
      for({:function, _, ^name, _, clauses} <- forms, do: clauses),
      &has_call?(&1, fn
        {:call, _, {:remote, _, {:atom, _, :io}, {:atom, _, :put_chars}},
         [{:atom, _, :standard_error} | _]} ->
          true

        _ ->
          false
      end)
    )
  end

  defp beam_forms(module, source) do
    beam = :code.which(module)

    case :beam_lib.chunks(beam, [:abstract_code]) do
      {:ok, {^module, [abstract_code: {:raw_abstract_v1, forms}]}} ->
        forms

      other ->
        flunk(
          "no source at #{source} and no abstract code in #{beam}: #{inspect(other, limit: 5)}"
        )
    end
  end

  # The functions holding a reference to IO.ANSI.enabled?/0 (a call or a capture).
  defp ansi_enabled_refs(ast) do
    {_ast, {_fun, refs}} =
      Macro.prewalk(ast, {nil, []}, fn
        {kind, _, [head | _]} = node, {_fun, acc} when kind in [:def, :defp] ->
          {node, {fun_name(head), acc}}

        {{:., _, [{:__aliases__, _, [:IO, :ANSI]}, :enabled?]}, _, _} = node, {fun, acc} ->
          {node, {fun, [fun | acc]}}

        node, acc ->
          {node, acc}
      end)

    refs |> Enum.uniq() |> Enum.sort()
  end

  # Erlang functions making a `Var:format(...)` call (a formatter callback).
  defp formatter_callers(forms) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:call, _, {:remote, _, {:var, _, _}, {:atom, _, :format}}, _} -> true
          _ -> false
        end),
        uniq: true,
        do: name
  end

  defp callers(forms, target) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:call, _, {:atom, _, ^target}, _} -> true
          _ -> false
        end),
        uniq: true,
        do: name
  end

  # The functions calling `mod:fun` by name.
  defp remote_callers(forms, mod, fun) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:call, _, {:remote, _, {:atom, _, ^mod}, {:atom, _, ^fun}}, _} -> true
          _ -> false
        end),
        uniq: true,
        do: name
  end

  # The functions calling `fun` on a module that is not a literal.
  defp dynamic_callers(forms, fun) do
    for {:function, _, name, _, clauses} <- forms,
        has_call?(clauses, fn
          {:call, _, {:remote, _, {:atom, _, _}, _}, _} -> false
          {:call, _, {:remote, _, _module, {:atom, _, ^fun}}, _} -> true
          _ -> false
        end),
        uniq: true,
        do: name
  end

  # The local functions `inner`'s result is handed to, inside `outer`
  # (`inner(...) |> next(...)` compiles to `next(inner(...), ...)`).
  defp callers_of_result(forms, outer, inner) do
    clauses = for {:function, _, ^outer, _, clauses} <- forms, do: clauses

    clauses
    |> walk([], fn
      {:call, _, {:atom, _, next}, [{:call, _, {:atom, _, ^inner}, _} | _]}, found ->
        [next | found]

      _, found ->
        found
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp walk(term, acc, fun) do
    acc = fun.(term, acc)

    case term do
      t when is_tuple(t) -> t |> Tuple.to_list() |> walk(acc, fun)
      l when is_list(l) -> Enum.reduce(l, acc, &walk(&1, &2, fun))
      _ -> acc
    end
  end

  # Every clause of `name` calls a local function that prints through one
  # of `:elixir_errors`' printing functions.
  defp prints?(forms, name) do
    clauses = for {:function, _, ^name, _, clauses} <- forms, clause <- clauses, do: clause
    printers = printer_names()

    printing? = fn local ->
      Enum.any?(
        for({:function, _, ^local, _, cs} <- forms, do: cs),
        &has_call?(&1, fn
          {:call, _, {:remote, _, {:atom, _, :elixir_errors}, {:atom, _, p}}, _} -> p in printers
          _ -> false
        end)
      )
    end

    clauses != [] and Enum.all?(clauses, &Enum.any?(local_calls(&1), printing?))
  end

  defp local_calls(clause) do
    clause
    |> walk([], fn
      {:call, _, {:atom, _, f}, _}, acc -> [f | acc]
      _, acc -> acc
    end)
    |> Enum.uniq()
  end

  # The installed toolchain's modules: Elixir's and those of the
  # applications that ship with it.
  defp toolchain_modules do
    for app <- [:elixir, :mix, :logger, :eex, :ex_unit, :iex],
        :ok == ensure_loaded_app(app),
        module <- Application.spec(app, :modules) || [],
        do: module
  end

  defp ensure_loaded_app(app) do
    case Application.load(app) do
      :ok -> :ok
      {:error, {:already_loaded, ^app}} -> :ok
      other -> other
    end
  end

  # Elixir source: the def/defp names whose body calls local `target`.
  defp ex_callers(ast, target) do
    ast
    |> ex_functions()
    |> Enum.filter(fn {_name, body} ->
      has_call?(body, fn
        {^target, _, args} when is_list(args) -> true
        _ -> false
      end)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  # Elixir source: the def/defp names whose body calls `fun` on a variable.
  defp ex_dynamic_callers(ast, fun) do
    ast
    |> ex_functions()
    |> Enum.filter(fn {_name, body} ->
      has_call?(body, fn
        {{:., _, [{var, _, ctx}, ^fun]}, _, args}
        when is_atom(var) and is_atom(ctx) and is_list(args) ->
          true

        _ ->
          false
      end)
    end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp ex_functions(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {kind, _, [head, body]} = node, acc when kind in [:def, :defp] ->
          {node, [{fun_name(head), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  defp has_call?(term, match?) do
    match?.(term) or
      case term do
        t when is_tuple(t) -> t |> Tuple.to_list() |> has_call?(match?)
        l when is_list(l) -> Enum.any?(l, &has_call?(&1, match?))
        _ -> false
      end
  end

  defp source(app, rel) do
    path = Path.join(:code.lib_dir(app), rel)
    assert File.regular?(path), "no source at #{path}"
    path |> File.read!() |> Code.string_to_quoted!()
  end

  # Every Application read of a literal app and key, with the function it is in.
  defp app_reads(ast) do
    {_ast, {_fun, reads}} =
      Macro.traverse(
        ast,
        {nil, []},
        fn
          {kind, _, [head | _]} = node, {_fun, acc} when kind in [:def, :defp] ->
            {node, {fun_name(head), acc}}

          {{:., _, [{:__aliases__, _, [:Application]}, f]}, _, [app, key | _]} = node, {fun, acc}
          when f in [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!] ->
            {node, {fun, [{app, key, fun} | acc]}}

          node, acc ->
            {node, acc}
        end,
        fn node, acc -> {node, acc} end
      )

    Enum.sort(reads)
  end

  defp fun_name({:when, _, [head | _]}), do: fun_name(head)
  defp fun_name({name, _, _}), do: name

  # IO.ANSI calls that can depend on the key (format/1,2, format_fragment/1,2),
  # all of them and those passed straight to IO.puts/IO.write.
  defp ansi_calls(ast) do
    {_ast, {direct, all}} =
      Macro.prewalk(ast, {[], []}, fn
        {{:., _, [{:__aliases__, _, [:IO]}, f]}, _, args} = node, {direct, all}
        when f in [:puts, :write] ->
          {node, {Enum.filter(args, &ansi_format?/1) ++ direct, all}}

        node, {direct, all} ->
          if ansi_format?(node), do: {node, {direct, [node | all]}}, else: {node, {direct, all}}
      end)

    {Enum.sort(direct), Enum.sort(all)}
  end

  defp ansi_format?({{:., _, [{:__aliases__, _, [:IO, :ANSI]}, f]}, _, _})
       when f in [:format, :format_fragment],
       do: true

  defp ansi_format?(_node), do: false

  defp macro_reads(ast) do
    {_ast, defs} =
      Macro.prewalk(ast, %{}, fn
        {kind, _, [head, [do: body]]} = node, acc when kind in [:def, :defp, :defmacro] ->
          {node, Map.update(acc, def_name(kind, head), [body], &[body | &1])}

        node, acc ->
          {node, acc}
      end)

    roots = for {{:defmacro, _} = key, _} <- defs, do: key
    funs = Map.new(defs, fn {{_kind, name}, bodies} -> {name, bodies} end)

    roots
    |> Enum.flat_map(&Map.fetch!(defs, &1))
    |> expand(funs, MapSet.new(), MapSet.new())
    |> Enum.sort()
  end

  defp def_name(kind, {:when, _, [head | _]}), do: def_name(kind, head)
  defp def_name(kind, {{:unquote, _, _}, _, _}), do: {kind, :unquote}
  defp def_name(kind, {name, _, _}), do: {kind, name}

  defp expand([], _funs, _seen, reads), do: reads

  defp expand([body | rest], funs, seen, reads) do
    {calls, found} = scan(body, {[], []})
    reads = Enum.into(found, reads)
    new = Enum.reject(Enum.uniq(calls), &(MapSet.member?(seen, &1) or not Map.has_key?(funs, &1)))
    seen = Enum.into(new, seen)
    expand(Enum.flat_map(new, &Map.fetch!(funs, &1)) ++ rest, funs, seen, reads)
  end

  # Expansion-time code only: inside `quote`, just what `unquote` runs.
  defp scan({:quote, _, args}, acc), do: unquotes(args, acc)

  defp scan({{:., _, [{:__aliases__, _, [:Application]}, fun]}, _, [app, key | _]}, acc)
       when fun in [:get_env, :fetch_env, :fetch_env!, :compile_env, :compile_env!] and
              is_atom(app) and is_atom(key) do
    {calls, found} = acc
    {calls, [{Atom.to_string(app), Atom.to_string(key)} | found]}
  end

  defp scan({name, _, args}, acc) when is_atom(name) and is_list(args) do
    {calls, found} = Enum.reduce(args, acc, &scan/2)
    {[name | calls], found}
  end

  defp scan({left, _, args}, acc) when is_list(args),
    do: Enum.reduce(args, scan(left, acc), &scan/2)

  defp scan({left, right}, acc), do: scan(right, scan(left, acc))
  defp scan(list, acc) when is_list(list), do: Enum.reduce(list, acc, &scan/2)
  defp scan(_leaf, acc), do: acc

  defp unquotes(ast, acc) do
    {_ast, acc} =
      Macro.prewalk(ast, acc, fn
        {:unquote, _, args} = node, acc -> {node, scan(args, acc)}
        node, acc -> {node, acc}
      end)

    acc
  end
end
