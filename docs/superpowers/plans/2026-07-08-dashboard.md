# Dashboard Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Dashboard at `/` with five summary sections (Top failure clusters, Pass rate per system, Native code, Recently passing, Recently failing), backed by a portal-side failure classifier, persisted native-code data, and new Catalog queries; move the package browser to `/packages`.

**Architecture:** Add two nullable fields to `SystemResult` (`failure_category`, `log_tail`) and one to `Package` (`native_components`) via Ash + generated migration. A pure `FailureClassifier` runs at ingestion over each non-pass system's `log_tail`/`error`. New `Catalog` read functions aggregate latest results in Elixir (matching the existing `Ash.read!` + `Enum` style). A new `DashboardLive` renders the sections with Beacon components; `IndexLive` moves to `/packages`.

**Tech Stack:** Elixir, Ash 3 + AshPostgres 2, Phoenix 1.8 LiveView, Beacon components (`PortalWeb.UI`), Tailwind/daisyUI.

## Global Constraints

- All work under `apps/portal/`. Run `mix` from the **repo root** (`/Users/tomhoenderdos/Projects/nerves_compatibility`) — the umbrella deps lock lives there; LiveView/DB/Ash tasks fail from `apps/portal/`.
- UI + Catalog + ingestion only. Do NOT change the worker, `result.json` contract, Docker, JSON API schema, badge, precompiled API, or Oban.
- Classification is **portal-side**; the worker already emits `log_tail`, `error`, and `result.package.native_components` — do not add worker fields.
- Catalog queries return plain maps/lists (no Ash structs leaking to the web layer), matching the existing `Ash.read!` + `Enum` style in `catalog.ex`.
- Failure categories are exactly these strings (first match wins, else fallback): `"NIF built for wrong architecture"`, `"Precompiled NIF missing for target"`, `"Dependency resolution failed"`, `"Compilation error"`, `"Other / unclassified"`. `classify/1` returns `nil` for pass/skipped.
- GIT SCOPING: the branch has UNRELATED pre-existing uncommitted changes. Stage ONLY each task's named files. NEVER `git add -A`/`.`/`commit -a`. After each commit run `git show --stat HEAD` and confirm only intended files.
- Preserve regression-critical IndexLive hooks when moving it: stream dom id `package-<name>`, `phx-change="search"` with param `q`, text `Nerves Compatibility`.
- `mix precommit` (from `apps/portal` after the umbrella is compiled, or the individual commands from root) and umbrella `mix test` must be green at the end.

---

### Task 1: Schema — failure_category, log_tail, native_components

**Files:**
- Modify: `apps/portal/lib/portal/catalog/system_result.ex` (actions accept lists ~24-47; attributes ~50-91)
- Modify: `apps/portal/lib/portal/catalog/package.ex` (create/upsert accept ~22-35; attributes ~42-64)
- Create: migration under `apps/portal/priv/repo/migrations/` (generated)
- Test: `apps/portal/test/portal/catalog/schema_fields_test.exs`

**Interfaces:**
- Produces: `SystemResult` accepts `:failure_category` and `:log_tail` on `:create` and `:failure_category` on `:update`; `Package` accepts `:native_components` on `:create` and `:upsert` (and in `upsert_fields`). All nullable, `public?(true)`.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/schema_fields_test.exs
defmodule Portal.Catalog.SchemaFieldsTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Package, Run, SystemResult}

  test "SystemResult persists failure_category and log_tail; Package persists native_components" do
    {:ok, pkg} =
      Package
      |> Ash.Changeset.for_create(:create, %{
        name: "schematest",
        native_components: %{"nif_language" => "rust", "port_languages" => []}
      })
      |> Ash.create(domain: Catalog)

    assert pkg.native_components == %{"nif_language" => "rust", "port_languages" => []}

    {:ok, run} =
      Run
      |> Ash.Changeset.for_create(:create, %{
        run_id: "schematest-1",
        package_id: pkg.id,
        version_tested: "1.0.0",
        image_digest: "sha256:x",
        overall_status: :fail
      })
      |> Ash.create(domain: Catalog)

    {:ok, sr} =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{
        run_id: run.id,
        system_pkg: "nerves_system_rpi0",
        status: :fail,
        log_tail: "cannot execute binary file",
        failure_category: "NIF built for wrong architecture"
      })
      |> Ash.create(domain: Catalog)

    assert sr.failure_category == "NIF built for wrong architecture"
    assert sr.log_tail == "cannot execute binary file"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/schema_fields_test.exs`
Expected: FAIL — `failure_category`/`log_tail`/`native_components` are not accepted attributes.

- [ ] **Step 3: Add the SystemResult fields**

In `system_result.ex`, extend the `:create` accept list (after `:log_path`) with `:log_tail, :failure_category`, extend the `:update` accept list (after `:log_path`) with `:failure_category`, and add these attributes inside `attributes do` (after the `log_path` attribute):

```elixir
    attribute :log_tail, :string do
      public?(true)
    end

    attribute :failure_category, :string do
      public?(true)
    end
```

- [ ] **Step 4: Add the Package field**

In `package.ex`, add `:native_components` to the `:create` accept, the `:upsert` accept, and the `upsert_fields` list, and add the attribute (after `last_run_at`):

```elixir
    attribute :native_components, :map do
      public?(true)
    end
```

- [ ] **Step 5: Generate + run the migration**

Run (from repo root):
```bash
mix ash.codegen add_dashboard_fields
mix ecto.migrate
```
Expected: a new migration file appears under `apps/portal/priv/repo/migrations/`, adds the three columns, migrate succeeds. (If `ash.codegen` errors on the umbrella, run `cd apps/portal && mix ash.codegen add_dashboard_fields` then `cd - && mix ecto.migrate`.)

- [ ] **Step 6: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/schema_fields_test.exs`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal/catalog/system_result.ex apps/portal/lib/portal/catalog/package.ex apps/portal/test/portal/catalog/schema_fields_test.exs apps/portal/priv/repo/migrations apps/portal/priv/resource_snapshots
git commit -m "feat(portal): add failure_category, log_tail, native_components catalog fields"
```

---

### Task 2: FailureClassifier

**Files:**
- Create: `apps/portal/lib/portal/catalog/failure_classifier.ex`
- Test: `apps/portal/test/portal/catalog/failure_classifier_test.exs`

**Interfaces:**
- Produces: `Portal.Catalog.FailureClassifier.classify(sys :: map) :: String.t() | nil`. `sys` has string keys `"status"`, `"log_tail"`, `"error"` (any may be missing). Returns `nil` for pass/skipped, else one of the five category strings.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/failure_classifier_test.exs
defmodule Portal.Catalog.FailureClassifierTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.FailureClassifier, as: FC

  test "pass and skipped classify to nil" do
    assert FC.classify(%{"status" => "pass", "log_tail" => "anything"}) == nil
    assert FC.classify(%{"status" => "skipped"}) == nil
  end

  test "wrong-architecture NIF" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "sh: cannot execute binary file: Exec format error"}) ==
             "NIF built for wrong architecture"
  end

  test "missing precompiled NIF" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "could not find precompiled NIF for target rpi0"}) ==
             "Precompiled NIF missing for target"
  end

  test "dependency resolution failure" do
    assert FC.classify(%{"status" => "error", "log_tail" => "Failed to use \"foo\" because no matching version"}) ==
             "Dependency resolution failed"
  end

  test "compilation error" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "** (CompileError) lib/foo.ex:3: undefined function bar/0"}) ==
             "Compilation error"
  end

  test "unmatched non-pass falls back to Other" do
    assert FC.classify(%{"status" => "fail", "log_tail" => "mysterious teapot failure"}) ==
             "Other / unclassified"
  end

  test "reads the error field too and tolerates missing keys" do
    assert FC.classify(%{"status" => "fail", "error" => "Exec format error"}) ==
             "NIF built for wrong architecture"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/failure_classifier_test.exs`
Expected: FAIL — module undefined.

- [ ] **Step 3: Implement the classifier**

```elixir
# apps/portal/lib/portal/catalog/failure_classifier.ex
defmodule Portal.Catalog.FailureClassifier do
  @moduledoc """
  Maps a failed system build to a coarse failure category by matching its
  `log_tail`/`error` text against an ordered ruleset. Portal-side; pure.
  """

  @fallback "Other / unclassified"

  # Ordered — first match wins.
  @rules [
    {"NIF built for wrong architecture",
     ~r/wrong ELF class|cannot execute binary|invalid ELF header|Exec format error|incompatible architecture/i},
    {"Precompiled NIF missing for target",
     ~r/could not find.*(\.so|nif|precompiled)|no precompiled|precompiled.*(not found|not available|missing)|error loading NIF/i},
    {"Dependency resolution failed",
     ~r/failed to use|unable to resolve|dependency resolution|no matching version|could not fetch|mix deps\.get.*fail/i},
    {"Compilation error",
     ~r/\(CompileError\)|== Compilation error|undefined function|\berror:\s/i}
  ]

  @spec classify(map) :: String.t() | nil
  def classify(sys) when is_map(sys) do
    status = sys |> Map.get("status") |> to_string()

    if status in ["pass", "skipped"] do
      nil
    else
      text = "#{Map.get(sys, "log_tail")}\n#{Map.get(sys, "error")}"

      Enum.find_value(@rules, @fallback, fn {category, regex} ->
        if Regex.match?(regex, text), do: category
      end)
    end
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/failure_classifier_test.exs`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/catalog/failure_classifier.ex apps/portal/test/portal/catalog/failure_classifier_test.exs
git commit -m "feat(portal): failure classifier (log-based category ruleset)"
```

---

### Task 3: Ingestion wiring

**Files:**
- Modify: `apps/portal/lib/portal/catalog/ingestion.ex` (`create_system_result/*`; `upsert_package/*`)
- Test: `apps/portal/test/portal/catalog/ingestion_dashboard_test.exs`

**Interfaces:**
- Consumes: `FailureClassifier.classify/1`; `SystemResult` `:log_tail`/`:failure_category`; `Package` `:native_components`.
- Produces: ingested failing systems carry `log_tail` + `failure_category`; ingested packages carry `native_components`.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/ingestion_dashboard_test.exs
defmodule Portal.Catalog.IngestionDashboardTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  @result %{
    "package" => %{
      "name" => "dashpkg",
      "version" => "0.1.0",
      "description" => "x",
      "native_components" => %{"nif_language" => "rust", "port_languages" => []}
    },
    "finished_at" => "2026-07-01T10:00:00Z",
    "systems" => %{
      "nerves_system_rpi0" => %{
        "status" => "fail",
        "log_tail" => "sh: cannot execute binary file: Exec format error",
        "firmware_size_bytes" => nil
      }
    }
  }

  test "ingestion stores log_tail, failure_category, and native_components" do
    dir = Path.join(System.tmp_dir!(), "ingest-dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _run} =
      Ingestion.ingest(@result, %{
        run_id: "dashpkg-1",
        image_digest: "sha256:x",
        files_dir: dir,
        log: "log"
      })

    [sr] = Catalog.latest_system_results("dashpkg")
    assert sr.status == :fail
    assert sr.log_tail =~ "Exec format error"
    assert sr.failure_category == "NIF built for wrong architecture"

    %{packages: %{"dashpkg" => pkg}} = Catalog.latest_by_pkg_json("dashpkg")
    assert pkg.native_components == %{"nif_language" => "rust", "port_languages" => []}
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/ingestion_dashboard_test.exs`
Expected: FAIL — `log_tail`/`failure_category` nil, `native_components` absent (and `latest_by_pkg_json` may not expose it yet — see Step 3 note).

- [ ] **Step 3: Wire the ingestion**

In `ingestion.ex`, in `create_system_result/*`, add to the `:create` attrs map:

```elixir
        log_tail: sys["log_tail"],
        failure_category: Portal.Catalog.FailureClassifier.classify(sys),
```

In `upsert_package/*`, change the `:upsert` attrs map to include `native_components` from the info map. The function currently builds `%{name:, description:, latest_version:, last_run_at:}` — add:

```elixir
      native_components: info["native_components"],
```

Also confirm `latest_by_pkg_json/1`'s `package_json/*` exposes `native_components` on the package entry — if the test reads `pkg.native_components` and it is the Ash struct, it is already present; the test asserts the value directly from the ingested `Package`, so no `package_json` change is required. (If `latest_by_pkg_json` returns a trimmed map without `native_components`, read the package via `Portal.Catalog` in the test instead — but prefer exposing it. Add `native_components: package.native_components` to the `package_json/*` map so the web layer can use it.)

- [ ] **Step 4: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/ingestion_dashboard_test.exs`
Expected: PASS.

- [ ] **Step 5: Run existing catalog tests to check no regression**

Run (from repo root): `mix test apps/portal/test/portal_web/catalog_live_test.exs apps/portal/test/portal/catalog`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/catalog/ingestion.ex apps/portal/test/portal/catalog/ingestion_dashboard_test.exs
git commit -m "feat(portal): classify + persist log_tail, failure_category, native_components at ingestion"
```

---

### Task 4: Catalog dashboard queries

**Files:**
- Modify: `apps/portal/lib/portal/catalog.ex` (add public functions + one private helper)
- Test: `apps/portal/test/portal/catalog/dashboard_queries_test.exs`

**Interfaces:**
- Consumes: existing private `packages/1`, `latest_runs/1`, `system_results_for_runs/1` in `catalog.ex`; `Ash.read!`.
- Produces:
  - `pass_rate_per_system() :: [%{system_pkg: String.t(), pass: integer, total: integer, rate: float}]`
  - `recent_runs(status :: :pass | :fail, limit :: integer) :: [%{package: String.t(), version: String.t(), finished_at: DateTime.t(), overall_status: atom}]`
  - `failure_clusters(limit :: integer) :: [%{category: String.t(), systems: integer, packages: integer}]`
  - `native_breakdown() :: [%{language: String.t(), packages: integer}]`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/dashboard_queries_test.exs
defmodule Portal.Catalog.DashboardQueriesTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, version, systems, native \\ nil, finished \\ "2026-07-01T10:00:00Z") do
    dir = Path.join(System.tmp_dir!(), "dq-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version, "native_components" => native},
      "finished_at" => finished,
      "systems" => systems
    }

    {:ok, _} = Ingestion.ingest(result, %{run_id: "#{name}-#{version}", image_digest: "sha256:x", files_dir: dir, log: "l"})
  end

  test "queries aggregate seeded runs" do
    ingest("passer", "1.0.0",
      %{"nerves_system_rpi0" => %{"status" => "pass"}, "nerves_system_x86_64" => %{"status" => "pass"}},
      %{"nif_language" => "rust", "port_languages" => []}, "2026-07-02T10:00:00Z")

    ingest("failer", "2.0.0",
      %{"nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"},
        "nerves_system_x86_64" => %{"status" => "pass"}},
      nil, "2026-07-03T10:00:00Z")

    rates = Catalog.pass_rate_per_system()
    rpi0 = Enum.find(rates, &(&1.system_pkg == "nerves_system_rpi0"))
    assert rpi0.total == 2 and rpi0.pass == 1

    recent_fail = Catalog.recent_runs(:fail, 5)
    assert hd(recent_fail).package == "failer"

    recent_pass = Catalog.recent_runs(:pass, 5)
    assert Enum.any?(recent_pass, &(&1.package == "passer"))

    clusters = Catalog.failure_clusters(10)
    arch = Enum.find(clusters, &(&1.category == "NIF built for wrong architecture"))
    assert arch.systems == 1 and arch.packages == 1

    native = Catalog.native_breakdown()
    assert Enum.any?(native, &(&1.language == "rust" and &1.packages == 1))
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/dashboard_queries_test.exs`
Expected: FAIL — functions undefined.

- [ ] **Step 3: Implement the queries**

Add to `catalog.ex` (public functions near the other `def`s; the private helper near the existing private helpers). Uses the existing `packages/1`, `latest_runs/1`, `system_results_for_runs/1`:

```elixir
  @doc "Latest system results across all packages, annotated with the package name."
  defp latest_annotated_systems do
    packages = packages(nil)
    runs = latest_runs(packages)

    run_to_pkg =
      packages
      |> Enum.reduce(%{}, fn pkg, acc ->
        case Map.get(runs, pkg.id) do
          nil -> acc
          run -> Map.put(acc, run.id, pkg.name)
        end
      end)

    run_to_pkg
    |> Map.keys()
    |> system_results_for_runs()
    |> Enum.map(fn sr ->
      %{
        package: Map.get(run_to_pkg, sr.run_id),
        system_pkg: sr.system_pkg,
        status: sr.status,
        failure_category: sr.failure_category
      }
    end)
  end

  @doc "Per-system pass counts over the latest run of every package."
  def pass_rate_per_system do
    latest_annotated_systems()
    |> Enum.group_by(& &1.system_pkg)
    |> Enum.map(fn {system_pkg, rows} ->
      total = length(rows)
      pass = Enum.count(rows, &(&1.status == :pass))
      %{system_pkg: system_pkg, pass: pass, total: total, rate: if(total > 0, do: pass / total, else: 0.0)}
    end)
    |> Enum.sort_by(& &1.system_pkg)
  end

  @doc "Most recently finished passing (:pass) or failing (:fail/:error) runs."
  def recent_runs(status, limit \\ 5) do
    wanted = if status == :pass, do: [:pass], else: [:fail, :error]
    pkgs = Package |> Ash.read!(domain: __MODULE__) |> Map.new(&{&1.id, &1})

    Run
    |> Ash.read!(domain: __MODULE__)
    |> Enum.filter(&(&1.overall_status in wanted and not is_nil(&1.finished_at)))
    |> Enum.sort_by(& &1.finished_at, {:desc, DateTime})
    |> Enum.take(limit)
    |> Enum.map(fn run ->
      %{
        package: (pkgs[run.package_id] && pkgs[run.package_id].name),
        version: run.version_tested,
        finished_at: run.finished_at,
        overall_status: run.overall_status
      }
    end)
  end

  @doc "Non-pass systems grouped by failure_category with occurrence + distinct-package counts."
  def failure_clusters(limit \\ 10) do
    latest_annotated_systems()
    |> Enum.filter(&(&1.status in [:fail, :error] and not is_nil(&1.failure_category)))
    |> Enum.group_by(& &1.failure_category)
    |> Enum.map(fn {category, rows} ->
      %{
        category: category,
        systems: length(rows),
        packages: rows |> Enum.map(& &1.package) |> Enum.uniq() |> length()
      }
    end)
    |> Enum.sort_by(& &1.systems, :desc)
    |> Enum.take(limit)
  end

  @doc "Packages grouped by native implementation language (NIF + ports), plus a pure-Elixir bucket."
  def native_breakdown do
    Package
    |> Ash.read!(domain: __MODULE__)
    |> Enum.flat_map(fn pkg ->
      nc = pkg.native_components || %{}
      langs = [nc["nif_language"] | nc["port_languages"] || []] |> Enum.reject(&is_nil/1)
      if langs == [], do: [{"Pure Elixir / none", pkg.name}], else: Enum.map(langs, &{&1, pkg.name})
    end)
    |> Enum.group_by(fn {lang, _} -> lang end, fn {_, name} -> name end)
    |> Enum.map(fn {language, names} -> %{language: language, packages: names |> Enum.uniq() |> length()} end)
    |> Enum.sort_by(& &1.packages, :desc)
  end
```

If `packages/1`, `latest_runs/1`, or `system_results_for_runs/1` are not exactly these names, grep `catalog.ex` for the private helpers `latest_by_pkg_json/1` uses and call those — they are the ones building "latest run per package".

- [ ] **Step 4: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/dashboard_queries_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/catalog.ex apps/portal/test/portal/catalog/dashboard_queries_test.exs
git commit -m "feat(portal): catalog dashboard queries (pass rate, recent runs, clusters, native)"
```

---

### Task 5: DashboardLive + move browser to /packages

**Files:**
- Create: `apps/portal/lib/portal_web/live/dashboard_live.ex`
- Modify: `apps/portal/lib/portal_web/router.ex` (the `:public` `live_session` block)
- Modify: `apps/portal/lib/portal_web/live/index_live.ex` (`Layouts.app` `active`)
- Modify: `apps/portal/lib/portal_web/live/package_live.ex` (back link `~p"/"` → `~p"/packages"`; not-found navigate)
- Modify: `apps/portal/lib/portal_web/live/request_live.ex` (back link `~p"/"` → `~p"/packages"`)
- Modify: `apps/portal/lib/portal_web/components/site_nav.ex` (Packages link → `/packages`)
- Modify: `apps/portal/test/portal_web/catalog_live_test.exs` (index test targets `~p"/packages"`)
- Test: `apps/portal/test/portal_web/dashboard_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.{pass_rate_per_system, recent_runs, failure_clusters, native_breakdown}`; `PortalWeb.UI.{page_header, stat_card, status_badge}`; `Layouts.app`.
- Produces: route `/` → `DashboardLive` (active `:home`), `/packages` → `IndexLive` (active `:packages`).

- [ ] **Step 1: Move the route + update the existing index test (regression guard first)**

In `router.ex`, inside the existing `live_session :public, on_mount: [...] do ... end`, change the live routes so `/` maps to the dashboard and the browser moves:

```elixir
      live "/", DashboardLive, :index
      live "/packages", IndexLive, :index
      live "/packages/:name", PackageLive, :show
      live "/requests/:id", RequestLive, :show
```

In `catalog_live_test.exs`, change the index browser test's `live(conn, ~p"/")` to `live(conn, ~p"/packages")` (leave the package-detail test on `~p"/packages/#{...}"`).

- [ ] **Step 2: Run the moved index test — expect it to fail to compile/route until DashboardLive exists**

Run (from repo root): `mix test apps/portal/test/portal_web/catalog_live_test.exs`
Expected: FAIL — `DashboardLive` undefined (router references it).

- [ ] **Step 3: Write the DashboardLive test**

```elixir
# apps/portal/test/portal_web/dashboard_live_test.exs
defmodule PortalWeb.DashboardLiveTest do
  use PortalWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "dashboard renders all five section headings", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Top failure clusters"
    assert html =~ "Pass rate per system"
    assert html =~ "Native code"
    assert html =~ "Recently checked passing"
    assert html =~ "Recently checked failing"
  end

  test "dashboard shows a failure cluster and a recent failing package with data", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "dash-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "dashfail", "version" => "1.0.0"},
          "finished_at" => "2026-07-04T10:00:00Z",
          "systems" => %{"nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"}}
        },
        %{run_id: "dashfail-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "NIF built for wrong architecture"
    assert html =~ "dashfail"
  end
end
```

- [ ] **Step 4: Run the dashboard test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/dashboard_live_test.exs`
Expected: FAIL — `DashboardLive` undefined.

- [ ] **Step 5: Implement DashboardLive**

```elixir
# apps/portal/lib/portal_web/live/dashboard_live.ex
defmodule PortalWeb.DashboardLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:clusters, Catalog.failure_clusters(8))
     |> assign(:rates, Catalog.pass_rate_per_system())
     |> assign(:native, Catalog.native_breakdown())
     |> assign(:recent_pass, Catalog.recent_runs(:pass, 5))
     |> assign(:recent_fail, Catalog.recent_runs(:fail, 5))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:home} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Dashboard" title="Nerves Compatibility">
          <:subtitle>Build results across every Nerves system, summarized.</:subtitle>
          <:actions>
            <a href={~p"/packages"} class="inline-flex items-center gap-2 rounded-xl bg-primary px-5 py-3 text-sm font-semibold text-primary-content shadow-sm transition hover:brightness-95">
              Browse packages
            </a>
          </:actions>
        </PortalWeb.UI.page_header>

        <.section title="Top failure clusters">
          <.empty :if={@clusters == []}>No failures recorded yet.</.empty>
          <ul :if={@clusters != []} class="divide-y divide-base-200">
            <li :for={c <- @clusters} class="flex items-center justify-between py-3">
              <span class="font-medium text-base-content">{c.category}</span>
              <span class="font-mono text-sm text-base-content/60">{c.systems} / {c.packages} pkg</span>
            </li>
          </ul>
        </.section>

        <.section title="Pass rate per system">
          <.empty :if={@rates == []}>No system results yet.</.empty>
          <ul :if={@rates != []} class="space-y-3">
            <li :for={r <- @rates} class="space-y-1">
              <div class="flex items-center justify-between text-sm">
                <span class="font-mono text-base-content">{r.system_pkg}</span>
                <span class="text-base-content/60">{r.pass}/{r.total} · {round(r.rate * 100)}%</span>
              </div>
              <div class="h-2 w-full overflow-hidden rounded-full bg-base-200">
                <div class="h-full rounded-full bg-emerald-400 dark:bg-emerald-500" style={"width: #{round(r.rate * 100)}%"}></div>
              </div>
            </li>
          </ul>
        </.section>

        <.section title="Native code">
          <.empty :if={@native == []}>No packages yet.</.empty>
          <ul :if={@native != []} class="divide-y divide-base-200">
            <li :for={n <- @native} class="flex items-center justify-between py-3">
              <span class="font-medium text-base-content">{n.language}</span>
              <span class="font-mono text-sm text-base-content/60">{n.packages} pkg</span>
            </li>
          </ul>
        </.section>

        <div class="grid gap-6 sm:grid-cols-2">
          <.section title="Recently checked passing">
            <.empty :if={@recent_pass == []}>Nothing yet.</.empty>
            <.recent_list :if={@recent_pass != []} rows={@recent_pass} status="pass" />
          </.section>
          <.section title="Recently checked failing">
            <.empty :if={@recent_fail == []}>Nothing yet.</.empty>
            <.recent_list :if={@recent_fail != []} rows={@recent_fail} status="fail" />
          </.section>
        </div>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  slot :inner_block, required: true

  defp section(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
      <h2 class="mb-4 text-sm font-semibold uppercase tracking-wider text-base-content/60">{@title}</h2>
      {render_slot(@inner_block)}
    </div>
    """
  end

  slot :inner_block, required: true

  defp empty(assigns) do
    ~H"""
    <p class="text-sm text-base-content/50">{render_slot(@inner_block)}</p>
    """
  end

  attr :rows, :list, required: true
  attr :status, :string, required: true

  defp recent_list(assigns) do
    ~H"""
    <ul class="divide-y divide-base-200">
      <li :for={row <- @rows} class="flex items-center justify-between py-3">
        <a href={~p"/packages/#{row.package}"} class="font-medium text-base-content hover:text-primary">
          {row.package} <span class="font-mono text-xs text-base-content/50">v{row.version}</span>
        </a>
        <PortalWeb.UI.status_badge status={@status} />
      </li>
    </ul>
    """
  end
end
```

- [ ] **Step 6: Update nav, active states, and back-links**

- `site_nav.ex`: change the Packages nav link from `href="/"` to `href="/packages"` (leave Dashboard on `href="/"`). Keep `active` atoms `:home` (Dashboard) and `:packages` (Packages).
- `index_live.ex`: keep `active={:packages}` in its `Layouts.app` (already set).
- `package_live.ex`: change the back link `href={~p"/"}` ("← Packages" / "All packages") to `href={~p"/packages"}`, and the not-found `push_navigate(to: ~p"/")` to `push_navigate(to: ~p"/packages")`.
- `request_live.ex`: change the back link `href={~p"/"}` to `href={~p"/packages"}`.

- [ ] **Step 7: Run the dashboard + index tests**

Run (from repo root): `mix test apps/portal/test/portal_web/dashboard_live_test.exs apps/portal/test/portal_web/catalog_live_test.exs`
Expected: PASS — dashboard renders 5 headings + seeded cluster/package; the moved browser test passes at `/packages`.

- [ ] **Step 8: Commit**

```bash
git add apps/portal/lib/portal_web/live/dashboard_live.ex apps/portal/lib/portal_web/router.ex apps/portal/lib/portal_web/live/index_live.ex apps/portal/lib/portal_web/live/package_live.ex apps/portal/lib/portal_web/live/request_live.ex apps/portal/lib/portal_web/components/site_nav.ex apps/portal/test/portal_web/dashboard_live_test.exs apps/portal/test/portal_web/catalog_live_test.exs
git commit -m "feat(portal): Dashboard at / with 5 sections; move package browser to /packages"
```

---

### Task 6: mix portal.reclassify task

**Files:**
- Create: `apps/portal/lib/mix/tasks/portal.reclassify.ex`
- Test: `apps/portal/test/mix/tasks/portal_reclassify_test.exs`

**Interfaces:**
- Consumes: `FailureClassifier.classify/1`; `SystemResult` `:update` action accepting `:failure_category`.
- Produces: `mix portal.reclassify` re-derives `failure_category` for every `SystemResult` that has a stored `log_tail`. Idempotent.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/mix/tasks/portal_reclassify_test.exs
defmodule Mix.Tasks.Portal.ReclassifyTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.{Package, Run, SystemResult}

  test "reclassify sets failure_category from stored log_tail" do
    {:ok, pkg} = Package |> Ash.Changeset.for_create(:create, %{name: "recl"}) |> Ash.create(domain: Catalog)

    {:ok, run} =
      Run
      |> Ash.Changeset.for_create(:create, %{run_id: "recl-1", package_id: pkg.id, version_tested: "1.0.0", image_digest: "sha256:x", overall_status: :fail})
      |> Ash.create(domain: Catalog)

    {:ok, sr} =
      SystemResult
      |> Ash.Changeset.for_create(:create, %{run_id: run.id, system_pkg: "nerves_system_rpi0", status: :fail, log_tail: "Exec format error", failure_category: nil})
      |> Ash.create(domain: Catalog)

    assert sr.failure_category == nil

    Mix.Tasks.Portal.Reclassify.run([])

    updated = SystemResult |> Ash.get!(sr.id, domain: Catalog)
    assert updated.failure_category == "NIF built for wrong architecture"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/mix/tasks/portal_reclassify_test.exs`
Expected: FAIL — task module undefined.

- [ ] **Step 3: Implement the task**

```elixir
# apps/portal/lib/mix/tasks/portal.reclassify.ex
defmodule Mix.Tasks.Portal.Reclassify do
  @shortdoc "Re-derive failure_category for stored system results from their log_tail"
  @moduledoc @shortdoc
  use Mix.Task

  alias Portal.Catalog
  alias Portal.Catalog.{FailureClassifier, SystemResult}

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")

    results = Ash.read!(SystemResult, domain: Catalog)

    counts =
      Enum.reduce(results, %{}, fn sr, acc ->
        category =
          FailureClassifier.classify(%{
            "status" => to_string(sr.status),
            "log_tail" => sr.log_tail
          })

        if category != sr.failure_category do
          sr
          |> Ash.Changeset.for_update(:update, %{failure_category: category})
          |> Ash.update!(domain: Catalog)
        end

        Map.update(acc, category || "pass/skipped", 1, &(&1 + 1))
      end)

    Mix.shell().info("Reclassified #{length(results)} system results:")
    Enum.each(counts, fn {cat, n} -> Mix.shell().info("  #{cat}: #{n}") end)
  end
end
```

- [ ] **Step 4: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/mix/tasks/portal_reclassify_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/mix/tasks/portal.reclassify.ex apps/portal/test/mix/tasks/portal_reclassify_test.exs
git commit -m "feat(portal): mix portal.reclassify task"
```

---

### Task 7: Full verification

- [ ] **Step 1: Umbrella test suite**

Run (from repo root): `mix test`
Expected: PASS (compatibility + ncc_worker + portal), integration excluded.

- [ ] **Step 2: Warnings-as-errors + format**

Run (from repo root): `mix compile --warnings-as-errors` and `mix format --check-formatted apps/portal/lib/portal/catalog/failure_classifier.ex apps/portal/lib/portal/catalog.ex apps/portal/lib/portal/catalog/ingestion.ex apps/portal/lib/portal_web/live/dashboard_live.ex apps/portal/lib/mix/tasks/portal.reclassify.ex`
Expected: clean.

- [ ] **Step 3: Manual check (light + dark)**

Run `mix phx.server` (pick a free port, e.g. `PORT=4040`). Seed a couple runs (build jason + a failing package, or reuse the earlier seed script). Visit `/` — all five sections render with data; `/packages` still shows the browser with search; nav toggles Dashboard/Packages active states; back-links from a package go to `/packages`. Toggle theme — sections legible in light and dark.

- [ ] **Step 4: Final commit if formatting changed**

```bash
git add -u apps/portal
git commit -m "chore(portal): dashboard finalize" || echo "nothing to finalize"
```

---

## Self-Review

**Spec coverage:**
- Schema (failure_category, log_tail, native_components) → Task 1. ✓
- FailureClassifier (5 categories, ordered, nil for pass/skipped) → Task 2. ✓
- Ingestion wiring (classify + log_tail + native_components) → Task 3. ✓
- Catalog queries (pass_rate_per_system, recent_runs, failure_clusters, native_breakdown) → Task 4. ✓
- DashboardLive at / + move browser to /packages + nav + links → Task 5. ✓
- mix portal.reclassify → Task 6. ✓
- Verification (precommit, light/dark) → Task 7. ✓
- Non-goals respected: no worker/Docker/API/badge/Oban edits in any task. ✓

**Placeholder scan:** One deliberate conditional note in Task 3/4 ("if the private helper names differ, grep for the ones `latest_by_pkg_json` uses") — this is a concrete fallback naming the exact anchor function, not a vague TODO. Acceptable.

**Type consistency:** `classify/1` takes a map with string keys everywhere (ingestion, reclassify, tests). `failure_clusters` returns `%{category, systems, packages}` consumed by DashboardLive as `c.category/c.systems/c.packages`. `recent_runs` returns `%{package, version, finished_at, overall_status}` consumed as `row.package/row.version`. `pass_rate_per_system` returns `%{system_pkg, pass, total, rate}` consumed as `r.system_pkg/r.pass/r.total/r.rate`. `native_breakdown` returns `%{language, packages}` consumed as `n.language/n.packages`. Consistent. ✓
