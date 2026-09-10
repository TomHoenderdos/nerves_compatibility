defmodule Portal.Catalog.LogSanitizerTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.LogSanitizer

  describe "system_log/1" do
    test "passes clean text through unchanged" do
      log = LogSanitizer.system_log("Compiling 3 files\nGenerated jason app\n")

      assert log.body == "Compiling 3 files\nGenerated jason app\n"
      assert log.byte_size == 38
      refute log.truncated
    end

    test "replaces invalid UTF-8 with the replacement character" do
      log = LogSanitizer.system_log(<<"ok ", 0xFF, " done">>)

      assert log.body == "ok \uFFFD done"
      assert String.valid?(log.body)
    end

    test "strips ANSI CSI sequences" do
      log = LogSanitizer.system_log("\e[31merror\e[0m here")

      assert log.body == "error here"
    end

    test "strips C0 controls and carriage returns but keeps tab and newline" do
      raw = "a\tb\nc" <> <<0>> <> "d" <> <<13>> <> "e"

      assert LogSanitizer.system_log(raw).body == "a\tb\ncde"
    end

    test "truncates head + tail, marks the elision, keeps the original size" do
      head = String.duplicate("h", 400 * 1024)
      middle = String.duplicate("m", 1024)
      tail = String.duplicate("t", 400 * 1024)

      log = LogSanitizer.system_log(head <> middle <> tail)

      assert log.truncated
      assert log.byte_size == 801 * 1024
      assert String.starts_with?(log.body, "hhh")
      assert String.ends_with?(log.body, "ttt")
      assert log.body =~ "1024 bytes elided by the portal"
      assert log.body =~ "\n\n[..."
      assert log.body =~ "...]\n\n"
      refute log.body =~ "mmm"
    end

    test "re-scrubs head slice to prevent UTF-8 corruption at truncation boundary" do
      # Create text where a multi-byte character (é = 0xC3 0xA9 in UTF-8) straddles the head boundary
      head = String.duplicate("x", 400 * 1024 - 1)
      # 0xC3 0xA9 is é, placed so 0xC3 is the last byte of the head slice
      codepoint_straddling_boundary = "é"
      tail = String.duplicate("t", 400 * 1024)

      log = LogSanitizer.system_log(head <> codepoint_straddling_boundary <> tail)

      # The body should be valid UTF-8 even after truncation
      assert String.valid?(log.body)
      # The replacement character should appear instead of orphaned bytes
      assert log.body =~ "�"
    end

    test "re-scrubs tail slice to prevent UTF-8 corruption at truncation boundary" do
      # Create text where a multi-byte character straddles the tail boundary
      head = String.duplicate("h", 400 * 1024)
      middle = String.duplicate("m", 1000)
      # Place a multi-byte character right at where the tail boundary would cut
      tail = "éé" <> String.duplicate("t", 400 * 1024 - 2)

      log = LogSanitizer.system_log(head <> middle <> tail)

      # The body should be valid UTF-8
      assert String.valid?(log.body)
    end
  end

  describe "runner_excerpt/1" do
    test "strips the Portal.Builder docker command header" do
      raw = """
      ================================================================================
      Portal.Builder - Docker Execution Log
      Started: 2026-09-10T08:00:00Z
      Command: docker run --rm -v /var/lib/ncc/scratch/x:/work ncc-worker:local
      ================================================================================

      == Compilation error in file lib/x.ex ==
      """

      excerpt = LogSanitizer.runner_excerpt(raw)

      refute excerpt =~ "docker run"
      refute excerpt =~ "/var/lib/ncc/scratch"
      assert excerpt =~ "Compilation error"
    end

    test "keeps only the tail and reports byte counts" do
      raw = String.duplicate("x", 20 * 1024) <> "\nthe actual error\n"

      excerpt = LogSanitizer.runner_excerpt(raw)

      assert excerpt =~ "the actual error"
      # Check for the exact marker format with byte counts
      assert excerpt =~ ~r/truncated, showing the last \d+ bytes of \d+/
      assert byte_size(excerpt) <= 16 * 1024 + 200
    end

    test "leaves a short log alone" do
      assert LogSanitizer.runner_excerpt("boom\n") == "boom\n"
    end

    test "re-scrubs runner tail to prevent UTF-8 corruption at truncation boundary" do
      # Create a log larger than 16 KB with a multi-byte character near the end
      large_head = String.duplicate("x", 17 * 1024)
      tail_with_multibyte = "é" <> String.duplicate("t", 100)

      excerpt = LogSanitizer.runner_excerpt(large_head <> tail_with_multibyte)

      # The excerpt should be valid UTF-8
      assert String.valid?(excerpt)
      # Should have the truncation marker
      assert excerpt =~ ~r/truncated, showing the last \d+ bytes/
    end
  end
end
