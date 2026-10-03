# Argus Static Analysis Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run argus_beam over each package's host-compiled beams inside the worker and show its findings, advisory only, on `/packages/:name`, with the analysis configuration editable from `/admin`.

**Architecture:** The worker image gains Souffle and the `argus` escript. `NccWorker.Argus` runs the escript after the host compile, maps every outcome to a result map, and the worker writes it as a top-level `argus` field in `result.json`. The portal stores admin settings in a singleton `Portal.Settings.Setting`, passes them to the worker through `NCC_INPUT`, stores the worker's `argus` map on `catalog_runs.argus`, and renders it on the package page filtered by a severity floor.

**Tech Stack:** Elixir 1.20 / OTP 29, Mix umbrella, Phoenix 1.8 LiveView, Ash 3 + AshPostgres, Oban, Docker (`ghcr.io/nerves-project/nerves_system_br`, Ubuntu 24.04), argus_beam 0.20.1, Souffle 2.5.

**Spec:** `docs/superpowers/specs/2026-10-03-argus-static-analysis-design.md`

## Global Constraints

- argus is advisory: it never changes a system `status`, `overall_status`, the badge, or worker exit codes `0` / `10` / `11`.
- Pinned versions: argus_beam `0.20.1`, Souffle `2.5`.
- Souffle amd64 `.deb` SHA-512: `6b86e554f6aa5abf8a8b55d8312ae37c0957c5bd6c9edeea89246db9406f645ec5e600b84fe6636b1c163da556f0da6c3d2dad46c1083413f2fcf4f95b9ac62c`; Souffle `2.5` source tarball SHA-256: `5d009ad6c74ccec10207d865c059716afac625759bff7c8070e529bd80385067`.
- Escript path inside the image: `/home/nerves/.mix/escripts/argus`.
- Priors are never enabled: `TYPESAFE_API_KEY` is unset for the argus process; no setting exposes priors.
- Findings cap: 200, with `truncated: true` when capped.
- Defaults: enabled `true`, analyses `["default", "exposure"]`, scope `firmware`, min severity `warning`, timeout `300` s (allowed 30..1800).
- Analysis allow-list: `startup shutdown blocking coupling mailbox failure structure races state_machine ets effects unsafe_input exposure coverage default all security otp`.
- argus severities are exactly `error | warning | info`.
- JSON API (schema v2) is unchanged.
- **Never run `mix deps.*` inside `apps/*`.** Worker tests run from the repo root: `mix test apps/ncc_worker/test/...`. Portal: `mix test`, `mix format`, `mix compile --warnings-as-errors` and `mix ash_postgres.generate_migrations` are fine inside `apps/portal`; do **not** run `mix precommit` (it runs `deps.unlock --unused` and prunes the shared lock).
- Read `apps/portal/AGENTS.md` before touching `apps/portal/`.

## Review Focus

1. **Package with zero host beams for the package itself** (e.g. compile passed but `_build/host/lib/<pkg>/ebin` missing) — argus should be `error` with a readable reason, never crash the worker. Pinned in Task 1 (`missing package ebin` test).
2. **argus prints notices on stderr while still emitting JSON on stdout** — the findings must still parse; stderr must never be mixed into the decoded stdout. Pinned in Task 1 (`stderr noise` test).
3. **Admin unchecks every analysis box** — the form posts no `analyses` key; the update must be rejected with a flash, not silently store `[]` or crash. Pinned in Task 4.
4. **A run ingested before this change** (`argus` is `nil`) or a malformed `argus` map (missing `findings`) — the package page must render without the section and without a 500. Pinned in Task 6.
5. **Finding without `line` or `file`** (argus allows `null`) — the page must still render the finding. Pinned in Task 6.

---

### Task 1: `NccWorker.Argus` — run the escript and map outcomes

**Files:**
- Create: `apps/ncc_worker/lib/ncc_worker/argus.ex`
- Test: `apps/ncc_worker/test/ncc_worker/argus_test.exs`

**Interfaces:**
- Produces:
  - `NccWorker.Argus.skipped() :: result()`
  - `NccWorker.Argus.run(project :: Path.t(), package :: String.t(), config :: map() | nil, selection :: :firmware | :pure_elixir, host_result :: map(), opts :: keyword()) :: result()`
    - `config` keys (atoms): `:analyses` (list of strings), `:scope` (`"firmware" | "all"`), `:timeout_seconds` (integer)
    - `opts`: `:cmd` (3-arity fun with `System.cmd/3`'s contract, default `&System.cmd/3`), `:bin` (default `/home/nerves/.mix/escripts/argus`)
  - `NccWorker.Argus.args(project, package, analyses) :: [String.t()]` (public for tests)
  - `@type result :: %{status: :ok | :error | :skipped, version: String.t() | nil, analyses: [String.t()], duration_ms: non_neg_integer() | nil, findings: [map()], truncated: boolean(), error: String.t() | nil}`

Design notes for the implementer:

- The argus process is wrapped as `sh -c 'exec timeout -k 10 "$@" 2>"$ARGUS_STDERR_FILE"' argus-run <secs> <bin> <args...>`. `timeout` exits `124` on timeout and `137` when it had to SIGKILL; both are timeouts. A missing escript makes `timeout` exit `127`. stdout stays clean JSON because stderr goes to a file.
- All `_build/host/lib/*/ebin` directories except the package itself and the generated wrapper app `nerves_compatibility_test` are passed as `--dep-ebin`. They are whole-program context only: without `--include-deps` argus reports findings for `--ebin` modules alone. (This is a superset of the package's dependency closure; extra context is harmless and saves a second `mix deps.tree`.)
- argus reports `file` relative to the cwd (the project), so a package file reads `deps/<pkg>/lib/x.ex`. Strip the `deps/<pkg>/` prefix on `file` and on each `related[].file`.

- [ ] **Step 1: Write the failing tests**

```elixir
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
             "--project", "beams",
             "--ebin", Path.join([lib, "pkg", "ebin"]),
             "--dep-ebin", Path.join([lib, "dep_a", "ebin"]),
             "--analyses", "default,exposure",
             "--format", "json",
             "--color", "never",
             "--state-dir", Path.join(root, ".argus-state")
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
    assert %{status: :ok, findings: [_]} = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
  end

  test "caps findings at 200", %{root: root} do
    out = JSON.encode!(for i <- 1..201, do: finding("deps/pkg/lib/#{i}.ex"))
    result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd(out, 0))
    assert length(result.findings) == 200
    assert result.truncated
  end

  for {status, label} <- [{2, "status 2"}, {3, "status 3"}, {127, "status 127"}] do
    test "exit #{status} is an error with the last stderr line", %{root: root} do
      cmd = cmd("", unquote(status), "first\nsouffle not found on PATH\n")
      result = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
      assert result.status == :error
      assert result.findings == []
      assert result.error == "argus exited with #{unquote(label)}: souffle not found on PATH"
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
    assert %{status: :error, error: "boom"} = Argus.run(root, "pkg", @config, :firmware, @pass, cmd: cmd)
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from repo root): `mix test apps/ncc_worker/test/ncc_worker/argus_test.exs`
Expected: FAIL — `NccWorker.Argus.skipped/0 is undefined (module NccWorker.Argus is not available)`

- [ ] **Step 3: Implement**

```elixir
defmodule NccWorker.Argus do
  @moduledoc """
  Runs argus_beam's escript over the package's host-compiled beams and returns
  its findings for `result.json`.

  Advisory: nothing here changes a system's status or the worker's exit code.
  Every failure, including a missing escript or souffle, becomes an `:error`
  result with a short reason.
  """

  @bin "/home/nerves/.mix/escripts/argus"
  @max_findings 200
  @default_timeout_seconds 300
  @default_analyses ["default", "exposure"]

  # The generated wrapper application, from `Project.new_project/2`. It is
  # rewritten for every package and is not the package under analysis.
  @wrapper_app "nerves_compatibility_test"

  # stderr goes to a file so stdout stays the JSON document argus prints.
  # `timeout` exits 124 on expiry and 137 when it had to SIGKILL.
  @script ~s(exec timeout -k 10 "$@" 2>"$ARGUS_STDERR_FILE")

  @type result :: %{
          status: :ok | :error | :skipped,
          version: String.t() | nil,
          analyses: [String.t()],
          duration_ms: non_neg_integer() | nil,
          findings: [map()],
          truncated: boolean(),
          error: String.t() | nil
        }

  @spec skipped() :: result()
  def skipped do
    %{
      status: :skipped,
      version: nil,
      analyses: [],
      duration_ms: nil,
      findings: [],
      truncated: false,
      error: nil
    }
  end

  @spec run(Path.t(), String.t(), map() | nil, :firmware | :pure_elixir, map(), keyword()) ::
          result()
  def run(project, package, config, selection, host_result, opts \\ [])
  def run(_project, _package, nil, _selection, _host, _opts), do: skipped()

  def run(_project, _package, _config, _selection, %{status: status}, _opts)
      when status != :pass,
      do: skipped()

  def run(_project, _package, %{scope: "firmware"}, :pure_elixir, _host, _opts), do: skipped()

  def run(project, package, config, _selection, _host, opts) do
    cmd = Keyword.get(opts, :cmd, &System.cmd/3)
    bin = Keyword.get(opts, :bin, @bin)
    analyses = Map.get(config, :analyses) || @default_analyses
    timeout = Map.get(config, :timeout_seconds) || @default_timeout_seconds
    started = System.monotonic_time(:millisecond)

    outcome =
      try do
        analyze(cmd, bin, project, package, analyses, timeout)
      rescue
        e -> %{status: :error, error: Exception.message(e)}
      end

    skipped()
    |> Map.merge(%{analyses: analyses, version: version(cmd, bin, project)})
    |> Map.merge(outcome)
    |> Map.put(:duration_ms, System.monotonic_time(:millisecond) - started)
  end

  @doc false
  @spec args(Path.t(), String.t(), [String.t()]) :: [String.t()]
  def args(project, package, analyses) do
    lib = Path.join([project, "_build", "host", "lib"])

    dep_ebins =
      case File.ls(lib) do
        {:ok, names} -> names
        {:error, _} -> []
      end
      |> Enum.reject(&(&1 in [package, @wrapper_app]))
      |> Enum.sort()
      |> Enum.map(&Path.join([lib, &1, "ebin"]))
      |> Enum.filter(&File.dir?/1)

    ["--project", "beams", "--ebin", Path.join([lib, package, "ebin"])] ++
      Enum.flat_map(dep_ebins, &["--dep-ebin", &1]) ++
      [
        "--analyses",
        Enum.join(analyses, ","),
        "--format",
        "json",
        "--color",
        "never",
        "--state-dir",
        Path.join(project, ".argus-state")
      ]
  end

  defp analyze(cmd, bin, project, package, analyses, timeout) do
    if File.dir?(Path.join([project, "_build", "host", "lib", package, "ebin"])) do
      stderr_file = Path.join(project, ".argus-stderr")

      env = [
        {"ARGUS_CACHE_DIR", Path.join(project, ".argus-cache")},
        {"ARGUS_STDERR_FILE", stderr_file},
        {"TYPESAFE_API_KEY", nil}
      ]

      argv = ["-c", @script, "argus-run", to_string(timeout), bin | args(project, package, analyses)]
      {stdout, status} = cmd.("sh", argv, cd: project, env: env)
      outcome(status, stdout, timeout, stderr_file, package)
    else
      %{status: :error, error: "no host beams for #{package}"}
    end
  end

  defp outcome(status, stdout, _timeout, _stderr_file, package) when status in [0, 1] do
    case JSON.decode(String.trim(stdout)) do
      {:ok, findings} when is_list(findings) ->
        %{
          status: :ok,
          findings: findings |> Enum.take(@max_findings) |> Enum.map(&relativize(&1, package)),
          truncated: length(findings) > @max_findings,
          error: nil
        }

      _ ->
        %{status: :error, error: "invalid json"}
    end
  end

  defp outcome(status, _stdout, timeout, _stderr_file, _package) when status in [124, 137],
    do: %{status: :error, error: "timeout after #{timeout}s"}

  defp outcome(status, _stdout, _timeout, stderr_file, _package),
    do: %{status: :error, error: "argus exited with status #{status}" <> last_line(stderr_file)}

  defp last_line(file) do
    with {:ok, body} <- File.read(file),
         [_ | _] = lines <- String.split(body, "\n", trim: true) do
      ": " <> List.last(lines)
    else
      _ -> ""
    end
  end

  defp relativize(%{} = finding, package) do
    prefix = "deps/#{package}/"

    finding
    |> Map.update("file", nil, &strip(&1, prefix))
    |> Map.update("related", [], fn related ->
      Enum.map(related, fn r -> Map.update(r, "file", nil, &strip(&1, prefix)) end)
    end)
  end

  defp relativize(finding, _package), do: finding

  defp strip(path, prefix) when is_binary(path), do: String.replace_prefix(path, prefix, "")
  defp strip(path, _prefix), do: path

  defp version(cmd, bin, project) do
    case cmd.(bin, ["version"], cd: project, stderr_to_stdout: true) do
      {out, 0} ->
        case Regex.run(~r/\d+\.\d+\.\d+\S*/, out) do
          [version] -> version
          _ -> nil
        end

      _ ->
        nil
    end
  rescue
    _ -> nil
  end
end
```

Note: the "a raising runner" test raises in `version/3` too; `version/3` rescues to `nil` and `analyze/6` raises `"boom"` into the `try`, giving `error: "boom"`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/ncc_worker/test/ncc_worker/argus_test.exs`
Expected: PASS (all tests). Then `mix format` from the root.

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_worker/lib/ncc_worker/argus.ex apps/ncc_worker/test/ncc_worker/argus_test.exs
git commit -m "feat(worker): run argus over host beams as an advisory check"
```

---

### Task 2: Wire argus into the worker contract

**Files:**
- Modify: `apps/ncc_worker/lib/ncc_worker/cli.ex:143` (`@input_keys`)
- Modify: `apps/ncc_worker/lib/ncc_worker/worker.ex` (typespecs ~L21-87, `skipped_gleam/1` ~L186, `skipped_retired/1` ~L222, `evaluate_project/1` ~L265-350, alias block L6-17)
- Modify: `apps/ncc_worker/lib/ncc_worker/json_writer.ex:50-63` (`convert_result_for_json/1`)
- Modify: `apps/ncc_worker/README.md` (NCC_INPUT section)
- Test: `apps/ncc_worker/test/ncc_worker/json_writer_test.exs`

**Interfaces:**
- Consumes: `NccWorker.Argus.run/6`, `NccWorker.Argus.skipped/0` (Task 1).
- Produces: `result.json` top-level `"argus"` object: `{"status", "version", "analyses", "duration_ms", "findings", "truncated", "error"}`; `NCC_INPUT` accepts `"argus": {"analyses": [...], "scope": "firmware"|"all", "timeout_seconds": N}`.

- [ ] **Step 1: Write the failing test** — append to `describe "write_result/2"` in `json_writer_test.exs`:

```elixir
    test "writes the argus result, and null when absent" do
      tmp_dir = System.tmp_dir!() |> Path.join("ncc_test_#{:rand.uniform(1_000_000)}")
      File.mkdir_p!(tmp_dir)
      on_exit(fn -> File.rm_rf!(tmp_dir) end)

      base = %{
        run_id: "r",
        package: %{name: "p", version: "1"},
        image: %{name: "i", digest: "d"},
        toolchain: %{},
        systems: %{},
        finished_at: "2026-10-03T00:00:00Z"
      }

      argus = %{NccWorker.Argus.skipped() | status: :ok, findings: [%{"title" => "t"}]}
      assert :ok = JsonWriter.write_result(tmp_dir, Map.put(base, :argus, argus))
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert decoded["argus"]["status"] == "ok"
      assert decoded["argus"]["findings"] == [%{"title" => "t"}]

      assert :ok = JsonWriter.write_result(tmp_dir, base)
      decoded = tmp_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
      assert Map.has_key?(decoded, "argus")
      assert decoded["argus"] == nil
    end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test apps/ncc_worker/test/ncc_worker/json_writer_test.exs`
Expected: FAIL — `decoded["argus"]` is `nil` / key missing.

- [ ] **Step 3: Implement**

`json_writer.ex`, in `convert_result_for_json/1`, after `finished_at: result.finished_at`:

```elixir
      finished_at: result.finished_at,
      argus: Map.get(result, :argus)
```

`cli.ex:143`, extend the list (keys are atomized only if listed here):

```elixir
  @input_keys ~w(run_id image name digest package version requirement source paths work_dir output_dir files_dir limits per_system_timeout_sec log_tail_bytes systems_filter systems_override argus analyses scope timeout_seconds)a
```

`worker.ex`:

1. Add `Argus` to the alias block (alphabetical: before `BeamScan`).
2. In `@type input`, after `optional(:systems_filter) => [String.t()],` add:

```elixir
          optional(:argus) => %{
            optional(:analyses) => [String.t()],
            optional(:scope) => String.t(),
            optional(:timeout_seconds) => integer()
          },
```

3. In `@type result`, after `finished_at: String.t()` add `, argus: NccWorker.Argus.result()` (make it the last key).
4. In `skipped_gleam/1` and `skipped_retired/1` result maps add `argus: Argus.skipped(),` after `systems: system_results,`.
5. In `evaluate_project/1`, after `source_changes = NccWorker.SourceScanner.diff(...)`:

```elixir
    # Advisory: argus reads the host beams once for every system. Its result
    # never feeds a system status.
    argus =
      Argus.run(project_dir, input.package.name, input[:argus], selection, host_result)
```

   and in the `result` map add `argus: argus,` after `systems: system_results,`.

`README.md` — in the NCC_INPUT section add the optional key and a short paragraph:

```markdown
- `argus` (optional): `{"analyses": ["default", "exposure"], "scope": "firmware", "timeout_seconds": 300}`.
  When present, the worker runs the argus_beam escript over the host-compiled beams
  (`scope: "firmware"` limits this to packages that build firmware) and writes the
  findings to `result.json` as `argus`. Advisory: it never changes a status or the
  exit code. Absent means `argus.status` is `"skipped"`.
```

- [ ] **Step 4: Run worker tests**

Run: `mix test apps/ncc_worker/test/`
Expected: PASS. Then `mix format` and `mix compile --warnings-as-errors` from the root.

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_worker
git commit -m "feat(worker): carry argus config in NCC_INPUT and findings in result.json"
```

---

### Task 3: Souffle and the argus escript in the worker image

**Files:**
- Modify: `apps/ncc_worker/Dockerfile`

**Interfaces:**
- Produces: `souffle` on `PATH`; `/home/nerves/.mix/escripts/argus` (argus_beam 0.20.1), usable by an arbitrary uid.

- [ ] **Step 1: Add the Souffle layer** — after the existing `fakeroot` `RUN`:

```dockerfile
# Souffle evaluates argus's Datalog rules. Upstream ships only an x86_64 .deb;
# arm64 (local Docker on Apple silicon) builds the same tag from source. mcpp is
# the preprocessor souffle runs over every .dl file.
ARG SOUFFLE_VERSION=2.5
RUN set -eux; \
    sudo apt-get update; \
    if [ "$(dpkg --print-architecture)" = "amd64" ]; then \
      deb="x86_64-ubuntu-2404-souffle-${SOUFFLE_VERSION}-Linux.deb"; \
      wget -q "https://github.com/souffle-lang/souffle/releases/download/${SOUFFLE_VERSION}/${deb}" -O "/tmp/${deb}"; \
      echo "6b86e554f6aa5abf8a8b55d8312ae37c0957c5bd6c9edeea89246db9406f645ec5e600b84fe6636b1c163da556f0da6c3d2dad46c1083413f2fcf4f95b9ac62c  /tmp/${deb}" | sha512sum -c -; \
      sudo apt-get install -y --no-install-recommends "/tmp/${deb}"; \
      rm -f "/tmp/${deb}"; \
    else \
      sudo apt-get install -y --no-install-recommends bison flex cmake g++ make mcpp \
        libffi-dev libsqlite3-dev zlib1g-dev libncurses-dev; \
      wget -q "https://github.com/souffle-lang/souffle/archive/refs/tags/${SOUFFLE_VERSION}.tar.gz" -O /tmp/souffle.tar.gz; \
      echo "5d009ad6c74ccec10207d865c059716afac625759bff7c8070e529bd80385067  /tmp/souffle.tar.gz" | sha256sum -c -; \
      tar xzf /tmp/souffle.tar.gz -C /tmp; \
      cmake -S "/tmp/souffle-${SOUFFLE_VERSION}" -B /tmp/souffle-build -DSOUFFLE_ENABLE_TESTING=OFF -DSOUFFLE_GIT=OFF; \
      cmake --build /tmp/souffle-build -j"$(nproc)"; \
      sudo cmake --install /tmp/souffle-build; \
      rm -rf /tmp/souffle*; \
    fi; \
    sudo rm -rf /var/lib/apt/lists/*; \
    souffle --version
```

- [ ] **Step 2: Install the escript** — append to the existing archives `RUN` (after `mix archive.install hex igniter_new --force`) as a separate layer right below it:

```dockerfile
# argus_beam's escript, pinned. The worker calls it by absolute path, so PATH
# under an arbitrary --user uid does not matter. `argus version` fails the image
# build when souffle is missing or broken.
ARG ARGUS_VERSION=0.20.1
RUN mix escript.install hex argus_beam ${ARGUS_VERSION} --force && \
    /home/nerves/.mix/escripts/argus version
```

The existing `chmod -R a+rwX /home/nerves` near the end of the Dockerfile covers the escript.

- [ ] **Step 3: Build and smoke-test locally**

Run (from repo root):
```bash
docker build -f apps/ncc_worker/Dockerfile -t ncc-worker:local .
docker run --rm --user "$(id -u):$(id -g)" --entrypoint /home/nerves/.mix/escripts/argus ncc-worker:local version
```
Expected: build succeeds (arm64 compiles Souffle; allow ~15 min); the run prints argus `0.20.1` and souffle `2.5`, exit 0.

- [ ] **Step 4: Real run on a firmware package**

Run:
```bash
mkdir -p /tmp/argus-smoke/{work,out,files}
echo '{"run_id":"smoke","image":{"name":"ncc-worker:local","digest":"sha256:0"},"package":{"name":"circuits_uart","version":"1.5.5"},"systems_filter":["rpi4"],"argus":{"analyses":["default","exposure"],"scope":"firmware","timeout_seconds":300}}' > /tmp/argus-smoke/work/input.json
docker run --rm --user "$(id -u):$(id -g)" -v /tmp/argus-smoke/work:/work -v /tmp/argus-smoke/out:/out -v /tmp/argus-smoke/files:/files -v ~/.ncc-nerves-cache:/home/nerves/.nerves -v ~/.ncc-hex-cache:/hex-cache ncc-worker:local
jq '.argus | {status, version, duration_ms, n: (.findings|length), error}' /tmp/argus-smoke/out/result.json
```
Expected: `status` is `"ok"`, `version` is `"0.20.1"`, `error` is `null`. If `status` is `"error"`, read `.argus.error` and fix before continuing (likely candidates: `--project beams` path handling, souffle not on PATH under the runtime uid). If the systems filter name differs, use one from `NccWorker.Systems`.

- [ ] **Step 5: Commit**

```bash
git add apps/ncc_worker/Dockerfile
git commit -m "build(worker): add souffle and the argus escript to the image"
```

---

### Task 4: `Portal.Settings` — singleton settings resource

**Files:**
- Create: `apps/portal/lib/portal/settings.ex`
- Create: `apps/portal/lib/portal/settings/setting.ex`
- Modify: `apps/portal/config/config.exs:21` (`ash_domains`)
- Create (generated): migration + resource snapshot under `apps/portal/priv/`
- Test: `apps/portal/test/portal/settings_test.exs`

**Interfaces:**
- Produces:
  - `Portal.Settings.get() :: %Portal.Settings.Setting{}` (defaults when no row)
  - `Portal.Settings.update(map()) :: {:ok, Setting.t()} | {:error, Ash.Error.t()}` — keys `:argus_enabled, :argus_analyses, :argus_scope, :argus_min_severity, :argus_timeout_seconds`
  - `Portal.Settings.worker_argus(Setting.t()) :: map() | nil` — `%{"analyses" => [String.t()], "scope" => String.t(), "timeout_seconds" => integer()}`, `nil` when disabled
  - `Portal.Settings.Setting.analysis_names() :: [atom()]` — the allow-list, in display order
  - Fields: `argus_enabled :: boolean`, `argus_analyses :: [atom]`, `argus_scope :: :firmware | :all`, `argus_min_severity :: :info | :warning | :error`, `argus_timeout_seconds :: integer`

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Portal.SettingsTest do
  use Portal.DataCase, async: false

  alias Portal.Settings

  test "get returns the defaults when nothing is stored" do
    setting = Settings.get()
    assert setting.argus_enabled == true
    assert setting.argus_analyses == [:default, :exposure]
    assert setting.argus_scope == :firmware
    assert setting.argus_min_severity == :warning
    assert setting.argus_timeout_seconds == 300
  end

  test "update stores a single row and get reads it back" do
    assert {:ok, _} =
             Settings.update(%{
               argus_enabled: false,
               argus_analyses: ["otp", "security"],
               argus_scope: "all",
               argus_min_severity: "error",
               argus_timeout_seconds: 600
             })

    assert {:ok, _} = Settings.update(%{argus_timeout_seconds: 900})

    setting = Settings.get()
    assert setting.argus_enabled == false
    assert setting.argus_analyses == [:otp, :security]
    assert setting.argus_scope == :all
    assert setting.argus_min_severity == :error
    assert setting.argus_timeout_seconds == 900
    assert Portal.Repo.aggregate("settings", :count) == 1
  end

  test "rejects an unknown analysis" do
    assert {:error, _} = Settings.update(%{argus_analyses: ["default", "not_an_analysis"]})
  end

  test "rejects an empty analysis list" do
    assert {:error, _} = Settings.update(%{argus_analyses: []})
  end

  test "rejects a timeout outside 30..1800" do
    assert {:error, _} = Settings.update(%{argus_timeout_seconds: 29})
    assert {:error, _} = Settings.update(%{argus_timeout_seconds: 1801})
  end

  test "rejects an unknown scope and severity" do
    assert {:error, _} = Settings.update(%{argus_scope: "everything"})
    assert {:error, _} = Settings.update(%{argus_min_severity: "fatal"})
  end

  test "worker_argus is nil when disabled and the worker map otherwise" do
    assert Settings.worker_argus(Settings.get()) == %{
             "analyses" => ["default", "exposure"],
             "scope" => "firmware",
             "timeout_seconds" => 300
           }

    {:ok, _} = Settings.update(%{argus_enabled: false})
    assert Settings.worker_argus(Settings.get()) == nil
  end
end
```

- [ ] **Step 2: Run to verify failure**

Run (in `apps/portal`): `mix test test/portal/settings_test.exs`
Expected: FAIL — `Portal.Settings` is not available.

- [ ] **Step 3: Implement the resource**

`apps/portal/lib/portal/settings/setting.ex`:

```elixir
defmodule Portal.Settings.Setting do
  @moduledoc """
  Admin-editable runtime settings. One row, keyed `"global"`; read through
  `Portal.Settings.get/0`, which falls back to the defaults when no row exists
  yet so a fresh database never fails a build.
  """

  use Ash.Resource,
    domain: Portal.Settings,
    data_layer: AshPostgres.DataLayer

  # argus_beam 0.20.1's analyses, then its named sets. Tied to the argus
  # version pinned in apps/ncc_worker/Dockerfile: an unknown name makes argus
  # exit 2 on every build, so this list is updated together with that pin.
  @analysis_names [
    :default,
    :otp,
    :security,
    :all,
    :startup,
    :shutdown,
    :blocking,
    :coupling,
    :mailbox,
    :failure,
    :structure,
    :races,
    :state_machine,
    :ets,
    :effects,
    :unsafe_input,
    :exposure,
    :coverage
  ]

  @doc "Every analysis and named set the admin form offers, in display order."
  def analysis_names, do: @analysis_names

  postgres do
    table("settings")
    repo(Portal.Repo)
  end

  actions do
    defaults([:read])

    create :upsert do
      accept([
        :key,
        :argus_enabled,
        :argus_analyses,
        :argus_scope,
        :argus_min_severity,
        :argus_timeout_seconds
      ])

      upsert?(true)
      upsert_identity(:unique_key)
    end
  end

  identities do
    identity(:unique_key, [:key])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :key, :string do
      allow_nil?(false)
      default("global")
      public?(true)
    end

    attribute :argus_enabled, :boolean do
      allow_nil?(false)
      default(true)
      public?(true)
    end

    attribute :argus_analyses, {:array, :atom} do
      allow_nil?(false)
      default([:default, :exposure])
      public?(true)
      constraints(min_length: 1, items: [one_of: @analysis_names])
    end

    attribute :argus_scope, :atom do
      allow_nil?(false)
      default(:firmware)
      public?(true)
      constraints(one_of: [:firmware, :all])
    end

    attribute :argus_min_severity, :atom do
      allow_nil?(false)
      default(:warning)
      public?(true)
      constraints(one_of: [:info, :warning, :error])
    end

    attribute :argus_timeout_seconds, :integer do
      allow_nil?(false)
      default(300)
      public?(true)
      constraints(min: 30, max: 1800)
    end

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end
end
```

`apps/portal/lib/portal/settings.ex`:

```elixir
defmodule Portal.Settings do
  @moduledoc """
  Runtime settings an admin edits from `/admin`. See `Portal.Settings.Setting`.
  """

  use Ash.Domain

  require Ash.Query

  alias Portal.Settings.Setting

  @key "global"

  @defaults %{
    key: @key,
    argus_enabled: true,
    argus_analyses: [:default, :exposure],
    argus_scope: :firmware,
    argus_min_severity: :warning,
    argus_timeout_seconds: 300
  }

  resources do
    resource(Setting)
  end

  @doc "The stored settings, or the defaults when none have been saved."
  @spec get() :: Setting.t()
  def get do
    Setting
    |> Ash.Query.filter(key == ^@key)
    |> Ash.read_one!(domain: __MODULE__)
    |> case do
      nil -> struct(Setting, @defaults)
      setting -> setting
    end
  end

  @doc """
  Saves `params` over the current settings. Unspecified fields keep their
  current value, so a partial update never resets the rest to defaults.
  """
  @spec update(map()) :: {:ok, Setting.t()} | {:error, term()}
  def update(params) do
    current = get() |> Map.take(Map.keys(@defaults))

    Setting
    |> Ash.Changeset.for_create(:upsert, Map.merge(current, Map.put(params, :key, @key)))
    |> Ash.create(domain: __MODULE__)
  end

  @doc "The `argus` key of the worker's `NCC_INPUT`, or nil when argus is off."
  @spec worker_argus(Setting.t()) :: map() | nil
  def worker_argus(%Setting{argus_enabled: false}), do: nil

  def worker_argus(%Setting{} = setting) do
    %{
      "analyses" => Enum.map(setting.argus_analyses, &Atom.to_string/1),
      "scope" => Atom.to_string(setting.argus_scope),
      "timeout_seconds" => setting.argus_timeout_seconds
    }
  end
end
```

`config/config.exs:21`:

```elixir
  ash_domains: [Portal.Accounts, Portal.ScanRequests, Portal.Catalog, Portal.Settings],
```

- [ ] **Step 4: Generate the migration**

Run (in `apps/portal`): `mix ash_postgres.generate_migrations --name add_settings`
Expected: a new `priv/repo/migrations/*_add_settings.exs` creating table `settings` with a unique index on `key`, plus a snapshot under `priv/resource_snapshots/repo/settings/`. Read the migration; it must not touch other tables.

- [ ] **Step 5: Run tests**

Run: `mix test test/portal/settings_test.exs`
Expected: PASS. If `Ash.Type.Atom` rejects string input such as `"otp"` (it casts with `String.to_existing_atom/1`; the atoms exist because `@analysis_names` defines them), stop and report rather than switching the column type.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/settings.ex apps/portal/lib/portal/settings apps/portal/config/config.exs apps/portal/priv apps/portal/test/portal/settings_test.exs
git commit -m "feat(portal): admin-editable settings with argus defaults"
```

---

### Task 5: Admin card for argus settings

**Files:**
- Modify: `apps/portal/lib/portal/admin.ex` (new function)
- Modify: `apps/portal/lib/portal_web/router.ex:100` (route)
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex` (action, `render_admin/2` ~L449, `admin_error_message/1` ~L632)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/admin.html.heex` (new card after the "hex.pm update check" card)
- Test: `apps/portal/test/portal/admin_test.exs`, `apps/portal/test/portal_web/controllers/page_controller_test.exs`

**Interfaces:**
- Consumes: `Portal.Settings.get/0`, `Portal.Settings.update/1`, `Portal.Settings.Setting.analysis_names/0` (Task 4).
- Produces: `Portal.Admin.update_argus_settings(params :: map()) :: {:ok, Setting.t()} | {:error, :invalid_argus_settings}`; route `POST /admin/argus` with params `argus[enabled]`, `argus[analyses][]`, `argus[scope]`, `argus[min_severity]`, `argus[timeout_seconds]`.

- [ ] **Step 1: Write the failing tests**

`admin_test.exs` (inside the module; it already uses `Portal.DataCase`):

```elixir
  describe "update_argus_settings/1" do
    test "maps the form params onto the settings" do
      assert {:ok, setting} =
               Portal.Admin.update_argus_settings(%{
                 "enabled" => "false",
                 "analyses" => ["otp", "exposure"],
                 "scope" => "all",
                 "min_severity" => "info",
                 "timeout_seconds" => "120"
               })

      assert setting.argus_enabled == false
      assert setting.argus_analyses == [:otp, :exposure]
      assert setting.argus_scope == :all
      assert setting.argus_min_severity == :info
      assert setting.argus_timeout_seconds == 120
    end

    test "no ticked analysis is an error, not an empty list" do
      params = %{"enabled" => "true", "scope" => "firmware", "min_severity" => "warning", "timeout_seconds" => "300"}
      assert {:error, :invalid_argus_settings} = Portal.Admin.update_argus_settings(params)
      assert Portal.Settings.get().argus_analyses == [:default, :exposure]
    end
  end
```

`page_controller_test.exs` — add `~p"/admin/argus"` to the path list in "the new admin routes are all closed to anonymous visitors", and add:

```elixir
  test "POST /admin/argus saves the settings and shows them", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_argus")

    conn =
      post(conn, ~p"/admin/argus", %{
        "argus" => %{
          "enabled" => "true",
          "analyses" => ["default", "unsafe_input"],
          "scope" => "all",
          "min_severity" => "error",
          "timeout_seconds" => "600"
        }
      })

    html = html_response(conn, 200)
    assert html =~ "Static analysis (argus)"
    assert html =~ "Saved argus settings."
    assert Portal.Settings.get().argus_analyses == [:default, :unsafe_input]
  end

  test "POST /admin/argus with no analyses flashes an error", %{conn: conn} do
    {conn, _admin} = signed_in_admin(conn, "admin_argus_bad")

    conn =
      post(conn, ~p"/admin/argus", %{
        "argus" => %{"enabled" => "true", "scope" => "firmware", "min_severity" => "warning", "timeout_seconds" => "300"}
      })

    assert html_response(conn, 200) =~ "Tick at least one analysis"
  end
```

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/portal/admin_test.exs test/portal_web/controllers/page_controller_test.exs`
Expected: FAIL — `update_argus_settings/1` undefined; no route `/admin/argus`.

- [ ] **Step 3: Implement**

`admin.ex` — add near the other public functions:

```elixir
  @doc """
  Save the argus card of `/admin`. `params` are the `argus[...]` form fields:
  an unticked checkbox sends nothing, so a missing `analyses` is an empty
  selection and is refused rather than stored.
  """
  @spec update_argus_settings(map()) ::
          {:ok, Portal.Settings.Setting.t()} | {:error, :invalid_argus_settings}
  def update_argus_settings(params) do
    attrs = %{
      argus_enabled: params["enabled"] == "true",
      argus_analyses: params["analyses"] || [],
      argus_scope: params["scope"],
      argus_min_severity: params["min_severity"],
      argus_timeout_seconds: params["timeout_seconds"]
    }

    case Portal.Settings.update(attrs) do
      {:ok, setting} -> {:ok, setting}
      {:error, _} -> {:error, :invalid_argus_settings}
    end
  end
```

`router.ex`, after `post "/admin/update-check", ...`:

```elixir
    post "/admin/argus", PageController, :admin_argus_settings
```

`page_controller.ex` — action after `admin_update_check/2`:

```elixir
  def admin_argus_settings(conn, params) do
    case require_admin(conn) do
      {:ok, conn, user} ->
        case Portal.Admin.update_argus_settings(params["argus"] || %{}) do
          {:ok, _setting} ->
            conn
            |> put_flash(:info, "Saved argus settings.")
            |> render_admin(user)

          {:error, reason} ->
            conn
            |> put_flash(:error, admin_error_message(reason))
            |> render_admin(user)
        end

      {:error, conn} ->
        conn
    end
  end
```

`admin_error_message/1` — add before the catch-all clause:

```elixir
  defp admin_error_message(:invalid_argus_settings),
    do: "Tick at least one analysis and keep the timeout between 30 and 1800 seconds."
```

`render_admin/2` — add two assigns to the `render(conn, :admin, ...)` call:

```elixir
      argus: Portal.Settings.get(),
      argus_analysis_names: Portal.Settings.Setting.analysis_names()
```

`admin.html.heex` — new card after the update-check `</section>`:

```heex
      <section id="argus-settings" class="card border border-base-300 bg-base-100 shadow-sm">
        <div class="card-body">
          <div>
            <h2 class="card-title">Static analysis (argus)</h2>
            <p class="mt-1 text-sm leading-6 text-base-content/70">
              argus_beam runs over each package's host beams and its findings show on the
              package page as advisory. Changes apply to builds started afterwards; the
              severity floor applies to the page immediately.
            </p>
          </div>

          <form method="post" action={~p"/admin/argus"} class="mt-5 space-y-5">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <.admin_page_fields queue_page={@queue_page.page} review_page={@review_page.page} />

            <input type="hidden" name="argus[enabled]" value="false" />
            <label class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="argus[enabled]"
                value="true"
                checked={@argus.argus_enabled}
                class="checkbox checkbox-sm"
              /> Run argus on new builds
            </label>

            <fieldset>
              <legend class="text-sm font-semibold">Analyses</legend>
              <div class="mt-2 grid gap-2 sm:grid-cols-3">
                <label :for={name <- @argus_analysis_names} class="flex items-center gap-2 text-sm">
                  <input
                    type="checkbox"
                    name="argus[analyses][]"
                    value={name}
                    checked={name in @argus.argus_analyses}
                    class="checkbox checkbox-sm"
                  />
                  <span class="font-mono">{name}</span>
                </label>
              </div>
            </fieldset>

            <fieldset>
              <legend class="text-sm font-semibold">Scope</legend>
              <label class="mt-2 flex items-center gap-2 text-sm">
                <input type="radio" name="argus[scope]" value="firmware" checked={@argus.argus_scope == :firmware} class="radio radio-sm" />
                Firmware packages only
              </label>
              <label class="mt-1 flex items-center gap-2 text-sm">
                <input type="radio" name="argus[scope]" value="all" checked={@argus.argus_scope == :all} class="radio radio-sm" />
                All packages
              </label>
            </fieldset>

            <div class="flex flex-wrap gap-5">
              <label class="text-sm">
                <span class="font-semibold">Public severity floor</span>
                <select name="argus[min_severity]" class="select select-sm mt-1 block">
                  <option :for={s <- [:info, :warning, :error]} value={s} selected={@argus.argus_min_severity == s}>
                    {s}
                  </option>
                </select>
              </label>
              <label class="text-sm">
                <span class="font-semibold">Timeout (seconds)</span>
                <input
                  type="number"
                  name="argus[timeout_seconds]"
                  min="30"
                  max="1800"
                  value={@argus.argus_timeout_seconds}
                  class="input input-sm mt-1 block w-32"
                />
              </label>
            </div>

            <button type="submit" class="btn btn-sm btn-primary">Save</button>
          </form>
        </div>
      </section>
```

- [ ] **Step 4: Run tests**

Run: `mix test test/portal/admin_test.exs test/portal_web/controllers/page_controller_test.exs`
Expected: PASS. Then `mix format` and `mix compile --warnings-as-errors` in `apps/portal`.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/admin.ex apps/portal/lib/portal_web apps/portal/test
git commit -m "feat(admin): argus settings card"
```

---

### Task 6: Pass settings to the worker, store and show findings

**Files:**
- Modify: `apps/portal/lib/portal/builder.ex` (`@type build_args` L24, `build/2` job L147-157, `write_worker_input/2` L368-384)
- Modify: `apps/portal/lib/portal/workers/build.ex:89-94` (`build_args`)
- Modify: `apps/portal/lib/portal/catalog/run.ex` (attribute + `:create` accept)
- Modify: `apps/portal/lib/portal/catalog/ingestion.ex:117-131` (`create_run/6`)
- Modify: `apps/portal/lib/portal/catalog.ex` (new `latest_argus/1`)
- Modify: `apps/portal/lib/portal_web/live/package_live.ex` (assigns + section + helpers)
- Create (generated): migration + snapshot for `catalog_runs.argus`
- Test: `apps/portal/test/portal/builder_test.exs`, `apps/portal/test/portal/catalog/ingestion_test.exs`, `apps/portal/test/portal_web/package_argus_test.exs` (new)

**Interfaces:**
- Consumes: `Portal.Settings.get/0`, `Portal.Settings.worker_argus/1` (Task 4); worker `result.json` `argus` field (Task 2).
- Produces:
  - `Portal.Builder.worker_input(job :: map()) :: map()` (public, pure; `job.argus` optional)
  - `build_args` optional key `:argus` (`map() | nil`)
  - `Portal.Catalog.Run` attribute `argus :: map() | nil`
  - `Portal.Catalog.latest_argus(package_name :: String.t()) :: map() | nil`

- [ ] **Step 1: Write the failing tests**

`builder_test.exs`:

```elixir
  describe "worker_input/1" do
    @input_job %{
      run_id: "r1",
      image_name: "ncc-worker",
      image_digest: "sha256:x",
      package: %{"name" => "jason", "version" => "1.4.4", "source" => "hex"},
      systems_filter: nil
    }

    test "carries the argus config when given" do
      argus = %{"analyses" => ["default"], "scope" => "all", "timeout_seconds" => 60}
      assert Builder.worker_input(Map.put(@input_job, :argus, argus))["argus"] == argus
    end

    test "omits argus when off" do
      refute Map.has_key?(Builder.worker_input(Map.put(@input_job, :argus, nil)), "argus")
      refute Map.has_key?(Builder.worker_input(@input_job), "argus")
    end
  end
```

`ingestion_test.exs`:

```elixir
  test "stores the argus result on the run, and nil when the worker sent none" do
    argus = %{"status" => "ok", "version" => "0.20.1", "findings" => [%{"title" => "t"}]}
    sha = "ce51ace18fbd3f0295b9df8305b6655ac8a5c609a2a5995cc852610f55637651"

    {:ok, run} =
      Ingestion.ingest(load_fixture() |> Map.put("argus", argus), %{
        run_id: "argus-1",
        image_digest: "sha256:argus",
        files_dir: seed_files_dir([sha])
      })

    assert run.argus == argus

    {:ok, old} =
      Ingestion.ingest(load_fixture(), %{
        run_id: "argus-2",
        image_digest: "sha256:argus2",
        files_dir: seed_files_dir([sha])
      })

    assert old.argus == nil
  end
```

(Check the opts other fixture tests pass to `Ingestion.ingest/2` at `ingestion_test.exs:39` and match them; add `output_dir`/`log` if they are required.)

`test/portal_web/package_argus_test.exs`:

```elixir
defmodule PortalWeb.PackageArgusTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Portal.Catalog.Ingestion

  defp finding(severity, title, extra \\ %{}) do
    Map.merge(
      %{
        "analysis" => "blocking",
        "severity" => severity,
        "file" => "lib/a.ex",
        "line" => 7,
        "title" => title,
        "detail" => "detail of #{title}",
        "help" => ["help for #{title}"],
        "related" => []
      },
      extra
    )
  end

  defp seed(argus) do
    files = Path.join(System.tmp_dir!(), "pa-f-#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "pa-o-#{System.unique_integer([:positive])}")
    File.mkdir_p!(files)
    File.mkdir_p!(Path.join(out, "logs"))

    on_exit(fn ->
      File.rm_rf(files)
      File.rm_rf(out)
    end)

    result =
      %{
        "package" => %{"name" => "argpkg", "version" => "1.0.0"},
        "finished_at" => "2026-10-03T10:00:00Z",
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      }
      |> then(fn r -> if argus == :absent, do: r, else: Map.put(r, "argus", argus) end)

    {:ok, _} =
      Ingestion.ingest(result, %{
        run_id: "argpkg-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: files,
        output_dir: out,
        log: "runner"
      })

    :ok
  end

  defp ok(findings, extra \\ %{}) do
    Map.merge(
      %{"status" => "ok", "version" => "0.20.1", "analyses" => ["default", "exposure"],
        "findings" => findings, "truncated" => false, "error" => nil},
      extra
    )
  end

  test "shows findings at or above the floor, hides the rest", %{conn: conn} do
    seed(ok([finding("error", "Deadlock"), finding("warning", "Leaked task"), finding("info", "Minor thing")]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(view, "#argus", "advisory")
    assert has_element?(view, "#argus", "argus_beam 0.20.1")
    assert has_element?(view, "#argus", "Deadlock")
    assert has_element?(view, "#argus", "Leaked task")
    assert has_element?(view, "#argus", "lib/a.ex:7")
    refute has_element?(view, "#argus", "Minor thing")
  end

  test "the floor follows the admin setting", %{conn: conn} do
    {:ok, _} = Portal.Settings.update(%{argus_min_severity: "error"})
    seed(ok([finding("error", "Deadlock"), finding("warning", "Leaked task")]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")

    assert has_element?(view, "#argus", "Deadlock")
    refute has_element?(view, "#argus", "Leaked task")
  end

  test "no visible findings says so", %{conn: conn} do
    seed(ok([finding("info", "Minor thing")]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "No findings at warning or above for: default, exposure")
  end

  test "truncation is stated", %{conn: conn} do
    seed(ok([finding("error", "Deadlock")], %{"truncated" => true}))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "first 200 findings")
  end

  test "a finding with no file or line still renders", %{conn: conn} do
    seed(ok([finding("error", "Floating", %{"file" => nil, "line" => nil})]))
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "Floating")
  end

  test "an error says it could not run and hides the reason from visitors", %{conn: conn} do
    seed(%{"status" => "error", "version" => "0.20.1", "findings" => [], "error" => "timeout after 300s"})
    {:ok, view, _} = live(conn, ~p"/packages/argpkg")
    assert has_element?(view, "#argus", "Analysis could not run for this version.")
    refute has_element?(view, "#argus", "timeout after 300s")
  end

  test "skipped, absent and malformed argus render no section", %{conn: conn} do
    # `catalog_runs.argus` is a map column, so a non-map never gets past
    # ingestion; the malformed cases are maps missing or mistyping `findings`.
    malformed = [%{"status" => "ok"}, %{"status" => "ok", "findings" => "x"}]

    for argus <- [%{"status" => "skipped"}, :absent | malformed] do
      seed(argus)
      {:ok, view, _} = live(conn, ~p"/packages/argpkg")
      refute has_element?(view, "#argus")
    end
  end
end
```

Note: in the last test each `seed/1` creates a newer run, so the page reads the latest one each time. If `finished_at` ties make the order unstable, give each seed a distinct `finished_at`.

- [ ] **Step 2: Run to verify failure**

Run: `mix test test/portal/builder_test.exs test/portal/catalog/ingestion_test.exs test/portal_web/package_argus_test.exs`
Expected: FAIL — `Builder.worker_input/1` undefined; `run.argus` key missing; `#argus` not found.

- [ ] **Step 3: Implement the Builder and the Build worker**

`builder.ex` — in `@type build_args` add `optional(:argus) => map() | nil`. In `build/2`'s `job` map add `argus: Map.get(args, :argus)` after `systems_filter`. Replace `write_worker_input/2`'s map construction with a public pure function:

```elixir
  @doc "The `NCC_INPUT` document for `job`. Pure, so tests need no Docker."
  @spec worker_input(map()) :: map()
  def worker_input(job) do
    %{
      "run_id" => job.run_id,
      "image" => %{"name" => job.image_name, "digest" => job.image_digest},
      "package" => job.package,
      "paths" => %{
        "work_dir" => "/work",
        "output_dir" => "/out",
        "files_dir" => "/files"
      }
    }
    |> maybe_put("systems_filter", job.systems_filter)
    |> maybe_put("argus", Map.get(job, :argus))
  end

  # work_dir is the run scratch directory constructed by build/2; input.json is fixed.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_worker_input(job, work_dir) do
    File.write!(Path.join(work_dir, "input.json"), Jason.encode_to_iodata!(worker_input(job)))
    :ok
  rescue
    e -> {:error, {:input_write_failed, Exception.message(e)}}
  end
```

`workers/build.ex` `do_build/7` — add to `build_args`:

```elixir
      image_digest: image_digest,
      # Read per build, so an admin change applies from the next build on.
      argus: Portal.Settings.worker_argus(Portal.Settings.get())
```

- [ ] **Step 4: Implement storage**

`run.ex`: add `:argus` to `create :create`'s `accept` list, and the attribute after `:toolchain`:

```elixir
    # The worker's advisory argus_beam result (`NccWorker.Argus`), verbatim.
    # Nil for runs from images before argus, and never read by any status.
    attribute :argus, :map do
      public?(true)
    end
```

`ingestion.ex` `create_run/6`: add `argus: result["argus"],` after `toolchain: result["toolchain"],`.

Run (in `apps/portal`): `mix ash_postgres.generate_migrations --name add_run_argus`
Expected: a migration adding nullable `argus` (`map`/jsonb) to `catalog_runs` and nothing else.

`catalog.ex` — public function next to `latest_system_results/1`:

```elixir
  @doc """
  The argus result of the package's latest run, or nil. Its own query because
  `@run_fields` leaves `argus` out: every other reader of runs would otherwise
  load the findings for nothing.
  """
  def latest_argus(package_name) do
    with [package] <- packages(package_name),
         [run] <-
           Run
           |> Ash.Query.filter(package_id == ^package.id)
           |> Ash.Query.sort(finished_at: :desc, inserted_at: :desc)
           |> Ash.Query.select([:id, :argus])
           |> Ash.Query.limit(1)
           |> Ash.read!(domain: __MODULE__) do
      run.argus
    else
      _ -> nil
    end
  end
```

- [ ] **Step 5: Implement the package page section**

`package_live.ex` `mount/3` — add assigns in the found branch:

```elixir
         |> assign(:argus, argus_view(Catalog.latest_argus(name)))
         |> assign(:argus_floor, Portal.Settings.get().argus_min_severity)
         |> assign(:admin?, Portal.Accounts.admin?(socket.assigns[:current_user]))
```

Helpers (private, bottom of the module):

```elixir
  @severity_rank %{"error" => 3, "warning" => 2, "info" => 1}

  # Only well-formed `ok` and `error` results render. Anything else -- skipped,
  # a run from before argus, a map missing its findings -- renders nothing.
  defp argus_view(%{"status" => "ok", "findings" => findings} = argus) when is_list(findings),
    do: argus

  defp argus_view(%{"status" => "error"} = argus), do: argus
  defp argus_view(_), do: nil

  defp visible_findings(findings, floor) do
    min = Map.fetch!(@severity_rank, Atom.to_string(floor))

    findings
    |> Enum.filter(&(Map.get(@severity_rank, &1["severity"], 0) >= min))
    |> Enum.sort_by(&(-Map.get(@severity_rank, &1["severity"], 0)))
  end

  defp finding_location(%{"file" => file, "line" => line}) when is_binary(file) and is_integer(line),
    do: "#{file}:#{line}"

  defp finding_location(%{"file" => file}) when is_binary(file), do: file
  defp finding_location(_), do: nil

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class(_), do: "badge-ghost"
```

Template — insert after the systems table's closing `</div>` (before the "Add this badge" block, `package_live.ex` ~L163):

```heex
        <section
          :if={@argus}
          id="argus"
          class="space-y-4 rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div>
            <h2 class="text-sm font-semibold text-base-content">OTP analysis</h2>
            <p class="mt-1 text-sm text-base-content/60">
              Static analysis of the compiled beams, advisory — by
              <a href="https://hex.pm/packages/argus_beam" target="_blank" rel="noopener" class="link">
                argus_beam {@argus["version"]}
              </a>. It does not affect the compatibility result.
            </p>
          </div>

          <%= if @argus["status"] == "error" do %>
            <p class="text-sm text-base-content/70">Analysis could not run for this version.</p>
            <p :if={@admin?} class="font-mono text-xs text-base-content/50">{@argus["error"]}</p>
          <% else %>
            <% visible = visible_findings(@argus["findings"], @argus_floor) %>
            <p :if={visible == []} class="text-sm text-base-content/70">
              No findings at {@argus_floor} or above for: {Enum.join(@argus["analyses"] || [], ", ")}
            </p>
            <ul :if={visible != []} class="divide-y divide-base-200">
              <li :for={{finding, i} <- Enum.with_index(visible)} id={"argus-finding-#{i}"} class="py-3">
                <div class="flex flex-wrap items-center gap-2">
                  <span class={["badge badge-sm", severity_class(finding["severity"])]}>
                    {finding["severity"]}
                  </span>
                  <span class="font-medium text-base-content">{finding["title"]}</span>
                  <span class="badge badge-sm badge-outline font-mono">{finding["analysis"]}</span>
                </div>
                <div :if={finding_location(finding)} class="mt-1 font-mono text-xs text-base-content/60">
                  {finding_location(finding)}
                </div>
                <details class="mt-1 text-sm text-base-content/70">
                  <summary class="cursor-pointer text-xs">Details</summary>
                  <p :if={finding["at_label"]}>{finding["at_label"]}</p>
                  <p :if={finding["detail"]} class="mt-1">{finding["detail"]}</p>
                  <ul :if={finding["help"] not in [nil, []]} class="mt-1 list-disc pl-5">
                    <li :for={hint <- List.wrap(finding["help"])}>{hint}</li>
                  </ul>
                  <ul :if={finding["related"] not in [nil, []]} class="mt-1 font-mono text-xs">
                    <li :for={rel <- finding["related"]}>
                      {rel["label"]} — {finding_location(rel)}
                    </li>
                  </ul>
                </details>
              </li>
            </ul>
            <p :if={@argus["truncated"]} class="text-xs text-base-content/50">
              Showing the first 200 findings argus reported.
            </p>
          <% end %>
        </section>
```

- [ ] **Step 6: Run tests**

Run: `mix test test/portal/builder_test.exs test/portal/catalog/ingestion_test.exs test/portal_web/package_argus_test.exs test/portal/workers`
Expected: PASS. Then the whole portal suite: `mix test`; `mix format`; `mix compile --warnings-as-errors`.

- [ ] **Step 7: Commit**

```bash
git add apps/portal
git commit -m "feat(portal): pass argus settings to builds and show findings on package pages"
```

---

### Task 7: Integration test, docs, sample measurement

**Files:**
- Modify: `apps/portal/test/portal/workers/build_integration_test.exs`
- Modify: `CLAUDE.md` (steps 4 of "How a Package Gets Checked"; "Container / Caching Details")
- Modify: `docs/superpowers/specs/2026-10-03-argus-static-analysis-design.md` (two corrections, below)

**Interfaces:**
- Consumes: everything above; a freshly built `ncc-worker:local` (Task 3).

- [ ] **Step 1: Extend the integration test**

In the existing jason test, after `assert run.overall_status == :pass`, add (jason is pure Elixir, so the default `firmware` scope skips it):

```elixir
    assert run.argus["status"] == "skipped"
```

Add a second test copying the first test's setup (scan request, `image_digest`, `%Oban.Job{}`, `Build.perform/1`, then the `Ingest` job), with `Portal.Settings.update(%{argus_scope: "all"})` before `Build.perform/1`, using version `"1.4.3"` so the (package, version, digest) dedupe does not skip it, and asserting:

```elixir
    assert run.argus["status"] == "ok", inspect(run.argus)
    assert run.argus["version"] == "0.20.1"
    assert is_list(run.argus["findings"])
```

- [ ] **Step 2: Run the integration test**

Run (from repo root, image from Task 3 built): `make test-integration`
Expected: PASS for both tests.

- [ ] **Step 3: Update docs**

`CLAUDE.md`, step 4: after "...builds firmware per Nerves system," insert "runs the advisory argus_beam analysis over the host beams (`NccWorker.Argus`)," and in "Container / Caching Details" add:

```markdown
- The image carries Souffle 2.5 and the argus_beam escript at `/home/nerves/.mix/escripts/argus`. amd64 installs Souffle's upstream `.deb`; arm64 builds it from source, so a local `make build` on Apple silicon takes noticeably longer.
- argus is configured from `/admin` (`Portal.Settings`) and passed through `NCC_INPUT.argus`. Its findings are advisory and never change a status.
```

Spec corrections (record what the implementation does):
- In "Worker → `NccWorker.Argus` → Command": replace the `<dep>` bullet with "every `_build/host/lib/*/ebin` except the package and the generated wrapper app `nerves_compatibility_test` — a superset of the closure, which saves a second `mix deps.tree`."
- In "Worker → Image": "amd64 installs the upstream `.deb` (SHA-512 pinned); arm64 builds Souffle 2.5 from source (SHA-256 pinned), since upstream ships no arm64 package and Ubuntu 24.04 has none."

- [ ] **Step 4: Sample run on real firmware packages**

For `vintage_net`, `circuits_uart`, `nerves_hub_link`, run the Task 3 Step 4 command with that package (latest version from hex.pm) and record from each `result.json`:

```bash
jq '{pkg: .package.name, status: .argus.status, ms: .argus.duration_ms, n: (.argus.findings|length), by_sev: (.argus.findings|group_by(.severity)|map({(.[0].severity): length})|add)}' /tmp/argus-smoke/out/result.json
```

Paste the table into the PR description. If any run exceeds 240 s or is `error`, raise it before merging; if the warning/error findings on these well-maintained packages look like false positives, raise that too — it decides whether the default floor should be `error`.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/test/portal/workers/build_integration_test.exs CLAUDE.md docs/superpowers/specs/2026-10-03-argus-static-analysis-design.md
git commit -m "test: argus in the Docker integration test; docs"
```
