defmodule NccWorker.LogTailTest do
  use ExUnit.Case, async: true

  alias NccWorker.LogTail

  # "│" is E2 94 82. Elixir prints it in every compiler warning box, so a
  # byte-boundary cut through it is common, and a result.json carrying the
  # orphaned 0x82 made JSON encoding raise and the worker exit 1.
  test "a cut through a multi-byte character yields valid UTF-8" do
    log = "warning\n" <> String.duplicate("│ x\n", 50)
    tail = LogTail.tail(log, byte_size(log) - 9)

    assert String.valid?(tail)
    assert is_binary(JSON.encode!(%{log_tail: tail}))
  end

  test "keeps at most max_bytes of the end" do
    tail = LogTail.tail(String.duplicate("a", 100) <> "END", 10)
    assert byte_size(tail) <= 10
    assert String.ends_with?(tail, "END")
  end

  test "short valid text is returned unchanged" do
    assert LogTail.tail("all good\n", 4096) == "all good\n"
  end

  test "raw binary bytes inside a log are replaced, not passed through" do
    assert LogTail.tail(<<"ok ", 0xFF, 0xFE, " ok">>, 4096) |> String.valid?()
  end
end
