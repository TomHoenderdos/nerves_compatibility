defmodule Compatibility.KinoAssetsAtomsTest do
  # The portal reads beams a package's compile wrote, on a node that lives
  # on across ingests: never an atom of theirs (`Compatibility.KinoAssets`,
  # as `Compatibility.DeterministicBeams` reads them). Not async: the atom
  # count is the VM's, and another test making atoms meanwhile would show.
  use ExUnit.Case, async: false

  alias Compatibility.KinoAssets

  @moduletag :tmp_dir

  @hash "uxwh53kfq2wszgf23hqwgkuiza"
  @cdn "https://repo.hex.pm/preview/kino_vega_lite/0.1.13/lib/assets/vega_lite/build"

  # A beam compiled in a VM of its own, as Kino.JS's quote compiles it, whose
  # module and other functions name atoms this VM has never seen.
  defp foreign_beam(dir) do
    tag = "q#{System.unique_integer([:positive])}x#{:rand.uniform(1_000_000_000)}"
    module = "Elixir.Fresh#{tag}"
    path = Path.join(dir, "fresh.beam")

    code = """
    [{_, bin}] = Code.compile_string(~S'''
    defmodule Fresh#{tag} do
      @compile :debug_info
      def __assets_info__() do
        %{archive_path: "x", js_path: "main.js", hash: #{inspect(@hash)}, cdn_url: #{inspect(@cdn)}}
      end
      def names, do: [#{Enum.map_join(1..200, ", ", &":#{tag}_#{&1}")}]
    end
    ''')
    File.write!(#{inspect(path)}, bin)
    """

    {_, 0} = System.cmd("elixir", ["-e", code], stderr_to_stdout: true)
    {module, File.read!(path)}
  end

  # Loading a module makes its own atoms: each function runs once, on a beam
  # of this VM's own, before anything is counted.
  setup do
    lists = File.read!(:code.which(:lists))
    _ = KinoAssets.exports_assets_info(lists)
    _ = KinoAssets.assets_info(lists, "lists")
    :ok
  end

  test "reading a beam's exports makes no atom of its names", %{tmp_dir: dir} do
    {module, bytes} = foreign_beam(dir)
    before = :erlang.system_info(:atom_count)
    assert KinoAssets.exports_assets_info(bytes) == {:ok, module, true}
    assert :erlang.system_info(:atom_count) == before
  end

  test "reading a beam's __assets_info__/0 makes no atom of its names", %{tmp_dir: dir} do
    {module, bytes} = foreign_beam(dir)
    before = :erlang.system_info(:atom_count)
    assert KinoAssets.assets_info(bytes, module) == {:ok, %{hash: @hash, cdn_url: @cdn}}
    assert :erlang.system_info(:atom_count) == before
  end
end
