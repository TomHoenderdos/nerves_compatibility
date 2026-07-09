# Static-Site Port Phase 1a Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-implement the prod static site's shell + Dashboard, Failure clusters, and Stats pages in the dynamic Phoenix app (Tailwind, prod structure), backed by existing Catalog data plus ported pure helpers and one query extension. Add a Warnings nav stub.

**Architecture:** A pure `Portal.Catalog.Rollup` + `Portal.Catalog.Architecture` provide package-level overall status, native-code bucket, and arch labels. `Catalog` gains `package_status_counts/0` and a richer `failure_clusters/1`. Three new LiveViews (`FailureClustersLive`, `StatsLive`, `WarningsLive` stub) and a rebuilt `DashboardLive` render prod's structure with Tailwind. Routes + `SiteNav` gain the three pages.

**Tech Stack:** Phoenix 1.8 LiveView, Ash, Tailwind/daisyUI, existing `PortalWeb.UI` Beacon components.

## Global Constraints

- All work under `apps/portal/`. Run `mix` from the **repo root**.
- Tailwind only (no raw-CSS adoption, no removal of Tailwind/daisyUI). Match prod's *structure* (sections, cards, tables, column order), not its exact CSS.
- Reuse existing Catalog queries: `stats_json/0`, `pass_rate_per_system/0`, `native_breakdown/0`, `recent_runs/2`. Extend `failure_clusters/1` and `latest_annotated_systems/0`. Add `package_status_counts/0`. No worker/`result.json`, JSON API, badge, or Oban changes. No new ingested fields.
- Ported pure functions come from git ref `e162454` (`git show e162454:site/lib/site/<file>.ex`) — recover exact bodies where this plan says "verbatim".
- COMMIT POLICY (user-approved): commit related files wholesale; the branch has unrelated pre-existing WIP (app.css, deleted `orchestrator/`) that must NOT be swept. Stage each task's explicit file list; NEVER `git add -A`/`.`/`commit -a`. After each commit run `git show --stat HEAD` and confirm only intended files.
- `mix precommit` + umbrella `mix test` green at the end.

## Failure category → title/hint map (used in Task 2)

Our ingestion `failure_category` values map to display title/hint (hint wording adapted from the old `Site.FailureCluster`):

| failure_category (our value) | title | hint |
| --- | --- | --- |
| `"NIF built for wrong architecture"` | `NIF built for wrong architecture` | `A dependency's NIF was compiled for the host, not the Nerves target — the scrub-otp step rejects it at firmware-build time. Usually fixable by forcing a clean rebuild of the dep for the target.` |
| `"Precompiled NIF missing for target"` | `Precompiled NIF missing for this target` | `The package ships a precompiled NIF but no build exists for the Nerves target triple. The package vendor would need to add the triple to their release.` |
| `"Dependency resolution failed"` | `Dependency resolution failed` | `A dependency could not be resolved or fetched. Often a version skew or a git/path dep that Hex can't satisfy.` |
| `"Compilation error"` | `Compilation error` | `The package's own source failed to compile — often a syntax issue triggered by a newer Elixir, or a missing macro dependency.` |
| `"Other / unclassified"` | `Other / unclassified` | `Build failures that don't match a known pattern. See the representative log for the specific cause.` |

---

### Task 1: Rollup + Architecture pure helpers

**Files:**
- Create: `apps/portal/lib/portal/catalog/architecture.ex`
- Create: `apps/portal/lib/portal/catalog/rollup.ex`
- Test: `apps/portal/test/portal/catalog/rollup_test.exs`

**Interfaces:**
- Produces:
  - `Portal.Catalog.Architecture.label(system :: String.t()|atom()|nil) :: String.t()`
  - `Portal.Catalog.Rollup.overall_status(statuses :: [atom()|String.t()]) :: :pass | :fail | :partial | :skipped | :unknown`
  - `Portal.Catalog.Rollup.native_bucket(nif_language :: String.t()|nil, port_languages :: [String.t()], any_scanned? :: boolean) :: String.t()`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/rollup_test.exs
defmodule Portal.Catalog.RollupTest do
  use ExUnit.Case, async: true

  alias Portal.Catalog.{Architecture, Rollup}

  test "architecture label maps known systems and strips prefix otherwise" do
    assert Architecture.label("nerves_system_rpi4") == "arm64"
    assert Architecture.label("nerves_system_x86_64") == "x86_64"
    assert Architecture.label("host") == "host"
    assert Architecture.label("nerves_system_grisp2") == "arm32"
    assert Architecture.label("nerves_system_newthing") == "newthing"
    assert Architecture.label("forced@x") == "forced"
    assert Architecture.label(nil) == ""
  end

  test "overall_status rolls per-system statuses to a package bucket" do
    assert Rollup.overall_status(["pass", "pass"]) == :pass
    assert Rollup.overall_status(["pass", "fail"]) == :fail
    assert Rollup.overall_status(["pass", "error"]) == :fail
    assert Rollup.overall_status(["pass", "skipped"]) == :partial
    assert Rollup.overall_status(["skipped", "skipped"]) == :skipped
    assert Rollup.overall_status([]) == :unknown
    assert Rollup.overall_status([:pass, :fail]) == :fail
  end

  test "native_bucket classifies language / none / not scanned" do
    assert Rollup.native_bucket("rust", [], true) == "rust"
    assert Rollup.native_bucket(nil, ["c"], true) == "c"
    assert Rollup.native_bucket(nil, [], true) == "none"
    assert Rollup.native_bucket(nil, [], false) == "not scanned"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/rollup_test.exs`
Expected: FAIL — modules undefined.

- [ ] **Step 3: Port Architecture verbatim**

Recover the exact module and rename it: `git show e162454:site/lib/site/architecture.ex` — copy the `@system_to_arch` map and `label/1` clauses verbatim into:

```elixir
# apps/portal/lib/portal/catalog/architecture.ex
defmodule Portal.Catalog.Architecture do
  @moduledoc "Maps Nerves system package names to CPU-architecture labels."

  @system_to_arch %{
    "nerves_system_rpi" => "arm32",
    "nerves_system_rpi0" => "arm32",
    "nerves_system_rpi0_2" => "arm64",
    "nerves_system_rpi2" => "arm32",
    "nerves_system_rpi3" => "arm32",
    "nerves_system_rpi3a" => "arm32",
    "nerves_system_rpi4" => "arm64",
    "nerves_system_rpi5" => "arm64",
    "nerves_system_qemu_aarch64" => "arm64",
    "nerves_system_mangopi_mq_pro" => "riscv64",
    "nerves_system_grisp2" => "arm32",
    "nerves_system_x86_64" => "x86_64",
    "nerves_system_bbb" => "arm32",
    "nerves_system_osd32mp1" => "arm32",
    "host" => "host"
  }

  @spec label(String.t() | atom() | nil) :: String.t()
  def label(nil), do: ""
  def label(system) when is_atom(system), do: label(Atom.to_string(system))

  def label(system) when is_binary(system) do
    case Map.fetch(@system_to_arch, system) do
      {:ok, arch} ->
        arch

      :error ->
        if String.starts_with?(system, "forced"),
          do: "forced",
          else: String.replace_prefix(system, "nerves_system_", "")
    end
  end
end
```

- [ ] **Step 4: Write Rollup**

```elixir
# apps/portal/lib/portal/catalog/rollup.ex
defmodule Portal.Catalog.Rollup do
  @moduledoc "Pure package-level rollups over per-system results."

  @doc "Roll a list of per-system statuses into one package-level bucket."
  @spec overall_status([atom() | String.t()]) :: :pass | :fail | :partial | :skipped | :unknown
  def overall_status([]), do: :unknown

  def overall_status(statuses) do
    s = Enum.map(statuses, &to_string/1)

    cond do
      Enum.any?(s, &(&1 in ["fail", "error"])) -> :fail
      Enum.all?(s, &(&1 == "pass")) -> :pass
      Enum.all?(s, &(&1 == "skipped")) -> :skipped
      Enum.any?(s, &(&1 == "pass")) -> :partial
      true -> :unknown
    end
  end

  @doc "Classify a package's native-code bucket."
  @spec native_bucket(String.t() | nil, [String.t()], boolean()) :: String.t()
  def native_bucket(_nif, _ports, false), do: "not scanned"
  def native_bucket(nif, _ports, true) when is_binary(nif) and nif != "", do: nif

  def native_bucket(_nif, ports, true) do
    case Enum.reject(ports || [], &(is_nil(&1) or &1 == "")) do
      [lang | _] -> lang
      [] -> "none"
    end
  end
end
```

- [ ] **Step 5: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/rollup_test.exs`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal/catalog/architecture.ex apps/portal/lib/portal/catalog/rollup.ex apps/portal/test/portal/catalog/rollup_test.exs
git commit -m "feat(portal): port Architecture labels + package-level Rollup helpers"
```

---

### Task 2: package_status_counts/0 + richer failure_clusters/1

**Files:**
- Modify: `apps/portal/lib/portal/catalog.ex` (extend `latest_annotated_systems/0`; add `package_status_counts/0`; extend `failure_clusters/1`)
- Test: `apps/portal/test/portal/catalog/phase1a_queries_test.exs`

**Interfaces:**
- Consumes: `Portal.Catalog.{Rollup, Architecture}`; existing private `latest_annotated_systems/0`.
- Produces:
  - `Catalog.package_status_counts() :: %{unique: n, pass: n, fail: n, partial: n, skipped: n, unknown: n}`
  - `Catalog.failure_clusters(limit) :: [%{category, title, hint, systems, packages, entries: [%{package, version, arch_label, nif_language, detail}], sample_log: String.t()|nil}]`

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal/catalog/phase1a_queries_test.exs
defmodule Portal.Catalog.Phase1aQueriesTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  defp ingest(name, version, systems, native \\ nil) do
    dir = Path.join(System.tmp_dir!(), "p1a-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    result = %{
      "package" => %{"name" => name, "version" => version, "native_components" => native},
      "finished_at" => "2026-07-06T10:00:00Z",
      "systems" => systems
    }

    {:ok, _} = Ingestion.ingest(result, %{run_id: "#{name}-#{version}", image_digest: "sha256:x", files_dir: dir, log: "l"})
  end

  test "package_status_counts buckets one row per package" do
    ingest("allpass", "1.0.0", %{"nerves_system_rpi0" => %{"status" => "pass"}, "host" => %{"status" => "pass"}})
    ingest("hasfail", "1.0.0", %{"nerves_system_rpi0" => %{"status" => "fail", "log_tail" => "Exec format error"}, "host" => %{"status" => "pass"}})

    counts = Catalog.package_status_counts()
    assert counts.unique == 2
    assert counts.pass == 1
    assert counts.fail == 1
  end

  test "failure_clusters returns title, entries, and a sample log" do
    ingest("clusterpkg", "2.0.0", %{"nerves_system_rpi4" => %{"status" => "fail", "log_tail" => "sh: cannot execute binary file: Exec format error"}})

    [cluster | _] = Catalog.failure_clusters(10)
    assert cluster.category == "NIF built for wrong architecture"
    assert cluster.title == "NIF built for wrong architecture"
    assert cluster.hint =~ "host"
    assert Enum.any?(cluster.entries, &(&1.package == "clusterpkg" and &1.arch_label == "arm64"))
    assert cluster.sample_log =~ "Exec format error"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal/catalog/phase1a_queries_test.exs`
Expected: FAIL — `package_status_counts/0` undefined; `failure_clusters/1` lacks `title`/`entries`/`sample_log`.

- [ ] **Step 3: Extend `latest_annotated_systems/0`**

In `catalog.ex`, extend the map each annotated row carries to include the fields the cluster page needs. Find `latest_annotated_systems/0` and change its final `Enum.map` so each row is:

```elixir
      %{
        package: Map.get(run_to_pkg, sr.run_id),
        system_pkg: sr.system_pkg,
        status: sr.status,
        failure_category: sr.failure_category,
        log_tail: sr.log_tail,
        version: sr.hex_version_tested,
        nif_language: nil
      }
```

(If joining `nif_language` from `Package.native_components` is cheap here, set it; otherwise leave `nil` — the cluster entries will show `nil` gracefully. Keep it `nil` for this task to avoid an extra join; a later phase can enrich.)

- [ ] **Step 4: Add `package_status_counts/0` and the title/hint map + rewrite `failure_clusters/1`**

Add to `catalog.ex`:

```elixir
  @failure_meta %{
    "NIF built for wrong architecture" =>
      {"NIF built for wrong architecture",
       "A dependency's NIF was compiled for the host, not the Nerves target — the scrub-otp step rejects it at firmware-build time. Usually fixable by forcing a clean rebuild of the dep for the target."},
    "Precompiled NIF missing for target" =>
      {"Precompiled NIF missing for this target",
       "The package ships a precompiled NIF but no build exists for the Nerves target triple. The package vendor would need to add the triple to their release."},
    "Dependency resolution failed" =>
      {"Dependency resolution failed",
       "A dependency could not be resolved or fetched. Often a version skew or a git/path dep that Hex can't satisfy."},
    "Compilation error" =>
      {"Compilation error",
       "The package's own source failed to compile — often a syntax issue triggered by a newer Elixir, or a missing macro dependency."},
    "Other / unclassified" =>
      {"Other / unclassified",
       "Build failures that don't match a known pattern. See the representative log for the specific cause."}
  }

  @doc "One bucket per package via Rollup.overall_status over its latest run's systems."
  def package_status_counts do
    by_pkg =
      latest_annotated_systems()
      |> Enum.group_by(& &1.package)
      |> Enum.map(fn {_pkg, rows} ->
        Portal.Catalog.Rollup.overall_status(Enum.map(rows, & &1.status))
      end)

    %{
      unique: length(by_pkg),
      pass: Enum.count(by_pkg, &(&1 == :pass)),
      fail: Enum.count(by_pkg, &(&1 == :fail)),
      partial: Enum.count(by_pkg, &(&1 == :partial)),
      skipped: Enum.count(by_pkg, &(&1 == :skipped)),
      unknown: Enum.count(by_pkg, &(&1 == :unknown))
    }
  end
```

Replace the existing `failure_clusters/1` body with:

```elixir
  def failure_clusters(limit \\ 10) do
    latest_annotated_systems()
    |> Enum.filter(&(&1.status in [:fail, :error] and not is_nil(&1.failure_category)))
    |> Enum.group_by(& &1.failure_category)
    |> Enum.map(fn {category, rows} ->
      {title, hint} = Map.get(@failure_meta, category, {category, "Build failures in this category."})

      entries =
        Enum.map(rows, fn r ->
          %{
            package: r.package,
            version: r.version,
            arch_label: Portal.Catalog.Architecture.label(r.system_pkg),
            nif_language: r.nif_language,
            detail: nil
          }
        end)

      %{
        category: category,
        title: title,
        hint: hint,
        systems: length(rows),
        packages: rows |> Enum.map(& &1.package) |> Enum.uniq() |> length(),
        entries: entries,
        sample_log: sample_log(rows)
      }
    end)
    |> Enum.sort_by(& &1.systems, :desc)
    |> Enum.take(limit)
  end

  # Shortest non-empty log_tail in the cluster, last 40 lines.
  defp sample_log(rows) do
    rows
    |> Enum.map(& &1.log_tail)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    |> Enum.min_by(&String.length/1, fn -> nil end)
    |> case do
      nil -> nil
      log -> log |> String.split("\n") |> Enum.take(-40) |> Enum.join("\n")
    end
  end
```

- [ ] **Step 5: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal/catalog/phase1a_queries_test.exs`
Expected: PASS.

- [ ] **Step 6: Run existing catalog + dashboard tests (failure_clusters shape changed)**

Run (from repo root): `mix test apps/portal/test/portal/catalog apps/portal/test/portal_web/dashboard_live_test.exs`
Expected: PASS — if `dashboard_live_test` asserted the old `failure_clusters` shape via the page, it still renders (the page reads `.category`/`.systems`/`.packages`, all still present). If any assertion breaks on the added keys, it is a test-only fix; note it for Task 4 where the dashboard is rebuilt.

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal/catalog.ex apps/portal/test/portal/catalog/phase1a_queries_test.exs
git commit -m "feat(portal): package_status_counts + richer failure_clusters (title/hint/entries/sample log)"
```

---

### Task 3: Routes + nav + Warnings stub

**Files:**
- Modify: `apps/portal/lib/portal_web/router.ex` (add 3 live routes in `:public` live_session)
- Modify: `apps/portal/lib/portal_web/components/site_nav.ex` (add Failure clusters / Warnings / Stats links)
- Create: `apps/portal/lib/portal_web/live/warnings_live.ex` (stub)
- Test: `apps/portal/test/portal_web/nav_and_stub_test.exs`

**Interfaces:**
- Produces: routes `/failure_clusters` → `FailureClustersLive`, `/stats` → `StatsLive`, `/warnings` → `WarningsLive`; nav links with active atoms `:clusters`, `:warnings`, `:stats`.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/nav_and_stub_test.exs
defmodule PortalWeb.NavAndStubTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "warnings stub renders", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/warnings")
    assert html =~ "Warnings"
    assert html =~ "coming soon"
  end

  test "nav shows the five section links", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/warnings")
    assert html =~ ~s(href="/failure_clusters")
    assert html =~ ~s(href="/stats")
    assert html =~ ~s(href="/warnings")
    assert html =~ ~s(href="/packages")
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/nav_and_stub_test.exs`
Expected: FAIL — no `/warnings` route / `WarningsLive`.

- [ ] **Step 3: Add the routes**

In `router.ex`, inside `live_session :public, on_mount: [...] do ... end`, add:

```elixir
      live "/failure_clusters", FailureClustersLive, :index
      live "/warnings", WarningsLive, :index
      live "/stats", StatsLive, :index
```

- [ ] **Step 4: Add the nav links**

In `site_nav.ex`, after the Packages link, add (matching the existing `<.nav_link>` style):

```elixir
          <.nav_link href="/failure_clusters" active={@active == :clusters}>Failure clusters</.nav_link>
          <.nav_link href="/warnings" active={@active == :warnings}>Warnings</.nav_link>
          <.nav_link href="/stats" active={@active == :stats}>Stats</.nav_link>
```

(Keep the existing Request scan + admin/oban links.)

- [ ] **Step 5: Create the Warnings stub**

```elixir
# apps/portal/lib/portal_web/live/warnings_live.ex
defmodule PortalWeb.WarningsLive do
  use PortalWeb, :live_view

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:warnings} current_user={@current_user}>
      <section class="space-y-4">
        <PortalWeb.UI.page_header kicker="Warnings" title="Build warnings">
          <:subtitle>Heuristic warnings about package build behavior.</:subtitle>
        </PortalWeb.UI.page_header>
        <div class="rounded-2xl border border-base-300 bg-base-100 p-8 text-center text-base-content/60">
          Warnings analysis coming soon.
        </div>
      </section>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run (from repo root): `mix test apps/portal/test/portal_web/nav_and_stub_test.exs`
Expected: PASS. (Routes for FailureClustersLive/StatsLive are declared but those modules don't exist yet — this compiles because the router references them; if compilation fails on undefined modules, do Tasks 4-6's module creation before running the suite. To keep this task self-contained, add minimal placeholder modules for `FailureClustersLive`/`StatsLive` that render `Layouts.app` with just a `page_header`, to be fleshed out in Tasks 5-6.)

- [ ] **Step 7: Commit**

```bash
git add apps/portal/lib/portal_web/router.ex apps/portal/lib/portal_web/components/site_nav.ex apps/portal/lib/portal_web/live/warnings_live.ex apps/portal/test/portal_web/nav_and_stub_test.exs
git commit -m "feat(portal): routes + nav for failure-clusters/warnings/stats; warnings stub"
```

Note: if placeholder `FailureClustersLive`/`StatsLive` modules were needed to compile, create them in this commit too (minimal `page_header`-only render) and include their paths in `git add`.

---

### Task 4: Rebuild DashboardLive (prod structure)

**Files:**
- Modify: `apps/portal/lib/portal_web/live/dashboard_live.ex`
- Modify: `apps/portal/test/portal_web/dashboard_live_test.exs` (update to new structure)

**Interfaces:**
- Consumes: `Catalog.{package_status_counts, failure_clusters, native_breakdown, pass_rate_per_system, recent_runs, stats_json}`.

- [ ] **Step 1: Update the dashboard test to the prod structure**

Replace the heading assertions in `dashboard_live_test.exs` so the "renders sections" test asserts the prod-structure text:

```elixir
  test "dashboard renders summary + tiles + recent lists", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Unique Packages"
    assert html =~ "Passing"
    assert html =~ "Failing"
    assert html =~ "Top failure clusters"
    assert html =~ "Native code"
    assert html =~ "Pass rate per system"
    assert html =~ "Recently checked passing"
    assert html =~ "Recently checked failing"
  end
```

(Keep the second test — the one seeding a failing package and asserting the cluster title + package name appear — but update its cluster assertion to the new title `"NIF built for wrong architecture"` if needed.)

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/dashboard_live_test.exs`
Expected: FAIL — old dashboard lacks "Unique Packages" summary etc.

- [ ] **Step 3: Rebuild `DashboardLive`**

Replace `dashboard_live.ex` with the prod-structure dashboard. `mount/3` loads the data; `render/1` renders Summary cards + a tile grid + two recent lists + footer. Full code:

```elixir
defmodule PortalWeb.DashboardLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    counts = Catalog.package_status_counts()
    stats = Catalog.stats_json()

    {:ok,
     socket
     |> assign(:counts, counts)
     |> assign(:clusters, Catalog.failure_clusters(3))
     |> assign(:native, Catalog.native_breakdown())
     |> assign(:rates, Catalog.pass_rate_per_system())
     |> assign(:recent_pass, Catalog.recent_runs(:pass, 10))
     |> assign(:recent_fail, Catalog.recent_runs(:fail, 10))
     |> assign(:last_run, stats[:last_run_finished_at])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:home} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Dashboard" title="Nerves Compatibility">
          <:subtitle>Compatibility results generated automatically across Nerves systems.</:subtitle>
        </PortalWeb.UI.page_header>

        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <PortalWeb.UI.stat_card label="Unique Packages" value={to_string(@counts.unique)} />
          <PortalWeb.UI.stat_card label="Passing" value={to_string(@counts.pass)} accent="pass" />
          <a href={~p"/packages"} class="block">
            <PortalWeb.UI.stat_card label="Failing" value={to_string(@counts.fail)} />
          </a>
        </div>

        <div class="grid grid-cols-1 gap-4 lg:grid-cols-3">
          <.tile :if={@clusters != []} title="Top failure clusters" href={~p"/failure_clusters"}>
            <ul class="space-y-2">
              <li :for={c <- @clusters} class="flex items-center justify-between text-sm">
                <span class="truncate text-base-content">{c.title}</span>
                <span class="font-mono text-base-content/50">{c.systems} / {c.packages} pkg</span>
              </li>
            </ul>
          </.tile>

          <.tile :if={@native != []} title="Native code">
            <ul class="space-y-2">
              <li :for={n <- @native} class="flex items-center justify-between text-sm">
                <span class="text-base-content">{n.language}</span>
                <span class="font-mono text-base-content/50">{n.packages}</span>
              </li>
            </ul>
          </.tile>

          <.tile :if={@rates != []} title="Pass rate per system">
            <ul class="space-y-2">
              <li :for={r <- @rates} class="space-y-1">
                <div class="flex justify-between text-xs">
                  <span class="font-mono text-base-content">{r.system_pkg}</span>
                  <span class="text-base-content/50">{r.pass}/{r.total} · {round(r.rate * 100)}%</span>
                </div>
                <div class="h-1.5 w-full overflow-hidden rounded-full bg-base-200">
                  <div class="h-full rounded-full bg-emerald-400 dark:bg-emerald-500" style={"width: #{round(r.rate * 100)}%"}></div>
                </div>
              </li>
            </ul>
          </.tile>
        </div>

        <div class="grid grid-cols-1 gap-6 sm:grid-cols-2">
          <.recent title="Recently checked passing" rows={@recent_pass} status="pass" />
          <.recent title="Recently checked failing" rows={@recent_fail} status="fail" />
        </div>

        <p class="text-xs text-base-content/40">Last test run: {@last_run || "n/a"}</p>
      </section>
    </Layouts.app>
    """
  end

  attr :title, :string, required: true
  attr :href, :string, default: nil
  slot :inner_block, required: true

  defp tile(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <div class="mb-3 flex items-center justify-between">
        <h2 class="text-sm font-semibold uppercase tracking-wider text-base-content/60">{@title}</h2>
        <a :if={@href} href={@href} class="text-xs font-medium text-primary hover:underline">see all →</a>
      </div>
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :title, :string, required: true
  attr :rows, :list, required: true
  attr :status, :string, required: true

  defp recent(assigns) do
    ~H"""
    <div class="rounded-2xl border border-base-300 bg-base-100 p-5 shadow-sm">
      <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">{@title}</h2>
      <p :if={@rows == []} class="text-sm text-base-content/50">Nothing yet.</p>
      <ul :if={@rows != []} class="divide-y divide-base-200">
        <li :for={row <- @rows} class="flex items-center justify-between py-2">
          <a href={~p"/packages/#{row.package}"} class="font-medium text-base-content hover:text-primary">
            {row.package} <span class="font-mono text-xs text-base-content/50">v{row.version}</span>
          </a>
          <PortalWeb.UI.status_badge status={to_string(row.overall_status)} />
        </li>
      </ul>
    </div>
    """
  end
end
```

- [ ] **Step 4: Run the dashboard test**

Run (from repo root): `mix test apps/portal/test/portal_web/dashboard_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/live/dashboard_live.ex apps/portal/test/portal_web/dashboard_live_test.exs
git commit -m "feat(portal): rebuild Dashboard in prod structure (summary + tiles + recent lists)"
```

---

### Task 5: FailureClustersLive

**Files:**
- Create (or replace placeholder): `apps/portal/lib/portal_web/live/failure_clusters_live.ex`
- Test: `apps/portal/test/portal_web/failure_clusters_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.failure_clusters/1` (extended shape from Task 2).

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/failure_clusters_live_test.exs
defmodule PortalWeb.FailureClustersLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "empty state with no failures", %{conn: conn} do
    {:ok, _v, html} = live(conn, ~p"/failure_clusters")
    assert html =~ "Failure clusters"
    assert html =~ "No failure clusters"
  end

  test "renders a cluster card with affected package and sample log", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "fc-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "fcpkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "fail", "log_tail" => "cannot execute binary file: Exec format error"}}
        },
        %{run_id: "fcpkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _v, html} = live(conn, ~p"/failure_clusters")
    assert html =~ "NIF built for wrong architecture"
    assert html =~ "fcpkg"
    assert html =~ "Exec format error"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/failure_clusters_live_test.exs`
Expected: FAIL — placeholder page lacks the content.

- [ ] **Step 3: Implement `FailureClustersLive`**

```elixir
# apps/portal/lib/portal_web/live/failure_clusters_live.ex
defmodule PortalWeb.FailureClustersLive do
  use PortalWeb, :live_view

  alias Portal.Catalog

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, :clusters, Catalog.failure_clusters(50))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:clusters} current_user={@current_user}>
      <section class="space-y-6">
        <PortalWeb.UI.page_header kicker="Diagnostics" title="Failure clusters">
          <:subtitle>Failing builds grouped by likely root cause.</:subtitle>
        </PortalWeb.UI.page_header>

        <p :if={@clusters == []} class="rounded-2xl border border-base-300 bg-base-100 p-8 text-center text-base-content/60">
          No failure clusters — everything is passing.
        </p>

        <div :for={c <- @clusters} class="rounded-2xl border border-base-300 bg-base-100 p-6 shadow-sm">
          <div class="flex flex-col gap-1 sm:flex-row sm:items-center sm:justify-between">
            <h2 class="text-lg font-semibold text-base-content">{c.title}</h2>
            <span class="font-mono text-sm text-base-content/50">{c.systems} failures · {c.packages} package(s)</span>
          </div>
          <p class="mt-2 text-sm leading-6 text-base-content/70">{c.hint}</p>

          <details class="mt-4">
            <summary class="cursor-pointer text-sm font-medium text-primary">Show {length(c.entries)} affected package(s)</summary>
            <ul class="mt-3 grid gap-2 sm:grid-cols-2">
              <li :for={e <- c.entries} class="text-sm">
                <a href={~p"/packages/#{e.package}"} class="font-medium text-base-content hover:text-primary">
                  {e.package}<span :if={e.version} class="font-mono text-xs text-base-content/50">@{e.version}</span>
                </a>
                <span class="text-base-content/50">· {e.arch_label}</span>
              </li>
            </ul>
          </details>

          <div :if={c.sample_log} class="mt-4">
            <div class="mb-1 text-xs font-semibold uppercase tracking-wider text-base-content/50">Representative log</div>
            <pre class="overflow-auto rounded-xl border border-base-300 bg-base-300/30 p-4 font-mono text-xs leading-relaxed text-base-content/80">{c.sample_log}</pre>
          </div>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
```

- [ ] **Step 4: Run the test**

Run (from repo root): `mix test apps/portal/test/portal_web/failure_clusters_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/live/failure_clusters_live.ex apps/portal/test/portal_web/failure_clusters_live_test.exs
git commit -m "feat(portal): Failure clusters page"
```

---

### Task 6: StatsLive

**Files:**
- Create (or replace placeholder): `apps/portal/lib/portal_web/live/stats_live.ex`
- Test: `apps/portal/test/portal_web/stats_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.package_status_counts/0`, `Catalog.stats_json/0`, `Portal.Catalog.Architecture.label/1`.

- [ ] **Step 1: Write the failing test**

```elixir
# apps/portal/test/portal_web/stats_live_test.exs
defmodule PortalWeb.StatsLiveTest do
  use PortalWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Portal.Catalog.Ingestion

  test "stats renders overall + per-system rows", %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "st-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, _} =
      Ingestion.ingest(
        %{
          "package" => %{"name" => "statpkg", "version" => "1.0.0"},
          "finished_at" => "2026-07-06T10:00:00Z",
          "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
        },
        %{run_id: "statpkg-1", image_digest: "sha256:x", files_dir: dir, log: "l"}
      )

    {:ok, _v, html} = live(conn, ~p"/stats")
    assert html =~ "Overall Statistics"
    assert html =~ "Statistics by System"
    assert html =~ "arm64"
    assert html =~ "Unique Packages"
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run (from repo root): `mix test apps/portal/test/portal_web/stats_live_test.exs`
Expected: FAIL.

- [ ] **Step 3: Implement `StatsLive`**

```elixir
# apps/portal/lib/portal_web/live/stats_live.ex
defmodule PortalWeb.StatsLive do
  use PortalWeb, :live_view

  alias Portal.Catalog
  alias Portal.Catalog.Architecture

  @impl true
  def mount(_params, _session, socket) do
    stats = Catalog.stats_json()

    {:ok,
     socket
     |> assign(:counts, Catalog.package_status_counts())
     |> assign(:by_system, by_system_rows(stats))
     |> assign(:last_run, stats[:last_run_finished_at])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} active={:stats} current_user={@current_user}>
      <section class="space-y-10">
        <PortalWeb.UI.page_header kicker="Statistics" title="Statistics">
          <:subtitle>Aggregate compatibility results across the catalog.</:subtitle>
        </PortalWeb.UI.page_header>

        <div>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">Overall Statistics</h2>
          <div class="grid grid-cols-2 gap-4 sm:grid-cols-4">
            <PortalWeb.UI.stat_card label="Unique Packages" value={to_string(@counts.unique)} />
            <PortalWeb.UI.stat_card label="Passing" value={to_string(@counts.pass)} accent="pass" />
            <PortalWeb.UI.stat_card label="Failing" value={to_string(@counts.fail)} />
            <PortalWeb.UI.stat_card label="Partial" value={to_string(@counts.partial)} />
          </div>
        </div>

        <div>
          <h2 class="mb-3 text-sm font-semibold uppercase tracking-wider text-base-content/60">Statistics by System</h2>
          <div class="overflow-hidden rounded-2xl border border-base-300 bg-base-100 shadow-sm">
            <table class="w-full text-left text-sm">
              <thead class="border-b border-base-300 bg-base-200/60 text-xs uppercase tracking-wide text-base-content/60">
                <tr>
                  <th class="px-5 py-3">Architecture</th>
                  <th class="px-5 py-3">Nerves system</th>
                  <th class="px-5 py-3">Total</th>
                  <th class="px-5 py-3">Pass</th>
                  <th class="px-5 py-3">Fail</th>
                  <th class="px-5 py-3">Error</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-200">
                <tr :for={row <- @by_system} class="hover:bg-base-200/40">
                  <td class="px-5 py-3 font-medium text-base-content">{row.arch}</td>
                  <td class="px-5 py-3 font-mono text-base-content/70">{row.system}</td>
                  <td class="px-5 py-3">{row.total}</td>
                  <td class="px-5 py-3 text-emerald-600 dark:text-emerald-400">{row.pass}</td>
                  <td class="px-5 py-3 text-orange-600 dark:text-orange-400">{row.fail}</td>
                  <td class="px-5 py-3 text-red-600 dark:text-red-400">{row.error}</td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>

        <p class="text-xs text-base-content/40">Last test run: {@last_run || "n/a"}</p>
      </section>
    </Layouts.app>
    """
  end

  # stats_json().by_system is keyed "<system_pkg>@<system_version>" → counts map.
  # Drop synthetic forced@ rows; label by architecture; sort by system name.
  defp by_system_rows(stats) do
    (stats[:by_system] || %{})
    |> Enum.reject(fn {key, _} -> String.starts_with?(to_string(key), "forced") end)
    |> Enum.map(fn {key, counts} ->
      system = key |> to_string() |> String.split("@") |> hd()
      c = normalize_counts(counts)

      %{
        arch: Architecture.label(system),
        system: system,
        total: c.total,
        pass: c.pass,
        fail: c.fail,
        error: c.error
      }
    end)
    |> Enum.sort_by(& &1.system)
  end

  defp normalize_counts(counts) do
    get = fn keys -> Enum.find_value(keys, 0, &Map.get(counts, &1)) end
    pass = get.([:pass, "pass"])
    fail = get.([:fail, "fail"])
    error = get.([:error, "error"])
    skipped = get.([:skipped, "skipped"])
    %{pass: pass, fail: fail, error: error, total: pass + fail + error + skipped}
  end
end
```

(If `stats_json().by_system` counts use different keys than `:pass`/`:fail`/`:error`/`:skipped`, adjust `normalize_counts/1` — read `Catalog.stats_json/0`'s `counts/2` helper to confirm the exact keys before finalizing.)

- [ ] **Step 4: Run the test**

Run (from repo root): `mix test apps/portal/test/portal_web/stats_live_test.exs`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal_web/live/stats_live.ex apps/portal/test/portal_web/stats_live_test.exs
git commit -m "feat(portal): Stats page (overall counts + per-system table)"
```

---

### Task 7: Verification

- [ ] **Step 1: Umbrella tests**

Run (from repo root): `mix test`
Expected: PASS (integration excluded).

- [ ] **Step 2: Warnings-as-errors + format**

Run (from repo root): `mix compile --warnings-as-errors` and `mix format --check-formatted apps/portal/lib/portal/catalog/rollup.ex apps/portal/lib/portal/catalog/architecture.ex apps/portal/lib/portal/catalog.ex apps/portal/lib/portal_web/live/dashboard_live.ex apps/portal/lib/portal_web/live/failure_clusters_live.ex apps/portal/lib/portal_web/live/stats_live.ex apps/portal/lib/portal_web/live/warnings_live.ex`
Expected: clean.

- [ ] **Step 3: Manual check (light + dark)**

Run `mix phx.server` on a free port. Seed a couple runs (one passing, one with a failing system + `log_tail`). Visit `/` (summary + tiles + recent lists), `/failure_clusters` (cluster card + sample log), `/stats` (overall + per-system table), `/warnings` (stub); check nav highlights each. Toggle theme — all legible in light + dark.

---

## Self-Review

**Spec coverage:**
- Shared helpers (overall_status, native_bucket, Architecture.label) → Task 1. ✓
- package_status_counts + richer failure_clusters (title/hint/entries/sample_log) → Task 2. ✓
- Routes + nav + Warnings stub → Task 3. ✓
- Dashboard rebuilt in prod structure → Task 4. ✓
- Failure clusters page → Task 5. ✓
- Stats page (overall + by-system; BEAM deferred) → Task 6. ✓
- Verification → Task 7. ✓
- Non-goals honored: no packages-list filters, no package-detail, no warnings rules, no BEAM aggregates, no worker/API change.

**Placeholder scan:** Conditional notes in Task 3 (placeholder modules to compile) and Task 6 (`normalize_counts` key confirmation) each name the concrete action + anchor. Acceptable.

**Type consistency:** `failure_clusters/1` returns `%{category,title,hint,systems,packages,entries,sample_log}` — consumed by DashboardLive (`.title/.systems/.packages`) and FailureClustersLive (`.title/.hint/.entries/.sample_log`). `package_status_counts/0` returns `%{unique,pass,fail,partial,skipped,unknown}` — consumed by Dashboard + Stats. `recent_runs/2` rows read as `.package/.version/.overall_status`. Consistent. ✓
