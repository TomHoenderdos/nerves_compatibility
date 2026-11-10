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
    # Malformed below the shape: never looked at.
    assert :ncc_tracer_stack.code_loading(frames(shape) ++ [:garbage], ~c"28")
    # Not a proper list, inside or below the shape: no crash, no flag.
    [first | rest] = frames(shape)
    refute :ncc_tracer_stack.code_loading([first | :tail], ~c"28")
    refute :ncc_tracer_stack.code_loading(:none, ~c"29")
    assert :ncc_tracer_stack.code_loading([first | rest] ++ [{:m, :f, 0, []} | :tail], ~c"28")
  end

  defp shape(release, top) do
    [shape] = for [^top | _] = s <- :ncc_tracer_stack.code_loading_shapes(release), do: s
    frames(shape)
  end

  test "each accepted read is flagged only under the shape that makes it" do
    below = [{:error_handler, :undefined_function, 3, []}, {:parse_trans, :get_file, 1, []}]

    for release <- [~c"28", ~c"29"] do
      pathtype = shape(release, {:erl_prim_loader, :pathtype, 1}) ++ below
      real_path = shape(release, {:erl_prim_loader, :real_path, 4}) ++ below
      read = &:ncc_tracer_stack.code_loading_read(&1, &2, &3, &4, release)

      assert read.(:erlang, :system_info, [:os_type], pathtype)
      assert read.(:prim_file, :read_link, [~c"/usr"], real_path)

      # The other shape: a shape does not say which call it was made from.
      refute read.(:erlang, :system_info, [:os_type], real_path)
      refute read.(:prim_file, :read_link, [~c"/usr"], pathtype)

      # Never flagged: get_cwd (no pinned shape has absname on top), the beam
      # read itself, other keys, other calls.
      for stack <- [pathtype, real_path] do
        refute read.(:prim_file, :get_cwd, [], stack)
        refute read.(:prim_file, :read_file, [~c"/x.beam"], stack)
        refute read.(:erlang, :system_info, [:endian], stack)
        refute read.(:erlang, :system_info, [{:os_type, :x}], stack)
        refute read.(:os, :type, [], stack)
        refute read.(:file, :read_link, [~c"/usr"], stack)
        refute read.(:prim_file, :read_link_all, [~c"/usr"], stack)
      end

      # A package frame on top, or a direct erl_prim_loader:read_file/1 call
      # (no code-server frames under it), or no shape at all.
      refute read.(:prim_file, :read_link, [~c"/usr"], [{:pkg, :f, 0, []} | real_path])
      refute read.(:erlang, :system_info, [:os_type], [{:pkg, :f, 0, []} | pathtype])

      direct =
        Enum.take_while(real_path, &(elem(&1, 0) != :code)) ++ [{:pkg, :f, 0, []} | below]

      refute read.(:prim_file, :read_link, [~c"/usr"], direct)
      refute read.(:prim_file, :read_link, [~c"/usr"], [{:pkg, :on_load, 0, []}])
      refute read.(:prim_file, :read_link, [~c"/usr"], :none)
      refute read.(:prim_file, :read_link, [~c"/usr"], [hd(real_path) | :tail])
    end

    # A release nothing was pinned for.
    refute :ncc_tracer_stack.code_loading_read(
             :prim_file,
             :read_link,
             [~c"/usr"],
             shape(~c"28", {:erl_prim_loader, :real_path, 4}),
             ~c"27"
           )
  end

  # Integration: CI's OTP floats to the newest patch while the images are
  # pinned; the images themselves are checked in `make test-integration` by
  # check_images.sh (`make check-code-loading-shapes`).
  @tag :integration
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
