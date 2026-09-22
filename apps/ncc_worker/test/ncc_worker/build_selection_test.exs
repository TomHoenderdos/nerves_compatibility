defmodule NccWorker.BuildSelectionTest do
  use ExUnit.Case, async: true

  alias NccWorker.BuildSelection

  setup do
    root = Path.join(System.tmp_dir!(), "ncc-selection-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root}
  end

  defp package(root, name, fixture \\ "circular_buffer-1.0.0") do
    source = Path.join([root, "deps", name])
    File.mkdir_p!(Path.join(source, "lib"))
    File.write!(Path.join(source, "mix.exs"), "defmodule Example.MixProject do end")
    File.write!(Path.join(source, "lib/example.ex"), "defmodule Example do end")
    build = Path.join([root, "_build", "host", "lib", name])
    File.mkdir_p!(Path.dirname(build))
    File.cp_r!(Path.join([__DIR__, "..", "fixture", fixture]), build)
    source
  end

  test "pure Elixir and its pure dependency closure skip firmware", %{root: root} do
    package(root, "wrapper")
    package(root, "leaf")
    graph = %{"root" => ["wrapper", "nerves"], "wrapper" => ["leaf"]}
    assert BuildSelection.classify(root, "wrapper", "A collection", graph) == :pure_elixir
  end

  test "a transitive NIF still requires firmware", %{root: root} do
    package(root, "wrapper")
    package(root, "leaf", "circuits_gpio-2.1.3")
    graph = %{"root" => ["wrapper"], "wrapper" => ["leaf"]}
    assert BuildSelection.classify(root, "wrapper", "", graph) == :firmware
  end

  test "ports are not classified as pure Elixir", %{root: root} do
    package(root, "uart", "circuits_uart-1.5.5")
    assert BuildSelection.classify(root, "uart", "", %{"root" => ["uart"]}) == :firmware
  end

  test "Nerves metadata and target-specific sources require firmware", %{root: root} do
    source = package(root, "sensor")
    graph = %{"root" => ["sensor"]}
    assert BuildSelection.classify(root, "sensor", "A Nerves sensor", graph) == :firmware
    File.write!(Path.join(source, "lib/example.ex"), "Mix.target()")
    assert BuildSelection.classify(root, "sensor", "", graph) == :firmware
  end

  test "native sources are held out even if the host BEAM has no NIF calls", %{root: root} do
    source = package(root, "native")
    File.mkdir_p!(Path.join(source, "c_src"))
    assert BuildSelection.classify(root, "native", "", %{"root" => ["native"]}) == :firmware
  end

  test "missing dependency sources, graph entries or compiled modules fail closed", %{root: root} do
    package(root, "wrapper")
    assert BuildSelection.classify(root, "wrapper", "", %{}) == :firmware
    graph = %{"root" => ["wrapper"], "wrapper" => ["missing"]}
    assert BuildSelection.classify(root, "wrapper", "", graph) == :firmware
    File.rm_rf!(Path.join([root, "_build", "host", "lib", "wrapper", "ebin"]))
    assert BuildSelection.classify(root, "wrapper", "", %{"root" => ["wrapper"]}) == :firmware
  end

  test "dependency cycles terminate and unrelated wrapper dependencies are ignored", %{root: root} do
    package(root, "a")
    package(root, "b")
    graph = %{"root" => ["a", "nerves"], "a" => ["b"], "b" => ["a"]}
    assert BuildSelection.classify(root, "a", "", graph) == :pure_elixir
  end

  test "a failed host compile never implies compatibility", %{root: root} do
    assert BuildSelection.select(root, "sample", "", %{status: :fail}, []) == :firmware
  end

  test "corrupt BEAM evidence keeps firmware enabled", %{root: root} do
    package(root, "sample")
    File.write!(Path.join([root, "_build", "host", "lib", "sample", "ebin", "bad.beam"]), "bad")
    assert BuildSelection.classify(root, "sample", "", %{"root" => ["sample"]}) == :firmware
  end

  test "newly compiled host modules can be classified", %{root: root} do
    package(root, "sample")

    [{module, binary}] =
      Code.compile_quoted(
        quote do
          defmodule NccWorker.TestCompiledPure do
            def size(value), do: byte_size(value)
          end
        end
      )

    path = Path.join([root, "_build", "host", "lib", "sample", "ebin", "#{module}.beam"])
    File.write!(path, binary)
    assert BuildSelection.classify(root, "sample", "", %{"root" => ["sample"]}) == :pure_elixir
  end
end
