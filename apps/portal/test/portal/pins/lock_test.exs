defmodule Portal.Pins.LockTest do
  use ExUnit.Case, async: true

  alias Portal.Pins.Lock

  @lock ~S"""
  %{
    "beam_notify": {:hex, :beam_notify, "1.1.1", "inner", [:make, :mix], [{:elixir_make, "~> 0.6", [hex: :elixir_make, repo: "hexpm", optional: false]}], "hexpm", "5a09"},
    "heroicons": {:git, "https://github.com/tailwindlabs/heroicons.git", "88ab", [tag: "v2.1.1", sparse: "optimized", depth: 1]},
    "tz": {:hex, :tzdata, "1.1.2", "inner", [:mix], [{:hackney, "~> 1.17", [hex: :hackney, repo: "hexpm", optional: true]}], "hexpm", "c0ff"},
    "local": {:path, "../local", []},
  }
  """

  test "a lock is read without evaluating it, its atoms never interned" do
    unique = "pinlock_never_an_atom_#{System.unique_integer([:positive])}"
    lock = String.replace(@lock, ":beam_notify,", ":#{unique},")

    assert {:ok, entries} = Lock.parse(lock)

    assert %{
             source: :hex,
             hex: ^unique,
             version: "1.1.1",
             managers: ["make", "mix"],
             checksum: "5a09",
             deps: [
               %{app: "elixir_make", hex: "elixir_make", requirement: "~> 0.6", optional: false}
             ]
           } = entries["beam_notify"]

    assert %{hex: "tzdata", deps: [%{app: "hackney", optional: true}]} = entries["tz"]
    assert entries["heroicons"] == %{source: :git}
    assert entries["local"] == %{source: :path}
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
  end

  test "anything but a literal map is refused" do
    assert {:error, {:not_literal, _}} = Lock.parse(~S|%{"a": File.rm_rf!("/")}|)
    assert {:error, {:not_literal, _}} = Lock.parse(~S|%{"a": x}|)
    assert {:error, :not_a_map} = Lock.parse("[1, 2]")
    assert {:error, :unparsable} = Lock.parse("%{")
  end
end
