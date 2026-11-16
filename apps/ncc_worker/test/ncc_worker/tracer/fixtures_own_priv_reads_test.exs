defmodule NccWorker.Tracer.FixturesOwnPrivReadsTest do
  # Judge revision 23 under the real tracer: a natively built package's own
  # compile embedding a file of its own source priv, read through Mix's link
  # from its build priv (rustler's `Mix.Tasks.Rustler.New` embedding its
  # templates). It passes, as the package and as a closure dependency, when
  # the package's tree is its verified tarball's after the compile. Another
  # package reading that priv, a build priv the compile wrote itself, and a
  # source priv linked out of the package's tree still refuse. Path
  # dependencies made "native" the way the static grep sees it: a native
  # tool named in their mix.exs. Starts real `elixir` VMs (the :real_vm group).
  use ExUnit.Case, async: true, group: :real_vm

  alias NccWorker.Portability.Context
  alias NccWorker.TracerFixtures

  import NccWorker.TracerFixtures, only: [lib: 3]

  @moduletag timeout: 900_000

  @tool "# built with :elixir_make\n"
  @native ["fx_tpl", "fx_tpl_written", "fx_tpl_out"]

  # Reads its template at compile time through `:code.priv_dir/1`, as
  # rustler's `Mix.Tasks.Rustler.New` does.
  @tpl_src """
  defmodule FxTpl do
    root = Path.join(:code.priv_dir(:fx_tpl), "templates")
    @external_resource Path.join(root, "a.txt")
    def a, do: unquote(File.read!(Path.join(root, "a.txt")))
  end
  """

  @tpl %{
    "mix.exs" => TracerFixtures.mix_exs("fx_tpl", "") <> @tool,
    "lib/fx_tpl.ex" => @tpl_src,
    "priv/templates/a.txt" => "template a\n"
  }

  # Writes its own build priv (a directory: it ships none), then reads the
  # file back.
  @written_src """
  defmodule FxTplWritten do
    dir = :code.priv_dir(:fx_tpl_written)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "gen.txt"), "generated")
    def gen, do: unquote(File.read!(Path.join(dir, "gen.txt")))
  end
  """

  @written %{
    "mix.exs" => TracerFixtures.mix_exs("fx_tpl_written", "") <> @tool,
    "lib/fx_tpl_written.ex" => @written_src
  }

  # Its source priv is a link out of its own tree.
  @out_src """
  defmodule FxTplOut do
    def a, do: unquote(File.read!(Path.join(:code.priv_dir(:fx_tpl_out), "a.txt")))
  end
  """

  @out %{
    "mix.exs" => TracerFixtures.mix_exs("fx_tpl_out", "") <> @tool,
    "lib/fx_tpl_out.ex" => @out_src,
    "priv/a.txt" => "outside\n"
  }

  setup_all do
    # The real path: on macOS the tmp dir sits behind the /var symlink, and
    # Mix's relative priv links, computed from the unresolved path, would
    # dangle (the worker's /work is a real path).
    root =
      Path.join(
        Context.realpath(System.tmp_dir!()),
        "ncc-fixtures-own-priv-reads-#{System.pid()}-#{System.unique_integer([:positive])}"
      )

    on_exit(fn -> File.rm_rf(root) end)
    home = Path.join(root, "hex")
    outside = Path.join(root, "outside")
    File.mkdir_p!(outside)
    File.write!(Path.join(outside, "a.txt"), "outside\n")

    releases =
      for {app, contents} <- [
            {"fx_tpl", @tpl},
            {"fx_tpl_written", @written},
            {"fx_tpl_out", @out}
          ],
          into: %{},
          do: TracerFixtures.hex_release(home, app, Map.keys(contents), contents)

    deps = %{
      "fx_tpl" => spec(@tpl),
      "fx_tpl_written" => spec(@written),
      "fx_tpl_out" => %{
        mix_exs: @out["mix.exs"],
        files: %{"lib/fx_tpl_out.ex" => @out_src},
        links: %{"priv" => outside}
      },
      # rustler in tokenizers' closure: depends on it, reads nothing.
      "fx_tpl_user" =>
        lib("fx_tpl_user", "defmodule FxTplUser do\n  def a, do: FxTpl.a()\nend\n", %{
          deps: ["fx_tpl"]
        }),
      # Embeds fx_tpl's template itself.
      "fx_tpl_reader" =>
        lib(
          "fx_tpl_reader",
          """
          defmodule FxTplReader do
            @a File.read!(Path.join(:code.priv_dir(:fx_tpl), "templates/a.txt"))
            def a, do: @a
          end
          """,
          %{deps: ["fx_tpl"]}
        )
    }

    top = ~w(fx_tpl fx_tpl_user fx_tpl_reader fx_tpl_written fx_tpl_out)
    proj = TracerFixtures.project(root, top, deps)
    traced = TracerFixtures.trace(proj, top, native: @native)

    %{proj: proj, traced: traced, opts: [releases: releases, hex_home: home]}
  end

  defp spec(contents) do
    %{mix_exs: contents["mix.exs"], files: Map.delete(contents, "mix.exs")}
  end

  defp verdict(ctx, package, opts \\ []),
    do:
      TracerFixtures.judge(ctx.proj, package, ctx.traced, @native, Keyword.merge(ctx.opts, opts))

  defp show(v), do: inspect({v.reason, v.observations["problems"]}, pretty: true)

  test "the traced compile finished", %{traced: traced, proj: proj} do
    assert {:ok, 0} = traced.result, traced.log
    assert traced.report.problems == [], inspect(traced.report.problems)

    # Mix linked fx_tpl's build priv to its source priv, and fx_tpl_written's
    # is a directory of its own.
    assert {:ok, _link} = File.read_link(Path.join(proj, "_build/host/lib/fx_tpl/priv"))

    assert {:ok, %File.Stat{type: :directory}} =
             File.lstat(Path.join(proj, "_build/host/lib/fx_tpl_written/priv"))
  end

  test "a package embedding its own priv file at compile time passes", ctx do
    v = verdict(ctx, "fx_tpl")
    assert %{status: :pass, reason: nil} = v, show(v)

    assert [%{"owner" => "fx_tpl", "app" => "fx_tpl", "source" => "priv/templates/a.txt"}] =
             v.observations["own_priv_reads"]
  end

  test "so does a package that has it in its closure", ctx do
    v = verdict(ctx, "fx_tpl_user")
    assert %{status: :pass, reason: nil} = v, show(v)
    assert [%{"owner" => "fx_tpl"}] = v.observations["own_priv_reads"]
    assert v.observations["taint"] == %{}
  end

  test "with no verified tarball the read refuses as before", ctx do
    for package <- ["fx_tpl", "fx_tpl_user"] do
      v = verdict(ctx, package, releases: %{})
      assert v.status == :skip
      assert v.reason =~ "compile-time host read: file:read_file/"
      assert v.reason =~ "_build/host/lib/fx_tpl/priv/templates/a.txt in "
      assert v.reason =~ "(lib/fx_tpl.ex:"
    end
  end

  test "a package reading another package's priv still refuses", ctx do
    v = verdict(ctx, "fx_tpl_reader")
    assert v.status == :skip
    assert "compile-time host read: file:read_file/" <> rest = v.reason
    assert rest =~ "_build/host/lib/fx_tpl/priv/templates/a.txt in "
    assert rest =~ "(lib/fx_tpl_reader.ex:"
  end

  test "a priv that is a real dir written earlier in the compile refuses", ctx do
    v = verdict(ctx, "fx_tpl_written")
    assert v.status == :skip
    assert "compile-time host read: file:read_file/" <> rest = v.reason
    assert rest =~ "_build/host/lib/fx_tpl_written/priv/gen.txt in "
    assert rest =~ "(lib/fx_tpl_written.ex:"
    assert Enum.any?(v.observations["priv_writes"], &(&1["written"] == "gen.txt"))
    assert v.observations["own_priv_reads"] == []
  end

  test "a symlink pointing outside the package's tree refuses", ctx do
    v = verdict(ctx, "fx_tpl_out")
    assert v.status == :skip
    assert "compile-time host read: file:read_file/" <> rest = v.reason
    assert rest =~ "_build/host/lib/fx_tpl_out/priv/a.txt in "
    assert rest =~ "(lib/fx_tpl_out.ex:"
    assert v.observations["own_priv_reads"] == []
  end
end
