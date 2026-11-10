defmodule Compatibility.RecordedValueTest do
  use ExUnit.Case, async: true

  alias Compatibility.RecordedValue

  defp encode(term, opts \\ [:deterministic]),
    do: term |> :erlang.term_to_binary(opts) |> Base.url_encode64(padding: false)

  describe "acceptable?/1, accepted" do
    test "a plain atom" do
      assert RecordedValue.acceptable?(encode(:ok))
    end

    test "a plain binary" do
      assert RecordedValue.acceptable?(encode("hello"))
    end

    test "a nested map and list" do
      term = %{a: [1, 2, {:ok, "x"}], b: %{c: :d}}
      assert RecordedValue.acceptable?(encode(term))
    end

    test "the real sample recorded for :error" do
      assert RecordedValue.acceptable?("g3cFZXJyb3I")
    end

    test "a binary exactly at the 64 KiB boundary" do
      # `term_to_binary/2` adds a small header; pad so the whole encoded
      # term lands at exactly 65_536 bytes.
      header_size = byte_size(:erlang.term_to_binary(<<>>, [:deterministic]))
      payload = :binary.copy(<<0>>, 65_536 - header_size)
      bin = :erlang.term_to_binary(payload, [:deterministic])
      assert byte_size(bin) == 65_536
      assert RecordedValue.acceptable?(Base.url_encode64(bin, padding: false))
    end
  end

  describe "acceptable?/1, refused" do
    test "compressed ETF" do
      # Small or low-redundancy terms don't actually compress (OTP keeps
      # the uncompressed form when it would be smaller), so use a term
      # redundant enough that `compressed: 9` really emits the <<131, 80>>
      # marker.
      term = List.duplicate(:ok, 2000)
      bin = :erlang.term_to_binary(term, compressed: 9)
      assert <<131, 80, _rest::binary>> = bin
      refute RecordedValue.acceptable?(Base.url_encode64(bin, padding: false))
    end

    test "over 64 KiB" do
      bin = :erlang.term_to_binary(:binary.copy(<<0>>, 70_000), [:deterministic])
      assert byte_size(bin) > 65_536
      refute RecordedValue.acceptable?(Base.url_encode64(bin, padding: false))
    end

    test "a fun" do
      refute RecordedValue.acceptable?(encode(fn -> :ok end))
    end

    test "a pid" do
      refute RecordedValue.acceptable?(encode(self()))
    end

    test "a port" do
      port = Port.open({:spawn, "cat"}, [:binary])
      refute RecordedValue.acceptable?(encode(port))
      Port.close(port)
    end

    test "a reference" do
      refute RecordedValue.acceptable?(encode(make_ref()))
    end

    test "a fun nested in a map value" do
      refute RecordedValue.acceptable?(encode(%{key: fn -> :ok end}))
    end

    test "a fun in an improper-list tail" do
      refute RecordedValue.acceptable?(encode([1, 2 | fn -> :ok end]))
    end

    test "garbage base64" do
      refute RecordedValue.acceptable?("not valid base64!!")
    end

    test "garbage ETF" do
      garbage = Base.url_encode64(<<1, 2, 3, 4, 5>>, padding: false)
      refute RecordedValue.acceptable?(garbage)
    end

    test "a non-binary input" do
      refute RecordedValue.acceptable?(nil)
      refute RecordedValue.acceptable?(123)
    end
  end
end
