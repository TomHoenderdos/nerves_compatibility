defmodule NccWorker.FirmwareBuildRootTest do
  use ExUnit.Case, async: true

  alias NccWorker.FirmwareBuildRoot

  @moduletag :tmp_dir

  @target "rpi0_2"
  @start %{"otp_root" => "/nonexistent-otp"}

  # A firmware build of the package `fx` for `rpi0_2`: its source under
  # deps_rpi0_2/fx, its beams under _build/rpi0_2/lib/fx/ebin.
  setup %{tmp_dir: dir} do
    proj = Path.join(dir, "proj")
    File.mkdir_p!(Path.join([proj, "deps_#{@target}", "fx", "lib"]))
    File.mkdir_p!(Path.join([proj, "_build", @target, "lib", "fx", "ebin"]))
    File.write!(Path.join([proj, "deps_#{@target}", "fx", "mix.exs"]), "")
    %{proj: proj, app_dir: Path.join([proj, "_build", @target, "lib", "fx"])}
  end

  defp build(proj, source, lib \\ "fx") do
    file = Path.join([proj, "deps_#{@target}", "fx", "lib", "fx.ex"])
    File.write!(file, source)
    ebin = Path.join([proj, "_build", @target, "lib", lib, "ebin"])
    File.mkdir_p!(ebin)

    for {module, binary} <- Code.compile_string(source, file) do
      File.write!(Path.join(ebin, "#{module}.beam"), binary)
      :code.purge(module)
      :code.delete(module)
    end
  end

  defp judge(dir, proj, target, _opts),
    do: FirmwareBuildRoot.judge(dir, proj, target, start: @start, extra_roots: [])

  defp judged(proj, app_dir, source) do
    build(proj, source)
    judge(app_dir, proj, @target, [])
  end

  describe "judge/4" do
    # xla's `checksum_path/0`: `Path.expand("../checksum.txt", __DIR__)`,
    # read at runtime, bakes `deps_<target>/xla/lib`.
    test "a directory of the build tree the code reads at runtime refuses",
         %{proj: proj, app_dir: app_dir} do
      assert {:refuse, "bakes the build path: Elixir.FxFwDir \"<root>/deps_rpi0_2/fx/lib\""} =
               judged(proj, app_dir, """
               defmodule FxFwDir do
                 def checksum_path, do: Path.expand("../checksum.txt", __DIR__)
                 def checksum, do: File.read(checksum_path())
               end
               """)
    end

    test "a _build path baked at compile time refuses", %{proj: proj, app_dir: app_dir} do
      priv = Path.join(app_dir, "priv")
      File.mkdir_p!(priv)

      assert {:refuse,
              "bakes the build path: Elixir.FxFwPriv \"<root>/_build/rpi0_2/lib/fx/priv\""} =
               judged(proj, app_dir, """
               defmodule FxFwPriv do
                 @priv #{inspect(priv)}
                 def priv, do: @priv
               end
               """)
    end

    test "a source path in a module that runs programs refuses",
         %{proj: proj, app_dir: app_dir} do
      assert {:refuse,
              "bakes the build path: Elixir.FxFwRun (a source path in a module that runs programs)"} =
               judged(proj, app_dir, """
               defmodule FxFwRun do
                 def run, do: System.cmd("cat", [file()])
                 defp file, do: __ENV__.file
               end
               """)
    end

    test "a source path in a package that runs a shell refuses",
         %{proj: proj, app_dir: app_dir} do
      assert {:refuse,
              "bakes the build path: Elixir.FxFwHold (a source path in a package that runs a shell)"} =
               judged(proj, app_dir, """
               defmodule FxFwHold do
                 def file, do: __ENV__.file
               end

               defmodule FxFwShell do
                 def run(cmd), do: :os.cmd(cmd)
               end
               """)
    end

    # Ecto's query metadata: `file: __ENV__.file` in a struct built at runtime.
    test "Ecto's query metadata is observed, as on the host", %{proj: proj, app_dir: app_dir} do
      assert {:observe, [{:observe, "build_root_source_path", "<root>/deps_rpi0_2/fx/lib/fx.ex"}]} =
               judged(proj, app_dir, """
               defmodule FxFwQuery do
                 defstruct [:expr, :file, :line]
                 def build(expr), do: %__MODULE__{expr: expr, file: __ENV__.file, line: __ENV__.line}
               end
               """)
    end

    test "a log line's metadata is not a baked path", %{proj: proj, app_dir: app_dir} do
      assert :ok =
               judged(proj, app_dir, """
               defmodule FxFwLog do
                 require Logger
                 def hello, do: Logger.info("hello")
               end
               """)
    end

    test "a build without the build tree passes", %{proj: proj, app_dir: app_dir} do
      assert :ok =
               judged(proj, app_dir, """
               defmodule FxFwClean do
                 def priv, do: :code.priv_dir(:fx)
               end
               """)
    end

    test "a missing ebin cannot be judged", %{proj: proj} do
      assert {:error, _} = judge(Path.join(proj, "nowhere"), proj, @target, [])
    end
  end

  describe "gate/3" do
    defp manifest,
      do: %{"ebin" => [%{"path" => "ebin/x.beam", "sha256" => "a", "size" => 1}], "priv" => []}

    defp passing,
      do: %{
        status: :pass,
        log_tail: "built",
        beam_scan: %{"footprint" => %{"file_count" => 1, "file_manifest" => manifest()}}
      }

    defp params(proj),
      do: %{project_dir: proj, package: "fx", targets: %{"nerves_system_rpi0_2" => {@target, []}}}

    test "a refused target keeps its status and publishes no files", %{proj: proj} do
      build(proj, """
      defmodule FxFwGateDir do
        def path, do: Path.expand("../data", __DIR__)
      end
      """)

      {systems, [line]} =
        FirmwareBuildRoot.gate(%{"nerves_system_rpi0_2" => passing()}, params(proj),
          judge: &judge/4
        )

      result = systems["nerves_system_rpi0_2"]
      assert result.status == :pass
      assert result.log_tail == "built"
      refute Map.has_key?(result.beam_scan["footprint"], "file_manifest")
      assert result.beam_scan["footprint"]["file_count"] == 1
      assert %{status: "skipped", reason: "bakes the build path: " <> _} = result.build_root
      assert line =~ "Files of nerves_system_rpi0_2 not published: bakes the build path"
    end

    test "an observed target publishes and records the observation", %{proj: proj} do
      build(proj, """
      defmodule FxFwGateQuery do
        defstruct [:expr, :file]
        def build(expr), do: %__MODULE__{expr: expr, file: __ENV__.file}
      end
      """)

      {systems, []} =
        FirmwareBuildRoot.gate(%{"nerves_system_rpi0_2" => passing()}, params(proj),
          judge: &judge/4
        )

      result = systems["nerves_system_rpi0_2"]
      assert result.beam_scan["footprint"]["file_manifest"] == manifest()

      assert %{
               status: "pass",
               reason: nil,
               observations: [%{"rule" => "build_root_source_path", "path" => "<root>/" <> _}]
             } = result.build_root
    end

    test "failed targets and unknown systems are left alone", %{proj: proj} do
      failed = %{status: :fail, beam_scan: nil, log_tail: "x"}
      systems = %{"nerves_system_rpi0_2" => failed, "nerves_system_other" => passing()}

      assert {^systems, []} = FirmwareBuildRoot.gate(systems, params(proj), judge: &judge/4)
    end

    test "a refused variant is dropped, the clean build kept", %{proj: proj} do
      build(proj, "defmodule FxFwGateOwn do\n  def x, do: :ok\nend\n")

      build(
        proj,
        "defmodule FxFwGateWithout do\n  def p, do: Path.expand(\"x\", __DIR__)\nend\n",
        ".fx.without"
      )

      variant = %{
        variant: "without",
        beam_scan: %{"footprint" => %{"file_manifest" => manifest()}},
        compile_env: [],
        deps_lock: %{}
      }

      system = Map.put(passing(), :published_variants, [variant])

      {systems, [line]} =
        FirmwareBuildRoot.gate(%{"nerves_system_rpi0_2" => system}, params(proj), judge: &judge/4)

      result = systems["nerves_system_rpi0_2"]
      refute Map.has_key?(result, :published_variants)
      assert result.beam_scan["footprint"]["file_manifest"] == manifest()
      assert %{status: "pass", variants: %{"without" => %{status: "skipped"}}} = result.build_root
      assert line =~ "(without) not published"
    end
  end
end
