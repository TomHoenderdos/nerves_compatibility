defmodule NccWorker.Portability.ProgramSourcePathTest do
  use ExUnit.Case, async: true

  alias NccWorker.Portability
  alias NccWorker.Tracer.Report

  @moduletag :tmp_dir

  @libs %{"nif_check" => "ok", "mapped_libs" => ["/usr/lib/libc.so.6"]}
  @refusal " (a source path in a module that runs programs)"

  # deps/<app> and _build/host/lib/<app>/ebin for the package `fx` and its
  # dependency `dep`.
  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")

    for app <- ["dep", "fx"] do
      File.mkdir_p!(Path.join([proj, "deps", app, "lib"]))
      File.mkdir_p!(Path.join([proj, "_build/host/lib", app, "ebin"]))
      File.write!(Path.join([proj, "deps", app, "mix.exs"]), "")
    end

    File.write!(Path.join(proj, "mix.exs"), "")
    %{proj: proj}
  end

  # Compiles `source` as `deps/<app>/lib/<app>.ex` into the app's ebin.
  defp build(proj, app, source) do
    file = Path.join([proj, "deps", app, "lib", app <> ".ex"])
    File.write!(file, source)
    ebin = Path.join([proj, "_build/host/lib", app, "ebin"])

    for {module, binary} <- Code.compile_string(source, file) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp dep(proj, app, children) do
    %{
      "app" => app,
      "dest" => Path.join([proj, "deps", app]),
      "build" => Path.join([proj, "_build/host/lib", app]),
      "manager" => "mix",
      "children" => children
    }
  end

  defp window(app, open, close),
    do: %{
      app: app,
      open: open,
      close: close,
      depth_ok: true,
      integrity_ok: true,
      delivered: true,
      libs: @libs
    }

  # A clean hand-built report for `fx`, which depends on `dep`.
  defp report(proj) do
    %Report{
      start: Map.merge(%{"otp_root" => "/nonexistent-otp"}, @libs),
      closure: %{
        "packages" => ["fx"],
        "deps" => [dep(proj, "dep", []), dep(proj, "fx", ["dep"])]
      },
      windows: [window("dep", 10, 20), window("fx", 30, 40)],
      sentinels: [
        %{app: "dep", ts: 11, integrity_ok: true},
        %{app: "fx", ts: 31, integrity_ok: true}
      ],
      stats: %{"kind" => "stats", "calls" => 10, "unjudged" => 0},
      ending:
        Map.merge(
          %{
            "status" => "ok",
            "depth_ok" => true,
            "final_sentinel" => true,
            "overflow" => false,
            "integrity_ok" => true,
            "delivered" => true
          },
          @libs
        )
    }
  end

  defp judged(proj), do: Portability.judge(proj, "fx", report(proj), [], built_check: false)

  defp judged(proj, fx_source) do
    build(proj, "fx", fx_source)
    judged(proj)
  end

  test "the package's program-running module with a bare source path refuses (R2)",
       %{proj: proj} do
    verdict =
      judged(proj, """
      defmodule FxPspjRun do
        def run, do: System.cmd("cat", [file()])
        defp file, do: __ENV__.file
      end
      """)

    assert %{status: :skip, reason: "bakes the build path: Elixir.FxPspjRun" <> @refusal} =
             verdict

    assert Compatibility.Portability.withdraws?(verdict.reason)
  end

  # The refusal needs the path and the program call in one module.
  test "a path held in one package module and run from another passes, observed",
       %{proj: proj} do
    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "fx"}]}} =
             judged(proj, """
             defmodule FxPspjHold do
               def file, do: __ENV__.file
             end

             defmodule FxPspjOther do
               def run(file), do: System.find_executable(file)
             end
             """)
  end

  test "a path held in one package module and run through :os.cmd from another refuses",
       %{proj: proj} do
    assert %{status: :skip, reason: "bakes the build path: Elixir.FxPspjOsPaths" <> why} =
             judged(proj, """
             defmodule FxPspjOsPaths do
               def dir, do: Path.dirname(file())
               defp file, do: __ENV__.file
             end

             defmodule FxPspjOsBuild do
               def run, do: (_ = :os.cmd(String.to_charlist("cd " <> FxPspjOsPaths.dir())); :ok)
             end
             """)

    assert why == " (a source path in a package that calls :os.cmd)"
  end

  test "a dependency's :os.cmd does not count against the package's path", %{proj: proj} do
    build(proj, "dep", """
    defmodule FxPspjDepOs do
      def run(cmd), do: :os.cmd(cmd)
    end
    """)

    assert %{status: :pass} =
             judged(proj, """
             defmodule FxPspjDepOsPkg do
               def file, do: __ENV__.file
             end
             """)
  end

  test "the package's path handed to a dependency that runs programs passes, observed",
       %{proj: proj} do
    build(proj, "dep", """
    defmodule FxPspjDepCmd do
      def cmd(file), do: System.cmd("cat", [file])
    end
    """)

    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "fx"}]}} =
             judged(proj, """
             defmodule FxPspjPkgRun do
               @compile {:no_warn_undefined, FxPspjDepCmd}
               def run, do: FxPspjDepCmd.cmd(file())
               defp file, do: __ENV__.file
             end
             """)
  end

  # Ecto's query macros store `file: __ENV__.file` in a struct built at
  # runtime; the adapter that runs programs is another module.
  test "Ecto's query metadata shape passes beside a module that runs programs",
       %{proj: proj} do
    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "fx"}]}} =
             judged(proj, """
             defmodule FxPspjQuery do
               defstruct [:expr, :file, :line]
               def build(expr), do: %__MODULE__{expr: expr, file: __ENV__.file, line: __ENV__.line}
             end

             defmodule FxPspjAdapter do
               def run(sql), do: System.cmd("psql", ["-c", sql])
             end
             """)
  end

  test "the same query shape in a module that runs programs refuses", %{proj: proj} do
    assert %{status: :skip, reason: "bakes the build path: Elixir.FxPspjQueryRun" <> @refusal} =
             judged(proj, """
             defmodule FxPspjQueryRun do
               defstruct [:expr, :file, :line]
               def build(expr), do: %__MODULE__{expr: expr, file: __ENV__.file, line: __ENV__.line}
               def run(q), do: System.cmd("cat", [q.file])
             end
             """)
  end

  test "the package's path passes when nothing in the closure runs programs",
       %{proj: proj} do
    build(proj, "dep", "defmodule FxPspjDepQuiet do\n  def x, do: :ok\nend\n")

    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "fx"}]}} =
             judged(proj, """
             defmodule FxPspjPkgQuiet do
               @compile {:no_warn_undefined, FxPspjDepQuiet}
               def run, do: FxPspjDepQuiet.x() && file()
               defp file, do: __ENV__.file
             end
             """)
  end

  test "the same module without the path passes", %{proj: proj} do
    assert %{status: :pass} =
             judged(proj, """
             defmodule FxPspjNoPath do
               def run, do: System.cmd("true", [])
             end
             """)
  end

  test "the path without a program call passes, observed", %{proj: proj} do
    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "fx"}]}} =
             judged(proj, """
             defmodule FxPspjPathOnly do
               def file, do: __ENV__.file
             end
             """)
  end

  test "a closure dependency is not given the rule (its beams are not published)",
       %{proj: proj} do
    build(proj, "fx", "defmodule FxPspjPkg do\n  def x, do: :ok\nend\n")

    build(proj, "dep", """
    defmodule FxPspjDep do
      def run, do: System.cmd("cat", [file()])
      defp file, do: __ENV__.file
    end
    """)

    assert %{status: :pass, observations: %{"build_root_source_path" => [%{"owner" => "dep"}]}} =
             judged(proj)
  end
end
