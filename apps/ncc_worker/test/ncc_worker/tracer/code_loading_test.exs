defmodule NccWorker.Tracer.CodeLoadingTest do
  @moduledoc """
  Pins `:ncc_tracer_stack.code_loading/1` (precompiled judge refinements,
  item 5a): the stack shapes of OTP's own code loading, recorded per
  toolchain image by `test/fixtures/code_loading/code_loading_repro.erl`,
  and the live shapes on the toolchain this VM runs.
  """
  use ExUnit.Case, async: true

  @fixtures Path.expand("../../fixtures/code_loading", __DIR__)

  defp frames(shape), do: for({m, f, a} <- shape, do: {m, f, a, []})

  test "the pinned table is exactly the recorded fixtures" do
    for release <- [~c"28", ~c"29"] do
      {:ok, [{:shapes, ^release, shapes}]} =
        :file.consult(String.to_charlist(Path.join(@fixtures, "otp-#{release}.term")))

      assert shapes != []
      assert :ncc_tracer_stack.code_loading_shapes(release) == shapes
    end

    assert :ncc_tracer_stack.code_loading_shapes(~c"27") == []
  end

  test "only a stack whose top is exactly a pinned shape is code loading" do
    [shape | _] = :ncc_tracer_stack.code_loading_shapes(~c"28")
    below = [{:error_handler, :undefined_function, 3, []}, {:parse_trans, :get_file, 1, []}]

    assert :ncc_tracer_stack.code_loading(frames(shape) ++ below, ~c"28")
    # A package frame on top: the package made the call.
    refute :ncc_tracer_stack.code_loading([{:pkg, :f, 0, []} | frames(shape) ++ below], ~c"28")
    # Without code:ensure_loaded/1: a direct erl_prim_loader:read_file/1 call.
    refute :ncc_tracer_stack.code_loading(frames(Enum.drop(shape, -2)) ++ below, ~c"28")
    # An OTP release without pinned shapes, and no stack at all.
    refute :ncc_tracer_stack.code_loading(frames(shape) ++ below, ~c"27")
    refute :ncc_tracer_stack.code_loading(:none, ~c"28")
    refute :ncc_tracer_stack.code_loading([:garbage | frames(shape)], ~c"28")
    refute :ncc_tracer_stack.code_loading([{:m, :f, :bad, []} | frames(shape)], ~c"28")
  end

  @tag :tmp_dir
  test "on this VM's OTP, the live reproduction shows only pinned shapes", %{tmp_dir: dir} do
    release = :erlang.system_info(:otp_release)
    pinned = :ncc_tracer_stack.code_loading_shapes(release)

    if pinned == [] do
      # Fail closed: no flag on a release nothing pinned.
      refute :ncc_tracer_stack.code_loading([{:code, :ensure_loaded, 1, []}])
    else
      File.cp!(
        Path.join(@fixtures, "code_loading_repro.erl"),
        Path.join(dir, "code_loading_repro.erl")
      )

      {_, 0} = System.cmd("erlc", ["code_loading_repro.erl"], cd: dir)

      {_, 0} =
        System.cmd("erl", ["-noshell", "-eval", ~s|code_loading_repro:build("repro.escript")|],
          cd: dir
        )

      {out, 0} = System.cmd("escript", ["repro.escript"], cd: dir)
      File.write!(Path.join(dir, "out.term"), out)

      {:ok, [{:shapes, ^release, live}, {:unmatched, []}]} =
        :file.consult(String.to_charlist(Path.join(dir, "out.term")))

      assert live != []
      for shape <- live, do: assert(shape in pinned, inspect(shape))
    end
  end
end
