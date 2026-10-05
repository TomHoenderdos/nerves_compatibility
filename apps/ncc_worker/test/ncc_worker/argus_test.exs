defmodule NccWorker.ArgusTest do
  use ExUnit.Case, async: true

  alias NccWorker.Argus

  @config %{analyses: ["default", "exposure"], scope: "firmware", timeout_seconds: 300}
  @pass %{status: :pass}

  setup do
    root = Path.join(System.tmp_dir!(), "ncc-argus-#{System.unique_integer([:positive])}")
    lib = Path.join([root, "_build", "host", "lib"])

    for app <- ["pkg", "dep_a", "nerves_compatibility_test"] do
      File.mkdir_p!(Path.join([lib, app, "ebin"]))
    end

    # A dep directory without an ebin must not become a --dep-ebin.
    File.mkdir_p!(Path.join(lib, "dep_b"))
    on_exit(fn -> File.rm_rf(root) end)
    %{root: root, lib: lib}
  end

  # Fake `System.cmd/3`: `argus version` answers a version line; the `sh`
  # wrapper answers `{stdout, status}` and may write `stderr` to the file the
  # wrapper would have redirected to.
  defp cmd(stdout, status, stderr \\ "") do
    test = self()

    fn
      _bin, ["version"], _opts ->
        {"argus 0.20.1 (Elixir 1.20.3, OTP 29, souffle 2.5)\n", 0}

      "sh", argv, opts ->
        send(test, {:argv, argv, opts})
        {_, file} = List.keyfind(opts[:env], "ARGUS_STDERR_FILE", 0)
        File.write!(file, stderr)
        {stdout, status}
    end
  end

  defp finding(file, extra \\ %{}) do
    Map.merge(
      %{
        "analysis" => "blocking",
        "severity" => "warning",
        "file" => file,
        "line" => 12,
        "end_line" => nil,
        "title" => "Call cycle",
        "at_label" => nil,
        "detail" => "d",
        "help" => ["h"],
        "provenance" => "structural",
        "confidence" => nil,
        "related" => [%{"label" => "l", "file" => file, "line" => 3, "end_line" => nil}]
      },
      extra
    )
  end

  test "skips when argus is not configured", %{root: root} do
    assert Argus.run(root, "pkg", nil, :firmware, @pass) == Argus.skipped()
  end

  test "skips when the host compile did not pass", %{root: root} do
    assert Argus.run(root, "pkg", @config, :firmware, %{status: :fail}).status == :skipped
  end

  test "firmware scope skips pure Elixir packages", %{root: root} do
    assert Argus.run(root, "pkg", @config, :pure_elixir, @pass, cmd: cmd("[]", 0)).status ==
             :skipped
  end

  test "all scope runs pure Elixir packages too", %{root: root} do
    config = %{@config | scope: "all"}
    assert Argus.run(root, "pkg", config, :pure_elixir, @pass, cmd: cmd("[]", 0)).status == :ok
  end

  test "builds the command line", %{root: root, lib: lib} do
    assert Argus.args(root, "pkg", ["default", "exposure"]) == [
             "--project",
             "beams",
             "--ebin",
             Path.join([lib, "pkg", "ebin"]),
             "--dep-ebin",
             Path.join([lib, "dep_a", "ebin"]),
             "--analyses",
             "default,exposure",
             "--format",
             "json",
             "--color",
             "never",
             "--state-dir",
             Path.join(root, ".argus-state")
           ]
  end

  test "wraps argus in timeout with a clean environment", %{root: root} do
    Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd("[]", 0), bin: "/x/argus")

    assert_received {:argv, ["-c", script, "argus-run", "300", "/x/argus" | rest], opts}
    assert script =~ "exec timeout -k 10"
    assert "--include-deps" not in rest
    assert opts[:cd] == root
    assert {"TYPESAFE_API_KEY", nil} in opts[:env]
    assert {"ARGUS_CACHE_DIR", Path.join(root, ".argus-cache")} in opts[:env]
  end

  test "exit 0 parses findings and strips the deps prefix", %{root: root} do
    out = JSON.encode!([finding("deps/pkg/lib/pkg/server.ex")])
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd(out <> "\n", 0))

    assert result.status == :ok
    assert result.version == "0.20.1"
    assert result.analyses == ["default", "exposure"]
    assert is_integer(result.duration_ms)
    assert result.error == nil

    assert [%{"file" => "lib/pkg/server.ex", "related" => [%{"file" => "lib/pkg/server.ex"}]}] =
             result.findings
  end

  test "exit 1 is still a completed run", %{root: root} do
    assert Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd("[]", 1)).status == :ok
  end

  test "stderr noise does not disturb the JSON on stdout", %{root: root} do
    out = JSON.encode!([finding("deps/pkg/lib/a.ex")])
    cmd = cmd(out, 0, "note: sources newer than beams\n")

    assert %{status: :ok, findings: [_]} =
             Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
  end

  test "caps findings at 200", %{root: root} do
    out = JSON.encode!(for i <- 1..201, do: finding("deps/pkg/lib/#{i}.ex"))
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd(out, 0))
    assert length(result.findings) == 200
    assert result.truncated
  end

  test "exit 3 with JSON keeps the findings of the analyses that finished", %{root: root} do
    out = JSON.encode!([finding("deps/pkg/lib/a.ex")])
    cmd = cmd(out, 3, "warning: analysis blocking degraded: souffle timed out\n")
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)

    assert result.status == :ok
    assert [%{"file" => "lib/a.ex"}] = result.findings
    assert result.error == "degraded: warning: analysis blocking degraded: souffle timed out"
  end

  test "stderr that is not UTF-8 or is huge still yields a JSON-safe reason", %{root: root} do
    cmd = cmd("", 2, "ok line\n" <> <<0xFF, 0xFE>> <> String.duplicate("x", 2_000) <> "\n")
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)

    assert String.valid?(result.error)
    assert byte_size(result.error) <= 600
    assert is_binary(JSON.encode!(result))
  end

  for status <- [2, 3, 127] do
    test "exit #{status} is an error with the last stderr line", %{root: root} do
      cmd = cmd("", unquote(status), "first\nsouffle not found on PATH\n")
      result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
      assert result.status == :error
      assert result.findings == []

      assert result.error ==
               "argus exited with status #{unquote(status)}: souffle not found on PATH"
    end
  end

  for status <- [124, 137] do
    test "exit #{status} is a timeout", %{root: root} do
      result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd("", unquote(status)))
      assert %{status: :error, findings: [], error: "timeout after 300s"} = result
    end
  end

  test "non-JSON stdout is an error", %{root: root} do
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd("oops", 0))
    assert %{status: :error, error: "invalid json"} = result
  end

  test "missing package ebin is an error, not a crash", %{root: root, lib: lib} do
    File.rm_rf!(Path.join([lib, "pkg"]))
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd("[]", 0))
    assert %{status: :error, error: "no host beams for pkg"} = result
  end

  test "a raising runner is an error, not a crash", %{root: root} do
    cmd = fn _, _, _ -> raise "boom" end

    assert %{status: :error, error: "boom"} =
             Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
  end
end
