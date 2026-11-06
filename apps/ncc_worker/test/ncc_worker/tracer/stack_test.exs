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
    Macro
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
end
