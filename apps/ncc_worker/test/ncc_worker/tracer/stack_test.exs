defmodule NccWorker.Tracer.StackTest do
  use ExUnit.Case, async: true

  @toolchain [
    :os,
    System,
    :filename,
    Path,
    :elixir_module,
    :elixir_dispatch,
    :elixir_compiler,
    Mix.Dep,
    :compile,
    Enum,
    Macro,
    :elixir_expand,
    :elixir,
    :erl_eval,
    Code,
    :lists,
    :elixir_def,
    Mix.Task,
    Mix.Project,
    Module.ParallelChecker,
    Kernel.ParallelCompiler,
    File,
    Stream,
    Enumerable.List,
    Enumerable.Stream,
    Enumerable.MapSet,
    Collectable.Map,
    Map,
    Keyword,
    MapSet,
    :maps,
    :ordsets,
    :array,
    :digraph
  ]

  defp tc?(module), do: module in @toolchain
  defp f(m, fun, a, file \\ ~c"x.erl", line \\ 1), do: {m, fun, a, [file: file, line: line]}
  defp extent(stack, user? \\ false), do: :ncc_tracer_stack.extent(stack, 64, &tc?/1, user?)

  test "a module body frame anywhere in the stack is user extent" do
    body = f(:elixir_compiler_3, :__MODULE__, 1, ~c"/p/deps/x/lib/x.ex", 2)
    stack = [f(:os, :type, 0), body, f(:elixir_compiler, :dispatch, 4)]

    assert {:user, :frame, ^body, ^body} = extent(stack)
  end

  test "a MACRO frame is user extent" do
    macro = f(X.M, :"MACRO-m", 1)

    assert {:user, :frame, ^macro, ^macro} =
             extent([macro, f(:elixir_dispatch, :expand_macro_fun, 7)])
  end

  test "a tail call leaves the dispatcher as the first frame after the wrappers" do
    stack = [
      f(:elixir_module, :"-expand_callback/6-fun-0-", 6),
      f(:elixir_module, :expand_callback, 6)
    ]

    assert {:user, :dispatcher, _, :none} = extent(stack)

    assert {:user, :dispatcher, _, :none} =
             extent([f(System, :get_env, 1), f(:elixir_dispatch, :expand_macro_fun, 7)])
  end

  test "a dispatcher deeper in the stack is the toolchain at work" do
    stack = [f(Mix.Dep, :load, 1), f(:elixir_module, :expand_callback, 6)]
    assert :toolchain = extent(stack)
  end

  test "a stack as long as the depth with no user frame counts as user extent" do
    stack = for i <- 1..64, do: f(Macro, :do_traverse, i)
    assert {:user, :truncated, _, :none} = extent(stack)
    assert :toolchain = extent(Enum.take(stack, 63))
  end

  test "a user process makes a toolchain-only stack user extent" do
    stack = [f(Enum, :map, 2)]
    assert {:user, :lineage, _, :none} = extent(stack, true)
    assert :toolchain = extent(stack, false)
  end

  test "frames and MFAs render for the report" do
    assert %{module: "Elixir.X", function: "MACRO-m", arity: 1, file: "lib/x.ex", line: 3} =
             :ncc_tracer_stack.frame(f(X, :"MACRO-m", [:a], ~c"lib/x.ex", 3))

    assert :null = :ncc_tracer_stack.frame(:none)
    assert "os:type/0" = :ncc_tracer_stack.mfa_bin(:os, :type, 0)
    assert "System.version/0" = :ncc_tracer_stack.mfa_bin(System, :version, 0)
  end

  describe "tail calls through toolchain glue" do
    test "a macro that maps a capture over System.get_env/1 is user extent" do
      stack = [
        f(System, :get_env, 1),
        f(Enum, :"-map/2-lists^map/1-1-", 2),
        f(:elixir_dispatch, :expand_macro_fun, 7),
        f(:elixir_expand, :expand, 3)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "a __before_compile__ callback that maps over System.get_env/1 is user extent" do
      stack = [
        f(System, :get_env, 1),
        f(Enum, :"-map/2-lists^map/1-1-", 2),
        f(:lists, :map, 2),
        f(:elixir_module, :expand_callback, 6),
        f(:elixir_module, :compile, 7)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "a macro that tail-calls Code.eval_string is user extent" do
      stack = [
        f(:elixir, :eval_external_handler, 3),
        f(:erl_eval, :do_apply, 7),
        f(:erl_eval, :exprs, 6),
        f(:elixir, :eval_forms, 4),
        f(Code, :validated_eval_string, 3),
        f(:elixir_dispatch, :expand_macro_fun, 7)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "evaluated code under a dispatcher is user extent even below a toolchain frame" do
      stack = [
        f(Path, :expand, 1),
        f(:erl_eval, :do_apply, 7),
        f(Mix.Dep, :load, 1),
        f(:elixir_module, :expand_callback, 6)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "evaluated code with no dispatcher below it stays toolchain" do
      assert :toolchain =
               extent([f(Path, :expand, 1), f(:erl_eval, :do_apply, 7), f(Mix.Dep, :load, 1)])
    end

    test "glue frames with no dispatcher anywhere stay toolchain" do
      stack = [
        f(Enum, :map, 2),
        f(:lists, :map, 2),
        f(Macro, :do_traverse, 3),
        f(:compile, :file, 2)
      ]

      assert :toolchain = extent(stack)
    end

    test "a non-glue toolchain frame between the call and the dispatcher stays toolchain" do
      # The `@after_compile Mix.Project` / `use Mix.Project` shape: Mix doing its own work.
      stack = [
        f(System, :get_env, 1),
        f(Enum, :map, 2),
        f(Mix.Project, :push, 3),
        f(:elixir_module, :eval_callbacks, 5)
      ]

      assert :toolchain = extent(stack)
    end

    test "Code loading a mix.exs under the parallel checker stays toolchain" do
      # Seen on every `Mix.Project.in_project/4` and `Mix.CLI.load_mix_exs/1`:
      # only Code's eval functions are glue, not compile_file/find_file!.
      stack = [
        f(File, :read, 1),
        f(Code, :find_file!, 2),
        f(Code, :"-compile_file/2-fun-1-", 2),
        f(Module.ParallelChecker, :verify, 1),
        f(Mix.Project, :load_project, 2)
      ]

      assert :toolchain = extent(stack)
    end

    test "every dispatcher entry is recognised, plain and as an anonymous fun" do
      expected = [
        {:elixir_module, :expand_callback},
        {:elixir_module, :eval_callbacks},
        {:elixir_dispatch, :expand_macro_fun},
        {:elixir_def, :run_on_definition_callbacks},
        {:compile, :foldl_transform},
        {:compile, :foldl_core_transforms},
        {Mix.Task, :run_task},
        {Module.ParallelChecker, :verify},
        {Kernel.ParallelCompiler, :verify_modules}
      ]

      assert Enum.sort(:ncc_tracer_stack.dispatchers()) == Enum.sort(expected)

      for {m, fun} <- expected do
        assert :ncc_tracer_stack.dispatcher(f(m, fun, 3)), "#{inspect(m)}.#{fun}"

        assert :ncc_tracer_stack.dispatcher(f(m, :"-#{fun}/3-fun-0-", 2)),
               "#{inspect(m)}.#{fun} fun"

        assert {:user, :dispatcher, _, :none} = extent([f(m, fun, 3)])
      end

      refute :ncc_tracer_stack.dispatcher(f(:elixir_module, :compile, 7))
    end

    test "an empty stack counts as user extent (fail closed)" do
      assert {:user, :truncated, :none, :none} = extent([])
    end
  end

  describe "protocol and non-tail higher-order glue" do
    test "a Stream chain through Enumerable impls is user extent" do
      stack = [
        f(System, :get_env, 1),
        f(Stream, :"-map/2-fun-0-", 4),
        f(Enumerable.List, :reduce, 3),
        f(Enumerable.Stream, :do_each, 4),
        f(Enum, :reverse, 1),
        f(:elixir_dispatch, :expand_macro_fun, 7)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "Enum over a MapSet through Enumerable.MapSet is user extent" do
      stack = [
        f(System, :get_env, 1),
        f(Enum, :"-map/2-fun-0-", 3),
        f(Enumerable.MapSet, :reduce, 3),
        f(Enum, :map, 2),
        f(:elixir_module, :expand_callback, 6)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "Enum.into through Collectable.Map is user extent" do
      stack = [
        f(System, :get_env, 1),
        f(Enum, :"-into/3-fun-0-", 3),
        f(Collectable.Map, :"-into/1-fun-0-", 2),
        f(Enum, :into_protocol, 3),
        f(:elixir_dispatch, :expand_macro_fun, 7)
      ]

      assert {:user, :dispatcher, _, :none} = extent(stack)
    end

    test "Map.update and Map.new with a captured primitive are user extent" do
      assert {:user, :dispatcher, _, :none} =
               extent([
                 f(System, :get_env, 1),
                 f(Map, :update, 4),
                 f(:elixir_dispatch, :expand_macro_fun, 7)
               ])

      assert {:user, :dispatcher, _, :none} =
               extent([
                 f(System, :get_env, 1),
                 f(Map, :new_from_enum, 3),
                 f(:maps, :from_list, 1),
                 f(:elixir_module, :expand_callback, 6)
               ])
    end

    test "Keyword.update with a captured primitive is user extent" do
      assert {:user, :dispatcher, _, :none} =
               extent([
                 f(System, :get_env, 1),
                 f(Keyword, :update, 4),
                 f(:elixir_dispatch, :expand_macro_fun, 7)
               ])
    end

    test "OTP's ordsets, array and digraph folds with a captured primitive are user extent" do
      for frame <- [
            f(:ordsets, :fold, 3),
            f(:array, :foldl, 3),
            f(:array, :"-map/2-fun-0-", 3),
            f(:digraph, :"-collect_elems/3-fun-0-", 3)
          ] do
        assert {:user, :dispatcher, _, :none} =
                 extent([
                   f(System, :get_env, 1),
                   frame,
                   f(:elixir_dispatch, :expand_macro_fun, 7)
                 ]),
               inspect(frame)
      end
    end

    test "an unknown protocol-like prefix is not glue" do
      stack = [
        f(System, :get_env, 1),
        f(MapSet, :new, 1),
        f(Mix.Project, :push, 3),
        f(:elixir_module, :eval_callbacks, 5)
      ]

      assert :toolchain = extent(stack)
    end
  end

  describe "the running mix script" do
    @mix ~c"/opt/elixir/bin/mix"
    defp script?(file), do: file == List.to_string(@mix)

    defp mix_extent(stack, user? \\ false),
      do: :ncc_tracer_stack.extent(stack, 64, &tc?/1, user?, &script?/1)

    defp mix_frame(file \\ @mix), do: f(:elixir_compiler_0, :__FILE__, 1, file, 7)

    test "the mix script's elixir_compiler frame is toolchain" do
      stack = [f(:os, :getenv, 1), f(Mix.Project, :get, 0), mix_frame()]
      assert :toolchain = mix_extent(stack)
    end

    test "an elixir_compiler frame of any other file stays user extent" do
      body = mix_frame(~c"/opt/elixir/bin/mix2")
      stack = [f(:os, :getenv, 1), f(Mix.Project, :get, 0), body]
      assert {:user, :frame, _, ^body} = mix_extent(stack)
    end

    test "the mix script frame below eval is not a module body" do
      stack = [
        f(:os, :getenv, 1),
        f(:erl_eval, :do_apply, 7),
        f(Mix.Task, :run, 1),
        mix_frame()
      ]

      assert :toolchain = mix_extent(stack)
    end

    test "a package frame deeper in a stack faking the mix script's file is still user" do
      # Code.compile_string(src, "/opt/elixir/bin/mix") from package code.
      pkg = f(Pkg.Macros, :"MACRO-m", 1, ~c"/p/deps/pkg/lib/pkg.ex", 3)
      stack = [f(:os, :getenv, 1), mix_frame(), f(Code, :compile_string, 2), pkg, mix_frame()]
      # The forged frame is not the bottom-most compiler frame: user itself.
      fake = mix_frame()
      assert {:user, :frame, _, ^fake} = mix_extent(stack)
    end

    test "the real script frame, bottom-most of its kind, with the CLI below it, is toolchain" do
      stack = [
        f(:os, :getenv, 1),
        f(Mix.Project, :get, 0),
        mix_frame(),
        f(:elixir_compiler, :dispatch, 4),
        f(Code, :require_file, 2)
      ]

      assert :toolchain = mix_extent(stack)
    end

    test "a script-file frame above another compiler frame is user" do
      # Code.compile_string(src, <bin/mix>) from __after_compile__, tail-called:
      # the forged frame sits above the real script frame.
      forged = f(:elixir_compiler_1, :__FILE__, 1, @mix, 1)

      stack = [
        f(:os, :getenv, 1),
        forged,
        f(:elixir_compiler, :dispatch, 4),
        f(:elixir_module, :expand_callback, 6),
        mix_frame(),
        f(:elixir_compiler, :dispatch, 4),
        f(Code, :require_file, 2)
      ]

      assert {:user, :frame, _, ^forged} = mix_extent(stack)
    end

    test "extent/4 knows no mix script" do
      stack = [f(:os, :getenv, 1), mix_frame()]
      assert {:user, :frame, _, _} = extent(stack)
    end
  end

  test "first_kind/2 says whose code made a config read" do
    kind = &:ncc_tracer_stack.first_kind(&1, fn m -> m in [Logger, IO | @toolchain] end)

    assert kind.(:none) == "none"
    assert kind.(f(Logger, :__should_log__, 2)) == "toolchain"
    assert kind.(f(IO, :warn, 2)) == "toolchain"
    assert kind.(f(Enum, :map, 2)) == "glue"
    assert kind.(f(:erl_eval, :do_apply, 7)) == "glue"
    assert kind.(f(:elixir_dispatch, :"-expand_macro_fun/7-fun-0-", 3)) == "glue"
    assert kind.(f(:elixir_compiler_3, :__MODULE__, 1)) == "user"
    assert kind.(f(Phoenix.LiveView.TagEngine.Compiler, :compile, 2)) == "user"
    assert kind.(:not_a_frame) == "none"
  end

  test "checker/2: the first frame past the wrappers and loaders is the type checker" do
    tc = [:code, :error_handler, Kernel.ErrorHandler, Module.Types.Apply | @toolchain]
    checker? = &:ncc_tracer_stack.checker(&1, fn m -> m in tc end)
    cache = f(Module.ParallelChecker, :cache_module, 2)

    assert checker?.([cache])

    assert checker?.([
             f(:code, :ensure_loaded, 1),
             f(:error_handler, :undefined_function, 3),
             cache
           ])

    assert checker?.([
             f(Kernel.ErrorHandler, :undefined_function, 3),
             f(Module.Types.Apply, :export, 6)
           ])

    refute checker?.([f(Code, :ensure_loaded?, 1), f(:elixir_compiler_3, :__MODULE__, 1)])
    refute checker?.([f(:code, :ensure_loaded, 1)])
    refute checker?.([])
    refute checker?.(:no_stack)
    # A package's module named like the checker is not the toolchain's.
    refute :ncc_tracer_stack.checker([cache], fn m -> m in [:code] end)
  end

  test "made_by_toolchain/2: who called past the glue, a hook dispatcher being package code" do
    tc = [Module.Types.Descr, Module.Types.Expr, Task.Supervised | @toolchain]
    by_tc = &:ncc_tracer_stack.made_by_toolchain(&1, fn m -> m in tc end)
    pkg = f(:elixir_compiler_3, :__MODULE__, 1)

    assert by_tc.([f(Enum, :"-map/2-lists^map/1-1-", 2), f(Module.Types.Expr, :of_expr, 3)])
    assert by_tc.([f(Kernel.ParallelCompiler, :verify_modules, 5)])
    assert by_tc.([f(Module.ParallelChecker, :verify, 1), pkg])
    assert by_tc.([f(Code, :compile_string, 2), pkg])
    refute by_tc.([pkg])
    refute by_tc.([f(Enum, :map, 2), pkg])
    refute by_tc.([f(:elixir_module, :"-expand_callback/6-fun-0-", 3)])
    refute by_tc.([f(Enum, :map, 2)])
    # Task running a fun the package handed it, which tail-called.
    refute by_tc.([f(Task.Supervised, :invoke_mfa, 2)])
    refute by_tc.([f(:elixir_compiler_4, :__FILE__, 1)])
    refute by_tc.([])
    refute by_tc.(:no_stack)
  end

  test "made_by_mix/2: Mix's own frame on top past the wrappers and higher-order glue" do
    tc = [Mix.Task, Mix.Tasks.Compile.All, Mix.Task.Compiler, Mix.Tasks.Deps.Compile | @toolchain]
    by_mix = &:ncc_tracer_stack.made_by_mix(&1, fn m -> m in tc end)
    pkg = f(:elixir_compiler_3, :__MODULE__, 1)
    task = f(Mix.Tasks.Compile.FxTask, :run, 1)

    assert by_mix.([f(Mix.Tasks.Compile.All, :"-compile/4-fun-0-", 3), pkg])
    assert by_mix.([f(Enum, :reduce, 3), f(Mix.Tasks.Deps.Compile, :do_mix, 2)])
    # A task module's run/1 the task runner called, or a package task that
    # tail-called: the result goes to the runner, not to package code.
    assert by_mix.([f(Mix.Task, :run_task, 5), pkg])
    refute by_mix.([pkg])
    refute by_mix.([task, f(Mix.Task, :run_task, 5)])
    refute by_mix.([f(Enum, :map, 2), pkg])
    # Registering a hook goes through after_compiler/2: the caller below it.
    refute by_mix.([f(Mix.Task.Compiler, :after_compiler, 2), pkg])
    assert by_mix.([f(Mix.Task.Compiler, :after_compiler, 2), f(Mix.Task, :run_task, 5)])
    # Evaluated code is not Mix's even when Mix evaluates it.
    refute by_mix.([f(:erl_eval, :do_apply, 7), f(Mix.Task, :run_task, 5)])
    refute by_mix.([f(Code, :eval_string, 3), f(Mix.Task, :run_task, 5)])
    # A package's module named like Mix's, a non-Mix toolchain frame.
    refute :ncc_tracer_stack.made_by_mix([f(Mix.Task, :run_task, 5)], fn m -> m == Enum end)
    refute by_mix.([f(Task.Supervised, :invoke_mfa, 2)])
    refute by_mix.([])
    refute by_mix.(:no_stack)
  end

  # Mix state (`Mix.target`): a dispatcher on top is the package's call, so
  # a package task that tail-called the read hands its value to package code
  # through Mix.Task.run/1 (precompiled judge refinements item 2).
  test "made_by_mix_strict/2: a dispatcher on top is not Mix's" do
    tc = [Mix.Task, Mix.Project, Mix.State, Mix.Tasks.Compile.All | @toolchain]
    strict = &:ncc_tracer_stack.made_by_mix_strict(&1, fn m -> m in tc end)
    pkg = f(:elixir_compiler_3, :__MODULE__, 1)

    refute strict.([f(Mix.Task, :run_task, 5), pkg])
    refute strict.([f(Enum, :map, 2), f(Mix.Task, :run_task, 5), pkg])
    assert strict.([f(Mix.Project, :build_path, 1), pkg])
    assert strict.([f(Mix.State, :get, 2), pkg])
    assert strict.([f(Enum, :reduce, 3), f(Mix.Tasks.Compile.All, :run, 1)])
    refute strict.([pkg])
    refute strict.([f(Code, :eval_string, 3), f(Mix.Project, :build_path, 1)])
    refute strict.([])
    refute strict.(:no_stack)
  end

  describe "a read made through IO.ANSI or Logger.Formatter" do
    @ansi_toolchain [
      Application,
      :application,
      IO.ANSI,
      Mix.Shell.IO,
      Logger.Formatter,
      :logger_h_common | @toolchain
    ]

    defp ansi_extent(stack, user? \\ false),
      do: :ncc_tracer_stack.extent(stack, 64, &(&1 in @ansi_toolchain), user?)

    defp ansi_read,
      do: [f(:application, :get_env, 3), f(Application, :get_env, 3), f(IO.ANSI, :enabled?, 0)]

    test "is attributed to the frame that called IO.ANSI" do
      shell = f(Mix.Shell.IO, :info, 1)
      body = f(:elixir_compiler_3, :__MODULE__, 1, ~c"/p/deps/x/lib/x.ex", 2)
      stack = ansi_read() ++ [f(IO.ANSI, :format, 1), shell, body]

      assert {:user, :frame, ^shell, ^body} = ansi_extent(stack)
      assert {:user, :frame, ^body, ^body} = ansi_extent(ansi_read() ++ [body])
    end

    test "through Logger.Formatter is its caller's: Logger's handler or package code" do
      handler = f(:logger_h_common, :try_format, 3)
      body = f(:elixir_compiler_3, :__MODULE__, 1, ~c"/p/deps/x/lib/x.ex", 2)
      formatter = [f(Logger.Formatter, :colorize, 4), f(Logger.Formatter, :format, 2)]

      assert {:user, :frame, ^handler, ^body} =
               ansi_extent(ansi_read() ++ formatter ++ [handler, body])

      assert {:user, :frame, ^body, ^body} = ansi_extent(ansi_read() ++ formatter ++ [body])
    end

    test "from a macro's tail call is the package's, through the dispatcher" do
      dispatcher = f(:elixir_dispatch, :"-expand_macro_fun/7-fun-0-", 3)

      assert {:user, :dispatcher, ^dispatcher, :none} =
               ansi_extent(ansi_read() ++ [dispatcher])
    end

    test "never changes a frame's kind; only the exact module names are skipped" do
      kind = &:ncc_tracer_stack.first_kind(&1, fn m -> m in @ansi_toolchain end)
      shell = f(Mix.Shell.IO, :info, 1)
      lookalike = f(:"Elixir.IO.ANSI.Fake", :enabled?, 0)
      body = f(:elixir_compiler_3, :__MODULE__, 1)

      assert {:user, :frame, ^shell, ^body} = ansi_extent(ansi_read() ++ [shell, body])
      assert kind.(shell) == "toolchain"
      assert {:user, :frame, ^lookalike, ^lookalike} = ansi_extent(ansi_read() ++ [lookalike])
      assert kind.(lookalike) == "user"
    end

    # A package's module of the same name is not the toolchain's: it is not
    # skipped and stays the first frame.
    test "only the toolchain's own IO.ANSI and Logger.Formatter are skipped" do
      forged? = &(&1 in [IO.ANSI, Logger.Formatter])
      tc? = &(&1 in @ansi_toolchain and not forged?.(&1))
      extent = &:ncc_tracer_stack.extent(&1, 64, tc?, false)
      handler = f(:logger_h_common, :try_format, 3)
      formatter = f(Logger.Formatter, :format, 2)
      ansi = f(IO.ANSI, :enabled?, 0)
      read = [f(:application, :get_env, 3), f(Application, :get_env, 3)]

      assert {:user, :frame, ^ansi, ^ansi} = extent.(read ++ [ansi, formatter, handler])

      assert {:user, :frame, ^formatter, ^formatter} =
               extent.(read ++ [formatter, handler])
    end

    # Logger's handler is the first frame only when reached through the
    # toolchain's formatter: a package formatter tail-calling IO.ANSI leaves
    # the IO.ANSI frame right above the handler, and that frame stays first.
    test "Logger's handler is first only through Logger.Formatter" do
      handler = f(:logger_h_common, :try_format, 3)
      ansi = f(IO.ANSI, :enabled?, 0)
      read = [f(:application, :get_env, 3), f(Application, :get_env, 3), ansi]
      body = f(:elixir_compiler_3, :__MODULE__, 1)

      assert {:user, :frame, ^ansi, ^body} = ansi_extent(read ++ [handler, body])

      assert {:user, :frame, ^handler, ^body} =
               ansi_extent(read ++ [f(Logger.Formatter, :format, 2), handler, body])

      # Not reached through a skipped frame at all: the handler stays first.
      assert {:user, :frame, ^handler, ^body} =
               ansi_extent([f(:application, :get_env, 3), handler, body])
    end

    test "with nothing below it has no first frame" do
      assert :toolchain = ansi_extent(ansi_read())
      assert {:user, :lineage, :none, :none} = ansi_extent(ansi_read(), true)
    end
  end

  describe "a read made by the compiler's diagnostics module" do
    @errors_toolchain [:application, :elixir_errors, Module.ParallelChecker, SyntaxError]

    defp errors_extent(stack, tc? \\ &(&1 in @errors_toolchain)),
      do: :ncc_tracer_stack.extent(stack, 64, tc?, true)

    defp errors_read,
      do: [
        f(:application, :get_env, 3),
        f(:elixir_errors, :highlight, 2),
        f(:elixir_errors, :format_snippet, 6)
      ]

    test "is the module's own while one of its printing functions is below" do
      highlight = f(:elixir_errors, :highlight, 2)
      checker = f(Module.ParallelChecker, :"-spawn_checker/7-fun-0-", 0)

      for printer <- [:print_diagnostic, :print_warning, :"-print_diagnostics/1-lc$^0/1-0-"] do
        stack = errors_read() ++ [f(:elixir_errors, printer, 2), checker]
        assert {:user, :lineage, ^highlight, :none} = errors_extent(stack)
      end
    end

    test "returned to a caller, is the caller's" do
      message = f(SyntaxError, :message, 1)
      body = f(:elixir_compiler_3, :__MODULE__, 1)

      assert {:user, :frame, ^message, ^body} = errors_extent(errors_read() ++ [message, body])
      assert {:user, :frame, ^body, ^body} = errors_extent(errors_read() ++ [body])
    end

    # The printers format a stacktrace entry's arguments with `inspect`,
    # which runs a package's own Inspect implementation: anything that code
    # asks `:elixir_errors` for is its own, even with a printer further down.
    test "a frame between the reading frame and the printer takes the read" do
      inspect_impl = f(Inspect.FxThing, :inspect, 2, ~c"/p/deps/x/lib/x.ex", 3)
      message = f(SyntaxError, :message, 1)

      below = [
        f(Exception, :format_stacktrace_entry, 1),
        f(:elixir_errors, :print_diagnostic, 2),
        f(Module.ParallelChecker, :"-spawn_checker/7-fun-0-", 0)
      ]

      assert {:user, :frame, ^message, ^inspect_impl} =
               errors_extent(errors_read() ++ [message, inspect_impl] ++ below)

      assert {:user, :frame, ^inspect_impl, ^inspect_impl} =
               errors_extent(errors_read() ++ [inspect_impl] ++ below)
    end

    test "IO.ANSI frames between the reading frame and the printer keep it first" do
      highlight = f(:elixir_errors, :highlight, 2)
      tc? = &(&1 in [IO.ANSI | @errors_toolchain])

      stack =
        errors_read() ++
          [f(IO.ANSI, :format, 1), f(:elixir_errors, :print_warning, 3)]

      assert {:user, :lineage, ^highlight, :none} = errors_extent(stack, tc?)
    end

    test "a package's module of the same name stays first" do
      highlight = f(:elixir_errors, :highlight, 2)
      body = f(:elixir_compiler_3, :__MODULE__, 1)
      forged = &(&1 in @errors_toolchain and &1 != :elixir_errors)

      assert {:user, :frame, ^highlight, ^highlight} =
               errors_extent(errors_read() ++ [body], forged)
    end
  end

  describe "a read made by the type checker's diagnostic formatting" do
    @types_toolchain [
      :application,
      IO.ANSI,
      Module.Types.Apply,
      Module.ParallelChecker,
      Enum,
      :lists
    ]

    defp types_extent(stack, tc? \\ &(&1 in @types_toolchain)),
      do: :ncc_tracer_stack.extent(stack, 64, tc?, true)

    defp types_read,
      do: [
        f(:application, :get_env, 3),
        f(IO.ANSI, :enabled?, 0),
        f(Module.Types.Apply, :ansi_red, 1),
        f(Module.Types.Apply, :args_to_quoted_string, 3),
        f(Module.Types.Apply, :format_diagnostic, 1)
      ]

    test "stays first on the way down to the checker's grouping of diagnostics" do
      reader = f(Module.Types.Apply, :ansi_red, 1)

      for grouper <- [:group_diagnostics, :group_warnings] do
        stack =
          [
            f(:application, :get_env, 3),
            f(IO.ANSI, :enabled?, 0),
            reader,
            f(Module.Types.Apply, :"-args_to_quoted_string/3-fun-0-", 2),
            f(Enum, :zip_with, 3),
            f(Module.Types.Apply, :args_to_quoted_string, 3),
            f(Module.Types.Apply, :format_diagnostic, 1)
          ] ++
            [
              f(Module.ParallelChecker, :"-#{grouper}/1-fun-0-", 2),
              f(:lists, :foldl, 3),
              f(Module.ParallelChecker, grouper, 1),
              f(Module.ParallelChecker, :check_module, 4)
            ]

        assert {:user, :lineage, ^reader, :none} = types_extent(stack)
      end
    end

    test "is skipped when the text goes back to someone else" do
      keep = f(PackageCode, :keep_message, 0, ~c"/p/deps/x/lib/x.ex", 3)

      assert {:user, :frame, ^keep, ^keep} = types_extent(types_read() ++ [keep])

      # The grouping function further down does not help: the package's
      # frame in between asked for the text.
      stack =
        types_read() ++
          [keep, f(Module.ParallelChecker, :group_diagnostics, 1)]

      assert {:user, :frame, ^keep, ^keep} = types_extent(stack)
    end

    test "is skipped when another checker function asked for the text" do
      verify = f(Module.ParallelChecker, :verify, 1)
      stack = types_read() ++ [verify, f(Module.ParallelChecker, :group_diagnostics, 1)]

      # The checker's verify/1 is a dispatcher: the read is not the formatter's.
      assert {:user, :dispatcher, ^verify, :none} = types_extent(stack)
    end

    test "with no grouping function below, Apply's frames are skipped" do
      check = f(Module.ParallelChecker, :check_module, 4)

      assert {:user, :lineage, ^check, :none} = types_extent(types_read() ++ [check])
      assert {:user, :lineage, :none, :none} = types_extent(types_read())
    end

    test "only the Enum and lists folds count as glue on the run" do
      reader = f(Module.Types.Apply, :ansi_red, 1)
      grouper = f(Module.ParallelChecker, :group_diagnostics, 1)
      tc? = &(&1 in [Map, :erl_eval, Code, :elixir_eval | @types_toolchain])

      assert {:user, :lineage, ^reader, :none} =
               types_extent(types_read() ++ [f(:lists, :foldl, 3), grouper], tc?)

      for glue <- [
            f(Map, :update, 4),
            f(:erl_eval, :do_apply, 7),
            f(Code, :eval_string, 3),
            f(:elixir_eval, :eval_forms, 4)
          ] do
        assert {:user, _kind, first, :none} = types_extent(types_read() ++ [glue, grouper], tc?)
        refute first == reader, inspect(glue)
      end
    end

    test "only the reading function stays first" do
      other = f(Module.Types.Apply, :format_diagnostic, 1)
      stack = [f(:application, :get_env, 3), f(IO.ANSI, :enabled?, 0), other]

      assert {:user, :lineage, :none, :none} = types_extent(stack)
    end

    test "a package's module of the same name stays first" do
      reader = f(Module.Types.Apply, :ansi_red, 1)
      forged = &(&1 in @types_toolchain and &1 != Module.Types.Apply)
      stack = types_read() ++ [f(PackageCode, :keep_message, 0)]

      assert {:user, :frame, ^reader, ^reader} = types_extent(stack, forged)
    end

    test "a package's checker module of the same name ends the run" do
      grouper = f(Module.ParallelChecker, :group_diagnostics, 1)
      forged = &(&1 in @types_toolchain and &1 != Module.ParallelChecker)

      assert {:user, :frame, ^grouper, ^grouper} =
               types_extent(types_read() ++ [grouper], forged)
    end

    test "names the reader and the grouping functions it is scoped to" do
      assert [{Module.Types.Apply, :ansi_red, Module.ParallelChecker, groupers}] =
               :ncc_tracer_stack.diagnosers()

      assert Enum.sort(groupers) == [:group_diagnostics, :group_warnings]
      assert Module.Types.Apply in :ncc_tracer_stack.uncached()
    end
  end
end
