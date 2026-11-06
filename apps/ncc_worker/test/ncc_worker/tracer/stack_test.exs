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
    :maps
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

  describe "tail calls through toolchain glue (review fix)" do
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

  describe "protocol and non-tail higher-order glue (review fix 2)" do
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
end
