defmodule Portal.RuntimeReleaseFastPathTest do
  # Reads `config/runtime.exs` with the fast path's variables set, so it
  # changes the process environment and cannot run alongside other tests.
  use ExUnit.Case, async: false

  @runtime Path.expand("../../../../config/runtime.exs", __DIR__)
  @vars ~w(NCC_RELEASE_FAST_PATH NCC_RELEASE_FAST_PATH_BUDGET)

  defp fast_path(env) do
    previous = Map.new(@vars, &{&1, System.get_env(&1)})

    try do
      Enum.each(@vars, &System.delete_env/1)
      Enum.each(env, fn {k, v} -> System.put_env(k, v) end)

      @runtime
      |> Config.Reader.read!(env: :test)
      |> get_in([:portal, Portal.Workers.ReleaseFastPath])
    after
      Enum.each(previous, fn
        {k, nil} -> System.delete_env(k)
        {k, v} -> System.put_env(k, v)
      end)
    end
  end

  test "unset, nothing is overridden" do
    assert fast_path(%{}) in [nil, []]
  end

  test "NCC_RELEASE_FAST_PATH switches it on and off" do
    assert fast_path(%{"NCC_RELEASE_FAST_PATH" => "0"})[:enabled] == false
    assert fast_path(%{"NCC_RELEASE_FAST_PATH" => "1"})[:enabled] == true
    assert fast_path(%{"NCC_RELEASE_FAST_PATH" => "maybe"})[:enabled] == nil
  end

  test "NCC_RELEASE_FAST_PATH_BUDGET takes a non-negative integer and nothing else" do
    assert fast_path(%{"NCC_RELEASE_FAST_PATH_BUDGET" => "250"})[:budget] == 250
    assert fast_path(%{"NCC_RELEASE_FAST_PATH_BUDGET" => "0"})[:budget] == 0
    assert fast_path(%{"NCC_RELEASE_FAST_PATH_BUDGET" => "-1"})[:budget] == nil
    assert fast_path(%{"NCC_RELEASE_FAST_PATH_BUDGET" => "lots"})[:budget] == nil
  end
end
