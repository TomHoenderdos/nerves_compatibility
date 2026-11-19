defmodule Compatibility.PinsTest do
  use ExUnit.Case, async: true

  alias Compatibility.Pins

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)
  @c String.duplicate("c", 64)

  defp dep(name, version, checksum, hex \\ nil),
    do: %{"name" => name, "hex" => hex || name, "version" => version, "checksum" => checksum}

  defp pins(deps, package_checksum \\ @a) do
    hash =
      Pins.hash(%{
        package: "ecto",
        version: "3.12.5",
        package_checksum: package_checksum,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => package_checksum, "deps" => deps}
  end

  describe "hash/1" do
    test "sha256 over the package line and the sorted dependency lines" do
      deps = [dep("telemetry", "1.3.0", @c), dep("decimal", "2.3.0", @b)]
      text = "ecto 3.12.5 #{@a}\ndecimal 2.3.0 #{@b}\ntelemetry 1.3.0 #{@c}\n"
      want = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower)

      assert Pins.hash(%{package: "ecto", version: "3.12.5", package_checksum: @a, deps: deps}) ==
               want

      # Order-independent.
      assert Pins.hash(%{
               package: "ecto",
               version: "3.12.5",
               package_checksum: @a,
               deps: Enum.reverse(deps)
             }) == want
    end
  end

  describe "validate/3" do
    test "a well-formed set passes and comes back as given" do
      p = pins([dep("decimal", "2.3.0", @b), dep("tz", "1.0.0", @c, "tzdata")])
      assert {:ok, %{"hash" => _, "deps" => [_, _]}} = Pins.validate("ecto", "3.12.5", p)
    end

    test "an empty closure is a set" do
      assert {:ok, _} = Pins.validate("ecto", "3.12.5", pins([]))
    end

    test "every malformed field is refused" do
      cases = [
        {"not a map", :not_a_map},
        {%{"hash" => "x", "package_checksum" => @a, "deps" => []}, :hash_mismatch},
        {pins([dep("Decimal", "2.3.0", @b)]), {:name, "Decimal"}},
        {pins([dep("decimal", "2.3.0", @b, "Dec")]), {:name, "Dec"}},
        {pins([dep(String.duplicate("a", 65), "1.0.0", @b)]), {:name, String.duplicate("a", 65)}},
        {pins([dep("decimal", "two", @b)]), {:version, "two"}},
        {pins([dep("decimal", "2.3.0", String.upcase(@b))]), {:checksum, String.upcase(@b)}},
        {pins([], "short"), {:checksum, "short"}},
        {pins([dep("decimal", "2.3.0", @b), dep("decimal", "2.3.0", @b)]),
         {:duplicate, "decimal"}},
        {pins([dep("nerves", "1.0.0", @b)]), {:tooling, "nerves"}},
        {pins([dep("nerves_system_rpi4", "1.0.0", @b)]), {:tooling, "nerves_system_rpi4"}},
        {pins([dep("nerves_toolchain_x", "1.0.0", @b)]), {:tooling, "nerves_toolchain_x"}},
        {pins([dep("nerves_bootstrap", "1.0.0", @b)]), {:tooling, "nerves_bootstrap"}},
        {pins([dep("ecto", "3.12.5", @b)]), {:package_itself, "ecto"}},
        {%{"hash" => @a, "package_checksum" => @a, "deps" => "x"}, :deps_not_a_list}
      ]

      for {input, why} <- cases do
        assert Pins.validate("ecto", "3.12.5", input) == {:error, {:invalid_pins, why}},
               "#{inspect(input, limit: 3)}"
      end
    end

    test "more than 200 dependencies is refused" do
      deps = for i <- 1..201, do: dep("d#{i}", "1.0.0", @b)

      assert {:error, {:invalid_pins, {:too_many, 201}}} =
               Pins.validate("ecto", "3.12.5", pins(deps))
    end

    test "nerves_runtime is a package, not tooling" do
      assert {:ok, _} =
               Pins.validate("ecto", "3.12.5", pins([dep("nerves_runtime", "0.13.0", @b)]))
    end
  end

  describe "compare/2" do
    test "equal when names, versions and checksums agree" do
      deps = [dep("decimal", "2.3.0", @b)]
      assert Pins.compare(deps, %{"decimal" => %{"version" => "2.3.0", "checksum" => @b}}) == :ok
    end

    test "names the extra, missing and differing dependencies" do
      deps = [dep("decimal", "2.3.0", @b), dep("jason", "1.4.0", @c), dep("tz", "1.0.0", @c)]

      locked = %{
        "decimal" => %{"version" => "2.2.0", "checksum" => @b},
        "jason" => %{"version" => "1.4.0", "checksum" => @a},
        "plug" => %{"version" => "1.0.0", "checksum" => @a}
      }

      assert {:mismatch, "pins_closure_mismatch", diff} = Pins.compare(deps, locked)
      assert diff == %{extra: ["plug"], missing: ["tz"], differing: ["decimal", "jason"]}
    end

    test "a checksum alone differing is a checksum mismatch" do
      deps = [dep("jason", "1.4.0", @c)]
      locked = %{"jason" => %{"version" => "1.4.0", "checksum" => @a}}

      assert {:mismatch, "pins_checksum_mismatch", %{differing: ["jason"]}} =
               Pins.compare(deps, locked)
    end

    test "no lock at all is a closure mismatch" do
      assert {:mismatch, "pins_closure_mismatch", %{missing: ["jason"]}} =
               Pins.compare([dep("jason", "1.4.0", @c)], nil)
    end
  end

  test "describe/2 names the deps as +extra -missing ~differing" do
    assert Pins.describe("pins_closure_mismatch", %{
             extra: ["a"],
             missing: ["b"],
             differing: ["c"]
           }) ==
             "pins_closure_mismatch (+a -b ~c)"

    assert Pins.describe("pins_unresolvable", %{extra: [], missing: [], differing: []}) ==
             "pins_unresolvable"
  end

  test "to_lock/1 is the deps_lock shape" do
    assert Pins.to_lock([dep("tz", "1.0.0", @c, "tzdata")]) ==
             %{"tz" => %{"version" => "1.0.0", "checksum" => @c}}
  end

  test "dev_only/0 names test and doc tooling" do
    assert "floki" in Pins.dev_only()
    assert "ex_doc" in Pins.dev_only()
  end
end
