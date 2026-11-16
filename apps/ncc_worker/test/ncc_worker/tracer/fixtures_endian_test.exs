defmodule NccWorker.Tracer.FixturesEndianTest do
  # Compile-time byte-order reads on real compiles (judge revision 13): nx's
  # `System.endianness/0` in a module body, and a dependent that compiles
  # against it. Each publishes with an `endian` compile input the client
  # compares, valued with the byte order the traced VM ran with; every other
  # host read still refuses. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 600_000

  @deps %{
    # nx's lib/nx/floating.ex: the float layout chosen by byte order.
    "fx_endian" =>
      lib("fx_endian", """
      defmodule FxEndian do
        @endian System.endianness()
        def endian, do: @endian

        # nx's Nx.Shared.write_bin_modifier/3: a macro that reads it again
        # in its caller's compile.
        defmacro modifier, do: System.endianness()
      end
      """),
    # polaris, safetensors: a dependent whose own compile calls the macro.
    "fx_endian_user" =>
      lib(
        "fx_endian_user",
        """
        defmodule FxEndianUser do
          require FxEndian
          @m FxEndian.modifier()
          def m, do: @m
        end
        """,
        %{deps: ["fx_endian"]}
      ),
    # nx_image: a dependent that only calls it at run time.
    "fx_endian_runtime" =>
      lib(
        "fx_endian_runtime",
        "defmodule FxEndianRuntime do\n  def e, do: FxEndian.endian()\nend\n",
        %{deps: ["fx_endian"]}
      ),
    # The byte order next to another host read: still refused.
    "fx_endian_os" =>
      lib("fx_endian_os", """
      defmodule FxEndianOs do
        @e System.endianness()
        @os :os.version()
        def v, do: {@e, @os}
      end
      """),
    # The Elixir install's byte order, which no client can check: refused.
    "fx_endian_compiled" =>
      lib("fx_endian_compiled", """
      defmodule FxEndianCompiled do
        @e System.compiled_endianness()
        def e, do: @e
      end
      """)
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-endian-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)
    %{proj: proj, traced: TracerFixtures.trace(proj, Map.keys(@deps))}
  end

  @here Atom.to_string(:erlang.system_info(:endian))
  @item %{"kind" => "endian", "value" => @here}

  defp verdict(ctx, app), do: TracerFixtures.judge(ctx.proj, app, ctx.traced)

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  test "the package's own read publishes with the builder's byte order", ctx do
    v = passes(ctx, "fx_endian")
    assert v.compile_inputs == [@item]
    assert Compatibility.CompileInputs.validate(v.compile_inputs) == {:ok, [@item]}
    assert Compatibility.CompileInputs.needs_check?(v.compile_inputs)
    assert [%{"owner" => "fx_endian"} | _] = v.observations["endian_reads"]
  end

  test "a dependent is not tainted: it carries the input to compare", ctx do
    for app <- ["fx_endian_user", "fx_endian_runtime"] do
      v = passes(ctx, app)
      assert v.compile_inputs == [@item], app
      assert v.observations["taint"] == %{}, app
    end
  end

  test "another host read next to it still refuses", ctx do
    assert %{
             status: :skip,
             reason: "compile-time host read: os:version/0" <> _,
             compile_inputs: nil
           } =
             verdict(ctx, "fx_endian_os")
  end

  test "System.compiled_endianness/0 refuses: the client checks only the VM's", ctx do
    assert %{
             status: :skip,
             reason: "compile-time Elixir patch dependence: System.compiled_endianness/0" <> _,
             compile_inputs: nil
           } = verdict(ctx, "fx_endian_compiled")
  end
end
