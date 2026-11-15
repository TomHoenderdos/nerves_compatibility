defmodule NccWorker.FirmwareWorldInputTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, WorldDeps}

  {:ok, members} = Compatibility.Worlds.firmware_members("nerves")
  @nerves members

  defp parse(map), do: map |> JSON.encode!() |> CLI.parse_input()

  test "the nerves world's members pass the worker's own check" do
    assert {:ok, %{name: "nerves", members: @nerves}} = WorldDeps.validate("nerves", @nerves)
  end

  test "a firmware run carries the world as name and members" do
    assert {:ok, %{firmware_world: %{name: "nerves", members: @nerves}}} =
             parse(%{"firmware_world" => %{"name" => "nerves", "members" => @nerves}})
  end

  test "absent is no world" do
    assert {:ok, input} = parse(%{"run_id" => "r"})
    refute Map.has_key?(input, :firmware_world)
  end

  test "it is not the toolchain world: present beside a toolchain world request, both stand" do
    assert {:ok, input} =
             parse(%{
               "mode" => "toolchain",
               "optional_deps" => "world",
               "world" => "phx",
               "world_members" => ["jason"],
               "firmware_world" => %{"name" => "nerves", "members" => @nerves}
             })

    assert input.world == "phx"
    # A toolchain run builds no target: the firmware world is dropped.
    refute Map.has_key?(input, :firmware_world)
  end

  test "argus-only and warm runs ignore it" do
    for mode <- ~w(argus_only warm_nerves toolchain) do
      assert {:ok, input} =
               parse(%{
                 "mode" => mode,
                 "firmware_world" => %{"name" => "nerves", "members" => @nerves}
               })

      refute Map.has_key?(input, :firmware_world), mode
    end
  end

  # A world this image does not pin has no variant name to publish under:
  # the sub-pass would have nothing to label its build with. Ignored, so a
  # portal ahead of the image builds as before rather than failing the run.
  test "a well-formed world this image does not know is ignored" do
    assert {:ok, input} =
             parse(%{"firmware_world" => %{"name" => "nerves2", "members" => @nerves}})

    refute Map.has_key?(input, :firmware_world)
  end

  test "an invalid firmware world exits 10" do
    for world <- [
          %{"name" => "nerves", "members" => ["Bad"]},
          %{"name" => "nerves", "members" => []},
          %{"name" => "nerves", "members" => ["a", "a"]},
          %{"name" => "nerves", "members" => ["jason", "igniter"]},
          %{"name" => "Nerves", "members" => @nerves},
          %{"members" => @nerves},
          "nerves",
          ["nerves"]
        ] do
      assert {:error, {:invalid_world, _}} = outcome = parse(%{"firmware_world" => world})
      assert CLI.exit_code(outcome) == 10
    end
  end
end
