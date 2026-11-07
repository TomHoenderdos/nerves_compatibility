defmodule NccWorker.Tracer.ConfigSnapshotTest do
  use ExUnit.Case, async: false

  @limits %{max_entries: 10, max_value: 1024, max_total: 4096}

  # Test-only decoding of values this test encoded itself.
  defp decode(b64), do: b64 |> Base.url_decode64!(padding: false) |> :erlang.binary_to_term()

  defp entries(rows, limits \\ @limits), do: :ncc_tracer_config.entries(rows, limits)

  test "entries are the env rows by app and key, values encoded as manifest values" do
    rows = [{{:env, :logger, :level}, :info}, {{:env, :fx, :k}, [a: 1]}]

    assert {[%{app: "fx", key: "k", value: v1}, %{app: "logger", key: "level", value: v2}], false} =
             entries(rows)

    assert decode(v1) == {:ok, [a: 1]}
    assert decode(v2) == {:ok, :info}

    assert v1 ==
             Base.url_encode64(:erlang.term_to_binary({:ok, [a: 1]}, [:deterministic]),
               padding: false
             )
  end

  test "an oversized value is marked, not encoded; rows past the caps truncate" do
    rows = [
      {{:env, :a, :big}, String.duplicate("x", 2000)},
      {{:env, :b, :k}, 1},
      {{:env, :c, :k}, 2}
    ]

    assert {[%{app: "a", key: "big", value: :null, oversize: true}, %{app: "b", key: "k"}], true} =
             entries(rows, %{@limits | max_entries: 2})

    assert {[%{app: "a"}], true} =
             entries([{{:env, :a, :k}, 1}, {{:env, :b, :k}, String.duplicate("y", 900)}], %{
               @limits
               | max_total: 100
             })
  end

  test "rows whose app or key is not an atom, and rows that are not env rows, are left out" do
    assert {[], false} =
             entries([{{:env, "fx", :k}, 1}, {{:env, :fx, "k"}, 1}, {{:loaded, :fx}, 1}, :junk])
  end

  test "snapshot/0 reads this VM's application env, apps not loaded included" do
    Application.put_env(:ncc_snapshot_test, :k, 7)
    on_exit(fn -> Application.delete_env(:ncc_snapshot_test, :k) end)

    assert {entries, false} = :ncc_tracer_config.snapshot()

    assert %{value: value} =
             Enum.find(entries, &(&1.app == "ncc_snapshot_test" and &1.key == "k"))

    assert decode(value) == {:ok, 7}
  end
end
