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

    # U+202E reverses the visual order of everything after it, so a package's
    # log can make its own output read as something else entirely on a page that
    # renders it. Trojan Source, aimed at whoever is reading the failure.
    test "strips bidi overrides and isolates" do
      raw = "user\u202Egnp.js\u202C ok \u2066spoof\u2069 \u202A\u202B\u202D done"

      body = LogSanitizer.system_log(raw).body

      assert body == "usergnp.js ok spoof  done"
      refute body =~ "\u202E"
      refute body =~ "\u2066"
    end

    # The embeddings and isolates were covered from the start; the *marks* were
    # not. A single LRM/RLM/ALM is enough to flip the rendered order of a
    # neutral run such as a path, and the zero-width characters hide a word
    # boundary inside an identifier.
    test "strips bidi marks and zero-width characters" do
      raw = "a\u200Eb\u200Fc\u061Cd\u200Be\uFEFFf"

      assert LogSanitizer.system_log(raw).body == "abcdef"
    end

    test "strips C1 controls" do
      raw = "before" <> <<0x80::utf8>> <> <<0x9B::utf8>> <> <<0x9F::utf8>> <> "after"

      assert LogSanitizer.system_log(raw).body == "beforeafter"
    end

    test "strips OSC window-title sequences whole" do
      assert LogSanitizer.system_log("\e]0;pwned\a done").body == " done"
      assert LogSanitizer.system_log("\e]8;;http://evil\e\\link").body == "link"
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
      # Position é so truncation cuts at its 0xA9 continuation byte
      # With @tail_bytes = 409_600:
      # size = 500_000 + 2 + 409_599 = 909_601
      # cut_offset = 909_601 - 409_600 = 500_001
      # é at indices [500_000, 500_001], tail slice starts at 500_001
      text = String.duplicate("h", 500_000) <> "é" <> String.duplicate("t", 400 * 1024 - 1)

      log = LogSanitizer.system_log(text)

      # The body should be valid UTF-8 even after cutting mid-character
      assert String.valid?(log.body)
      # The orphaned continuation byte becomes a replacement character.
      assert log.body =~ "�"
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

    # The strip used to pin the rule to exactly 80 `=`. Nothing tied it to the
    # builder, so a one-character change there would have shipped the docker
    # argv and the host mount paths to the public request page with the suite
    # still green. Build the header from `Portal.Builder` itself.
    test "strips the header Portal.Builder actually writes" do
      job = %{
        run_id: "11111111-2222-3333-4444-555555555555",
        image_name: "ncc-worker",
        image_digest: "sha256:deadbeef"
      }

      header =
        job
        |> Portal.Builder.build_docker_args("/scratch/work", "/scratch/out", "/scratch/files")
        |> Portal.Builder.command_log_header()

      excerpt = LogSanitizer.runner_excerpt(header <> "boom\n")

      refute excerpt =~ "docker run"
      refute excerpt =~ "ncc-worker"
      refute excerpt =~ "Portal.Builder - Docker Execution Log"
      assert excerpt == "boom\n"
    end

    # Docker daemon errors echo the bind source path, and a mount failure is
    # exactly what produces a run-level error_log. The header strip does not
    # help: this text is in the body.
    test "masks the host scratch root out of the body" do
      root = "/Users/deploy/.ncc-scratch"

      raw = """
      docker: Error response from daemon: invalid mount config for type bind:
        bind source path does not exist: #{root}/pkg-1.0.0-123/work
      boom
      """

      excerpt = LogSanitizer.runner_excerpt(raw, root)

      refute excerpt =~ root
      refute excerpt =~ "/Users/deploy"
      assert excerpt =~ "<host>/pkg-1.0.0-123/work"
      assert excerpt =~ "boom"
    end

    test "an unset scratch root leaves the text alone" do
      assert LogSanitizer.runner_excerpt("boom\n", nil) == "boom\n"
      assert LogSanitizer.runner_excerpt("boom\n", "") == "boom\n"
      assert LogSanitizer.runner_excerpt("boom\n", [nil, ""]) == "boom\n"
    end

    # The caches are *siblings* of the scratch root, not children, so masking
    # the scratch root alone left the home directory — and the deploy account
    # name — in the body of any failure that named a cache mount. Every bind
    # source the builder passes has to be masked, not just the first one.
    test "masks every host root the builder mounts, not only the scratch root" do
      roots = ["/Users/deploy/.ncc-scratch", "/Users/deploy/.ncc-nerves-cache"]

      raw = """
      docker: Error response from daemon: invalid mount config for type bind:
        bind source path does not exist: /Users/deploy/.ncc-nerves-cache/artifacts
        while mounting /Users/deploy/.ncc-scratch/pkg-1.0.0-123/work
      boom
      """

      excerpt = LogSanitizer.runner_excerpt(raw, roots)

      refute excerpt =~ "/Users/deploy"
      assert excerpt =~ "<host>/artifacts"
      assert excerpt =~ "<host>/pkg-1.0.0-123/work"
      assert excerpt =~ "boom"
    end

    # A configured root can nest inside another. Replacing the shorter one first
    # splices "<host>" into the middle of the longer one and leaves the rest of
    # the host path published.
    test "masks the longest matching root first" do
      roots = ["/srv/ncc", "/srv/ncc/build-cache"]

      excerpt = LogSanitizer.runner_excerpt("bind source: /srv/ncc/build-cache/x\n", roots)

      assert excerpt == "bind source: <host>/x\n"
    end

    test "defaults the roots to the builder's own" do
      for root <- [
            Portal.Builder.scratch_root(),
            Portal.Builder.nerves_cache(),
            Portal.Builder.hex_cache()
          ] do
        excerpt = LogSanitizer.runner_excerpt("bind source path does not exist: #{root}/x\n")

        refute excerpt =~ root
        assert excerpt =~ "<host>/x"
      end
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
      # Position é so the tail cut lands on its 0xA9 continuation byte rather
      # than on a valid leading byte — otherwise the slice is already valid and
      # the test would pass even with the `scrub/1` wrapper removed.
      #
      # No header and no control characters, so nothing upstream of the cut
      # shifts these offsets. With @runner_bytes = 16_384:
      #   size        = 20_000 + 2 + 16_383 = 36_385
      #   cut_offset  = 36_385 - 16_384     = 20_001
      #   é occupies indices [20_000, 20_001], so the slice starts mid-codepoint.
      text = String.duplicate("x", 20_000) <> "é" <> String.duplicate("t", 16 * 1024 - 1)

      excerpt = LogSanitizer.runner_excerpt(text)

      assert String.valid?(excerpt)
      # The orphaned continuation byte becomes a replacement character.
      assert excerpt =~ "�"
      assert excerpt =~ ~r/truncated, showing the last \d+ bytes of \d+/
    end
  end

  describe "system_log_file/1" do
    setup do
      {:ok, dir: tmp_dir()}
    end

    test "reads a small log whole, matching the in-memory path", %{dir: dir} do
      raw = "\e[31mCompiling 3 files\e[0m\nGenerated jason app\n"
      path = write!(dir, "small.log", raw)

      assert {:ok, log} = LogSanitizer.system_log_file(path)
      assert log == LogSanitizer.system_log(raw)
      refute log.truncated
    end

    test "an empty log round-trips as an empty body", %{dir: dir} do
      path = write!(dir, "empty.log", "")

      assert {:ok, log} = LogSanitizer.system_log_file(path)
      assert log == %{body: "", byte_size: 0, truncated: false}
    end

    # The whole point of the file path: the bytes between head and tail are
    # never read, so a runaway build's log does not become a runaway
    # allocation inside the ingest transaction.
    test "keeps head and tail of an over-cap log without reading the middle", %{dir: dir} do
      head = String.duplicate("h", 400 * 1024)
      middle = String.duplicate("m", 5 * 1024 * 1024)
      tail = String.duplicate("t", 400 * 1024)
      path = write!(dir, "big.log", head <> middle <> tail)

      assert {:ok, log} = LogSanitizer.system_log_file(path)

      assert log.truncated
      assert log.byte_size == 400 * 1024 + 5 * 1024 * 1024 + 400 * 1024
      assert String.starts_with?(log.body, "hhh")
      assert String.ends_with?(log.body, "ttt")
      assert log.body =~ "#{5 * 1024 * 1024} bytes elided by the portal"
      refute log.body =~ "mmm"
    end

    test "never allocates the whole file", %{dir: dir} do
      path = write!(dir, "huge.log", String.duplicate("x", 32 * 1024 * 1024))

      {peak, {:ok, log}} = with_peak_memory(fn -> LogSanitizer.system_log_file(path) end)

      assert log.byte_size == 32 * 1024 * 1024
      # Head + tail is 800 KB. Anything near 32 MB means the file was slurped.
      assert peak < 8 * 1024 * 1024, "allocated #{peak} bytes reading a 32 MB log"
    end

    test "scrubs a codepoint split by the head or tail cut", %{dir: dir} do
      # é straddles the head boundary, and another straddles the tail cut.
      raw =
        String.duplicate("x", 400 * 1024 - 1) <>
          "é" <>
          String.duplicate("m", 1024) <>
          "é" <> String.duplicate("t", 400 * 1024 - 1)

      path = write!(dir, "utf8.log", raw)

      assert {:ok, log} = LogSanitizer.system_log_file(path)
      assert String.valid?(log.body)
      assert log.body =~ "\uFFFD"
    end

    test "refuses a symlink rather than following it", %{dir: dir} do
      secret = write!(dir, "secret.txt", "host filesystem contents")
      link = Path.join(dir, "linked.log")
      File.ln_s!(secret, link)

      assert {:error, {:not_regular, :symlink}} = LogSanitizer.system_log_file(link)
    end

    test "refuses a directory", %{dir: dir} do
      assert {:error, {:not_regular, :directory}} = LogSanitizer.system_log_file(dir)
    end

    test "reports a missing file rather than raising", %{dir: dir} do
      assert {:error, :enoent} = LogSanitizer.system_log_file(Path.join(dir, "nope.log"))
    end
  end

  describe "runner_excerpt_file/2" do
    setup do
      {:ok, dir: tmp_dir()}
    end

    test "matches the in-memory excerpt for a short log", %{dir: dir} do
      raw = "docker: boom\nthe actual error\n"
      path = write!(dir, "runner.log", raw)

      assert {:ok, excerpt} = LogSanitizer.runner_excerpt_file(path, [])
      assert excerpt == LogSanitizer.runner_excerpt(raw, [])
    end

    test "an empty runner log is an empty excerpt", %{dir: dir} do
      path = write!(dir, "runner.log", "")

      assert {:ok, ""} = LogSanitizer.runner_excerpt_file(path, [])
    end

    test "masks host roots inside the tail window", %{dir: dir} do
      root = "/Users/deploy/.ncc-scratch"
      raw = String.duplicate("x", 4096) <> "\nbind source: #{root}/pkg/work\n"
      path = write!(dir, "runner.log", raw)

      assert {:ok, excerpt} = LogSanitizer.runner_excerpt_file(path, [root])
      refute excerpt =~ root
      assert excerpt =~ "<host>/pkg/work"
    end

    # The banner has to name the file's size, not the size of the window that
    # was read off its end — otherwise it understates what was dropped by a
    # factor of however large the log actually was.
    test "reports the file's real size, not the window's", %{dir: dir} do
      raw = String.duplicate("x", 4 * 1024 * 1024) <> "\nthe actual error\n"
      path = write!(dir, "runner.log", raw)

      assert {:ok, excerpt} = LogSanitizer.runner_excerpt_file(path, [])
      assert excerpt =~ "the actual error"
      assert excerpt =~ "showing the last 16384 bytes of #{byte_size(raw)}"
      assert byte_size(excerpt) <= 16 * 1024 + 200
    end

    test "never allocates the whole file", %{dir: dir} do
      path = write!(dir, "runner.log", String.duplicate("x", 32 * 1024 * 1024))

      {peak, {:ok, excerpt}} =
        with_peak_memory(fn -> LogSanitizer.runner_excerpt_file(path, []) end)

      assert byte_size(excerpt) <= 16 * 1024 + 200
      assert peak < 8 * 1024 * 1024, "allocated #{peak} bytes reading a 32 MB log"
    end

    # A short log makes the builder header part of the tail, and that header
    # carries the whole docker argv and every host mount path.
    test "strips the builder header even though only the tail is read", %{dir: dir} do
      header =
        %{
          run_id: "11111111-2222-3333-4444-555555555555",
          image_name: "ncc-worker",
          image_digest: "sha256:deadbeef"
        }
        |> Portal.Builder.build_docker_args("/scratch/work", "/scratch/out", "/scratch/files")
        |> Portal.Builder.command_log_header()

      path = write!(dir, "runner.log", header <> "boom\n")

      assert {:ok, "boom\n"} = LogSanitizer.runner_excerpt_file(path, [])
    end

    test "refuses a symlink rather than following it", %{dir: dir} do
      secret = write!(dir, "secret.txt", "host filesystem contents")
      link = Path.join(dir, "runner.log")
      File.ln_s!(secret, link)

      assert {:error, {:not_regular, :symlink}} = LogSanitizer.runner_excerpt_file(link, [])
    end

    test "reports a missing file rather than raising", %{dir: dir} do
      assert {:error, :enoent} = LogSanitizer.runner_excerpt_file(Path.join(dir, "nope.log"), [])
    end
  end

  defp tmp_dir do
    dir = Path.join(System.tmp_dir!(), "ncc-log-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp write!(dir, name, contents) do
    path = Path.join(dir, name)
    File.write!(path, contents)
    path
  end

  # The fixture binary is built in this process and would dominate any
  # measurement taken here, so the call runs in its own process and that
  # process's own peak is what is reported.
  defp with_peak_memory(fun) do
    parent = self()

    {pid, ref} =
      spawn_monitor(fn ->
        result = fun.()
        send(parent, {:result, self(), :erlang.process_info(self(), :memory), result})
      end)

    receive do
      {:result, ^pid, {:memory, peak}, result} ->
        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          5_000 -> :ok
        end

        {peak, result}
    after
      30_000 -> flunk("timed out reading the fixture")
    end
  end
end
