defmodule NccWorker.Tracer.FixturesNativeBeamTest do
  # Judge revision 15 under the real tracer: a package that calls a natively
  # built dependency only at runtime. On Elixir 1.20 the type checker reads
  # that dependency's beam while it compiles the package (bumblebee reading
  # Tokenizers.Tokenizer.beam). The read is allowed when the dependency's
  # own compile is clean and refused when it observed the host, and a
  # compile-time use of the clean dependency still refuses. Path
  # dependencies made "native" the way the static grep sees it: a native
  # tool named in their mix.exs.
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 900_000

  @native ["fx_nat", "fx_nat_os"]

  @tool "# built with :elixir_make\n"

  @nat_src "defmodule FxNat do\n  def f(x), do: x + 1\nend\n"
  @nat_os_src "defmodule FxNatOs do\n  @os :os.type()\n  def os, do: @os\nend\n"

  # The 1.20 type checker reads a remote module's beam in the checker
  # process it spawns for the calling module, and the tracer sees that read
  # only when two things hold, as they do for bumblebee's read of
  # Tokenizers.Tokenizer.beam:
  #
  #   * the natively built dependency's ebin is a cached code path entry, so
  #     the checker reads the file itself. Mix leaves a dependency's own
  #     ebin on the path, uncached, until the next dependency's compile
  #     prunes it: a user compiled straight after it has its beam read by
  #     the code server instead, a toolchain process the tracer drops.
  #     fx_a_pad and fx_pad_os, which depend on nothing, compile in between
  #     (Mix's topological order; the first test pins it), and the user's
  #     compile puts the ebin back cached;
  #   * the checker process is a user process: spawned while a module body
  #     of the package is on the stack, as for a nested module. A lone
  #     top-level module's checker is spawned by the compiler alone.
  #
  # Without either, the read is not seen at all and the verdicts below are
  # the same, without the `native_beam_reads` observation.
  @nested &"defmodule #{&1} do\n  defmodule Run do\n    def g, do: #{&2}\n  end\nend\n"

  @deps %{
    "fx_nat" => %{
      mix_exs: TracerFixtures.mix_exs("fx_nat", "") <> @tool,
      files: %{"lib/fx_nat.ex" => @nat_src}
    },
    "fx_nat_os" => %{
      mix_exs: TracerFixtures.mix_exs("fx_nat_os", "") <> @tool,
      files: %{"lib/fx_nat_os.ex" => @nat_os_src}
    },
    "fx_uses_nat" =>
      lib("fx_uses_nat", @nested.("FxUsesNat", "FxNat.f(1)"), %{deps: ["fx_nat", "fx_a_pad"]}),
    "fx_uses_nat_os" =>
      lib("fx_uses_nat_os", @nested.("FxUsesNatOs", "FxNatOs.os()"), %{
        deps: ["fx_nat_os", "fx_pad_os"]
      }),
    "fx_a_pad" => lib("fx_a_pad", "defmodule FxAPad do\n  def p, do: :ok\nend\n", %{}),
    "fx_pad_os" => lib("fx_pad_os", "defmodule FxPadOs do\n  def p, do: :ok\nend\n", %{}),
    # A compile-time call into the clean dependency.
    "fx_uses_nat_ct" =>
      lib(
        "fx_uses_nat_ct",
        "defmodule FxUsesNatCt do\n  @x FxNat.f(1)\n  def g, do: @x\nend\n",
        %{
          deps: ["fx_nat"]
        }
      )
  }

  setup_all do
    root =
      Path.join(System.tmp_dir!(), "ncc-fixtures-nbeam-#{System.unique_integer([:positive])}")

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")

    releases =
      for {name, src} <- [{"fx_nat", @nat_src}, {"fx_nat_os", @nat_os_src}], into: %{} do
        contents = %{
          "mix.exs" => TracerFixtures.mix_exs(name, "") <> @tool,
          "lib/#{name}.ex" => src
        }

        TracerFixtures.hex_release(home, name, Map.keys(contents), contents)
      end

    top = ["fx_uses_nat", "fx_uses_nat_os", "fx_uses_nat_ct"]
    proj = TracerFixtures.project(root, top, @deps)
    traced = TracerFixtures.trace(proj, top, native: @native)

    %{proj: proj, traced: traced, opts: [releases: releases, hex_home: home]}
  end

  defp verdict(ctx, package),
    do: TracerFixtures.judge(ctx.proj, package, ctx.traced, @native, ctx.opts)

  test "the traced compile finished", %{traced: traced} do
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == [], inspect(traced.report.problems)

    order = for %{"app" => app} <- traced.report.closure["deps"], do: app
    at = &Enum.find_index(order, fn app -> app == &1 end)

    assert at.("fx_nat") < at.("fx_a_pad") and at.("fx_a_pad") < at.("fx_uses_nat"),
           inspect(order)

    assert at.("fx_nat_os") < at.("fx_pad_os") and at.("fx_pad_os") < at.("fx_uses_nat_os"),
           inspect(order)
  end

  test "a runtime-only user of a clean native dependency passes", ctx do
    v = verdict(ctx, "fx_uses_nat")
    assert %{status: :pass, reason: nil} = v, inspect({v.reason, v.observations["problems"]})

    if Version.match?(System.version(), ">= 1.20.0") do
      assert [%{"app" => "fx_nat", "owner" => "fx_uses_nat"} | _] =
               v.observations["native_beam_reads"]
    end
  end

  test "a runtime-only user of a host-tainted native dependency still refuses", ctx do
    assert %{status: :skip, reason: reason} = verdict(ctx, "fx_uses_nat_os")

    if Version.match?(System.version(), ">= 1.20.0") do
      # The read itself, in the package's window, as before revision 15.
      assert "compile-time host read: " <> rest = reason
      assert rest =~ "fx_nat_os/ebin/Elixir.FxNatOs.beam"
    else
      assert "closure dependency observed the host: fx_nat_os" <> _ = reason
    end
  end

  test "a compile-time call into a clean native dependency still refuses", ctx do
    assert %{status: :skip, reason: "calls natively built dependency at compile time: " <> _} =
             verdict(ctx, "fx_uses_nat_ct")
  end
end
