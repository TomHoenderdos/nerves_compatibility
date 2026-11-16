defmodule NccWorker.Tracer.FixturesOsTypeTest do
  # Compile-time OS-type reads on real compiles (judge revision 17): kino's
  # `File.rm_rf!/1` in `Kino.JS.__before_compile__/1`, which keeps only the
  # family, a module body baking the whole tuple, and a dependent that
  # compiles against each. Each publishes with an `os_type` compile input
  # the client compares, valued with the OS type the traced VM ran with;
  # every other host read still refuses. Starts real `elixir` VMs (the
  # :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 2, lib: 3]

  @moduletag timeout: 600_000

  @deps %{
    # kino's lib/kino/js.ex: a before_compile hook that clears a dir under
    # the build with File.rm_rf!/1 (`{major, _} = :os.type()` inside).
    "fx_os_rm" =>
      lib("fx_os_rm", """
      defmodule FxOsRm do
        defmacro __using__(_opts), do: quote(do: @before_compile FxOsRm)

        defmacro __before_compile__(_env) do
          File.rm_rf!(Path.join(Mix.Project.compile_path(), "fx-os-rm-never-there"))
          quote(do: def(cleared, do: true))
        end
      end
      """),
    "fx_os_rm_user" =>
      lib(
        "fx_os_rm_user",
        "defmodule FxOsRmUser do\n  use FxOsRm\nend\n",
        %{deps: ["fx_os_rm"]}
      ),
    # A module body that bakes the whole tuple.
    "fx_os_attr" =>
      lib("fx_os_attr", """
      defmodule FxOsAttr do
        @os :os.type()
        def os, do: @os
      end
      """),
    # Both: the whole tuple wins.
    "fx_os_both" =>
      lib(
        "fx_os_both",
        "defmodule FxOsBoth do\n  use FxOsRm\n  @os :os.type()\n  def os, do: @os\nend\n",
        %{deps: ["fx_os_rm"]}
      ),
    # A package's own File-like module calling :os.type/0: never the family.
    "fx_os_fake" =>
      lib("fx_os_fake", """
      defmodule FxOsFake.File do
        def rm_rf(_path), do: :os.type()
      end

      defmodule FxOsFake do
        @os FxOsFake.File.rm_rf("x")
        def os, do: @os
      end
      """),
    # The OS type next to another host read: still refused.
    "fx_os_version" =>
      lib("fx_os_version", """
      defmodule FxOsVersion do
        @t :os.type()
        @v :os.version()
        def v, do: {@t, @v}
      end
      """)
  }

  setup_all do
    root =
      Path.join(
        System.tmp_dir!(),
        "ncc-fixtures-os-type-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    proj = TracerFixtures.project(Path.join(root, "p"), Map.keys(@deps), @deps)
    %{proj: proj, traced: TracerFixtures.trace(proj, Map.keys(@deps))}
  end

  {family, name} = :os.type()
  @family Atom.to_string(family)
  @full %{"kind" => "os_type", "family" => @family, "name" => Atom.to_string(name)}
  @family_only %{"kind" => "os_type", "family" => @family}

  defp verdict(ctx, app), do: TracerFixtures.judge(ctx.proj, app, ctx.traced)

  defp passes(ctx, app) do
    v = verdict(ctx, app)
    assert %{status: :pass} = v, "#{app}: #{inspect(v.observations, pretty: true)}"
    v
  end

  test "File.rm_rf!/1 in a before_compile hook publishes with the family alone", ctx do
    # The hook's own package defines it but never runs it.
    assert passes(ctx, "fx_os_rm").compile_inputs == []

    v = passes(ctx, "fx_os_rm_user")
    assert v.compile_inputs == [@family_only]
    assert Compatibility.CompileInputs.validate(v.compile_inputs) == {:ok, [@family_only]}
    assert Compatibility.CompileInputs.needs_check?(v.compile_inputs)
    assert v.observations["taint"] == %{}

    scopes = for r <- verdict(ctx, "fx_os_rm_user").observations["os_type_reads"], do: r["scope"]
    assert "family" in scopes
    assert Enum.all?(scopes, &(&1 in ["family", "covered"])), inspect(scopes)
  end

  test "a module body's read publishes with the whole OS type", ctx do
    v = passes(ctx, "fx_os_attr")
    assert v.compile_inputs == [@full]
    assert [%{"owner" => "fx_os_attr", "scope" => "full"} | _] = v.observations["os_type_reads"]
  end

  test "next to a read that reaches the whole tuple, the name is kept", ctx do
    assert passes(ctx, "fx_os_both").compile_inputs == [@full]
  end

  test "a package's own module named like the toolchain's is never the family", ctx do
    assert passes(ctx, "fx_os_fake").compile_inputs == [@full]
  end

  test "another host read next to it still refuses", ctx do
    assert %{
             status: :skip,
             reason: "compile-time host read: os:version/0" <> _,
             compile_inputs: nil
           } = verdict(ctx, "fx_os_version")
  end
end
