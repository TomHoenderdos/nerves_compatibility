# Argus Findings Triage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An internal `/admin/argus/findings` list of argus findings across packages, with a per-finding triage status and note that survive rebuilds.

**Architecture:** A new Ash resource `Portal.Catalog.FindingTriage` keyed on a line-independent fingerprint. `Portal.Catalog.Ingestion` upserts one row per finding of every `ok` argus run, inside the ingest transaction, never touching an admin's status. `Portal.Catalog` exposes list/count/update functions, and a passkey-gated LiveView renders and edits them.

**Tech Stack:** Elixir 1.20, Phoenix 1.8 LiveView, Ash 3 + AshPostgres.

**Spec:** `docs/superpowers/specs/2026-10-05-argus-triage-design.md`

## Global Constraints

- Statuses exactly `new | confirmed | false_positive | reported`; default `new`.
- Fingerprint: lowercase hex sha256 of `package_name, analysis, title, file || "", detail || ""` joined by `"\0"`. No line number.
- A `:sighting` upsert never overwrites `status`, `note`, `updated_by`, `first_seen_version`.
- Malformed findings are skipped; triage recording never fails an ingest.
- Page only for a passkey-signed-in admin (`RequireAdmin`), same as `/admin/oban`.
- No email, no Jev, no change to the public package page.
- Never run `mix deps.*` inside `apps/*`; don't run `mix precommit`. Migrations via `mix ash_postgres.generate_migrations` in `apps/portal`.
- Follow `apps/portal/AGENTS.md`: `<.form>`/`<.input>`, streams for the list, unique DOM ids.

## Review Focus

1. A finding whose `title`/`analysis`/`severity` is not a string, or a non-map entry in `findings` — skipped, run still ingests. Pinned in Task 2.
2. The same finding at a shifted line in a newer version — one row, status kept, `last_seen_*` moved. Pinned in Tasks 1 and 2.
3. Two findings of one class in one file (same title, different `detail`) — two rows. Pinned in Task 1.
4. A finding that disappears in a newer build — marked stale, hidden by default, shown with the filter. Pinned in Task 3.
5. An admin who signed in with a password, or a non-admin, opening the page — refused. Pinned in Task 4.

---

### Task 1: `FindingTriage` resource and fingerprint

**Files:**
- Create: `apps/portal/lib/portal/catalog/finding_triage.ex`
- Modify: `apps/portal/lib/portal/catalog.ex` (`resources do` block)
- Create (generated): migration + snapshot
- Test: `apps/portal/test/portal/catalog/finding_triage_test.exs`

**Interfaces:**
- Produces: `Portal.Catalog.FindingTriage.fingerprint(package_name :: String.t(), finding :: map()) :: String.t()`; actions `:sighting` (upsert) and `:triage` (update); attributes as in the spec.

- [ ] **Step 1: Failing test**

```elixir
defmodule Portal.Catalog.FindingTriageTest do
  use Portal.DataCase, async: true

  alias Portal.Catalog.FindingTriage

  @finding %{
    "analysis" => "mailbox",
    "severity" => "warning",
    "title" => "Timer cancelled without flushing its message",
    "file" => "lib/x/downloader.ex",
    "line" => 263,
    "detail" => "X.Downloader cancels the timer in X.Downloader.reschedule/1"
  }

  test "fingerprint ignores the line number" do
    assert FindingTriage.fingerprint("x", @finding) ==
             FindingTriage.fingerprint("x", %{@finding | "line" => 300})
  end

  test "fingerprint separates two findings of one class in one file" do
    refute FindingTriage.fingerprint("x", @finding) ==
             FindingTriage.fingerprint("x", %{@finding | "detail" => "X.Downloader.other/1"})
  end

  test "fingerprint separates packages" do
    refute FindingTriage.fingerprint("x", @finding) == FindingTriage.fingerprint("y", @finding)
  end

  test "fingerprint is lowercase hex sha256" do
    assert FindingTriage.fingerprint("x", @finding) =~ ~r/\A[0-9a-f]{64}\z/
  end
end
```

- [ ] **Step 2:** `mix test apps/portal/test/portal/catalog/finding_triage_test.exs` (repo root) → FAIL, module undefined.

- [ ] **Step 3: Implement**

```elixir
defmodule Portal.Catalog.FindingTriage do
  @moduledoc """
  An admin's verdict on one argus finding, across every run that reports it.

  Keyed on `fingerprint/2`, which leaves the line number out so a finding that
  moves in a newer version is still the same row and keeps its status.
  Ingestion records each sighting through `:sighting`; admins set `:triage`.
  """

  use Ash.Resource,
    domain: Portal.Catalog,
    data_layer: AshPostgres.DataLayer

  postgres do
    table("catalog_finding_triage")
    repo(Portal.Repo)

    custom_indexes do
      index([:status])
      index([:package_name])
    end
  end

  actions do
    defaults([:read])

    # Upserts never touch what an admin decided: status, note, updated_by and
    # the version the finding was first seen in.
    create :sighting do
      accept([
        :fingerprint,
        :package_name,
        :analysis,
        :severity,
        :title,
        :file,
        :line,
        :finding,
        :first_seen_version,
        :last_seen_version,
        :last_seen_run_id
      ])

      upsert?(true)
      upsert_identity(:unique_fingerprint)
      upsert_fields([:severity, :line, :finding, :last_seen_version, :last_seen_run_id])
    end

    update :triage do
      accept([:status, :note, :updated_by])
    end
  end

  identities do
    identity(:unique_fingerprint, [:fingerprint])
  end

  attributes do
    uuid_primary_key(:id)

    attribute :fingerprint, :string, allow_nil?: false, public?: true
    attribute :package_name, :string, allow_nil?: false, public?: true
    attribute :analysis, :string, allow_nil?: false, public?: true
    attribute :severity, :string, allow_nil?: false, public?: true
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :file, :string, public?: true
    attribute :line, :integer, public?: true
    attribute :finding, :map, public?: true

    attribute :status, :atom do
      allow_nil?(false)
      default(:new)
      public?(true)
      constraints(one_of: [:new, :confirmed, :false_positive, :reported])
    end

    attribute :note, :string, public?: true
    attribute :first_seen_version, :string, public?: true
    attribute :last_seen_version, :string, public?: true
    attribute :last_seen_run_id, :uuid, public?: true
    attribute :updated_by, :string, public?: true

    create_timestamp(:inserted_at)
    update_timestamp(:updated_at)
  end

  @doc "The identity of `finding` in `package_name`, independent of its line."
  @spec fingerprint(String.t(), map()) :: String.t()
  def fingerprint(package_name, finding) do
    [
      package_name,
      finding["analysis"],
      finding["title"],
      text(finding["file"]),
      text(finding["detail"])
    ]
    |> Enum.join(<<0>>)
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp text(value) when is_binary(value), do: value
  defp text(_), do: ""
end
```

Add `resource(FindingTriage)` to `Portal.Catalog`'s `resources do` block and `FindingTriage` to its alias list. Then in `apps/portal`: `mix ash_postgres.generate_migrations --name add_finding_triage`; read the migration (must only create `catalog_finding_triage` with its unique and two plain indexes).

- [ ] **Step 4:** test → PASS 4/4.
- [ ] **Step 5:** commit `feat(portal): finding triage resource keyed on a line-independent fingerprint`.

---

### Task 2: Record sightings on ingest

**Files:**
- Modify: `apps/portal/lib/portal/catalog/ingestion.ex` (`ingest` with-chain ~L95)
- Test: `apps/portal/test/portal/catalog/finding_triage_ingest_test.exs`

**Interfaces:**
- Consumes: `FindingTriage` `:sighting`, `fingerprint/2` (Task 1).

- [ ] **Step 1: Failing tests**

```elixir
defmodule Portal.Catalog.FindingTriageIngestTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.{FindingTriage, Ingestion}

  defp finding(extra \\ %{}) do
    Map.merge(
      %{
        "analysis" => "failure",
        "severity" => "warning",
        "title" => "Catch-all rescue swallows exceptions",
        "file" => "lib/p/a.ex",
        "line" => 10,
        "detail" => "P.A.run/1 takes every exception"
      },
      extra
    )
  end

  defp ingest(version, argus, n) do
    files = Path.join(System.tmp_dir!(), "tri-f-#{n}-#{System.unique_integer([:positive])}")
    out = Path.join(System.tmp_dir!(), "tri-o-#{n}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(files)
    File.mkdir_p!(Path.join(out, "logs"))
    on_exit(fn -> File.rm_rf(files) && File.rm_rf(out) end)

    result =
      %{
        "package" => %{"name" => "tripkg", "version" => version},
        "finished_at" => "2026-10-0#{n}T10:00:00Z",
        "systems" => %{"nerves_system_rpi4" => %{"status" => "pass"}}
      }
      |> then(&if(argus == :absent, do: &1, else: Map.put(&1, "argus", argus)))

    {:ok, run} =
      Ingestion.ingest(result, %{
        run_id: "tripkg-#{n}-#{System.unique_integer([:positive])}",
        image_digest: "sha256:x",
        files_dir: files,
        output_dir: out,
        log: "runner"
      })

    run
  end

  defp ok(findings), do: %{"status" => "ok", "version" => "0.20.1", "findings" => findings}
  defp rows, do: Ash.read!(FindingTriage, domain: Portal.Catalog)

  test "an ok run creates one new row per finding" do
    run = ingest("1.0.0", ok([finding(), finding(%{"detail" => "P.A.other/1"})]), 1)

    assert [_, _] = rows = rows()
    assert Enum.all?(rows, &(&1.status == :new and &1.package_name == "tripkg"))
    assert Enum.all?(rows, &(&1.first_seen_version == "1.0.0" and &1.last_seen_run_id == run.id))
  end

  test "a later run moves last_seen and keeps the admin's status" do
    ingest("1.0.0", ok([finding()]), 1)
    [row] = rows()

    row
    |> Ash.Changeset.for_update(:triage, %{status: :confirmed, note: "real", updated_by: "tom"})
    |> Ash.update!(domain: Portal.Catalog)

    run2 = ingest("1.1.0", ok([finding(%{"line" => 42})]), 2)

    assert [row] = rows()
    assert row.status == :confirmed
    assert row.note == "real"
    assert row.updated_by == "tom"
    assert row.first_seen_version == "1.0.0"
    assert row.last_seen_version == "1.1.0"
    assert row.last_seen_run_id == run2.id
    assert row.line == 42
  end

  test "error, skipped and absent argus record nothing" do
    ingest("1.0.0", %{"status" => "error", "findings" => [], "error" => "x"}, 1)
    ingest("1.0.1", %{"status" => "skipped"}, 2)
    ingest("1.0.2", :absent, 3)
    assert rows() == []
  end

  test "malformed findings are skipped and the run still ingests" do
    bad = [
      "not a map",
      finding(%{"title" => %{"x" => 1}}),
      finding(%{"severity" => nil}),
      Map.delete(finding(), "analysis")
    ]

    assert %{id: _} = ingest("1.0.0", ok([finding() | bad]), 1)
    assert [_] = rows()
  end
end
```

- [ ] **Step 2:** run → FAIL (no rows).

- [ ] **Step 3: Implement** in `ingestion.ex`. Extend the with-chain:

```elixir
    with {:ok, package} <- upsert_package(package_name, package_info, finished_at),
         {:ok, run} <-
           create_run(result, opts, package.id, version, overall, finished_at),
         :ok <-
           create_system_results(systems, run.id, version, staged, logs),
         :ok <- record_triage(package_name, version, run.id, result["argus"]) do
      {:ok, run}
    end
```

and add:

```elixir
  # One FindingTriage row per finding of an `ok` argus run. Only findings with
  # string analysis, severity and title are recorded: anything else is skipped
  # here rather than handed to Postgres, where an insert error would abort the
  # whole ingest transaction.
  defp record_triage(package_name, version, run_id, %{"status" => "ok", "findings" => findings})
       when is_list(findings) do
    findings
    |> Enum.filter(&triageable?/1)
    |> Enum.each(fn finding ->
      FindingTriage
      |> Ash.Changeset.for_create(:sighting, %{
        fingerprint: FindingTriage.fingerprint(package_name, finding),
        package_name: package_name,
        analysis: finding["analysis"],
        severity: finding["severity"],
        title: finding["title"],
        file: if(is_binary(finding["file"]), do: finding["file"]),
        line: if(is_integer(finding["line"]), do: finding["line"]),
        finding: finding,
        first_seen_version: version,
        last_seen_version: version,
        last_seen_run_id: run_id
      })
      |> Ash.create!(domain: @domain)
    end)
  end

  defp record_triage(_package_name, _version, _run_id, _argus), do: :ok

  defp triageable?(%{"analysis" => a, "severity" => s, "title" => t})
       when is_binary(a) and is_binary(t) and s in ["error", "warning", "info"],
       do: true

  defp triageable?(_), do: false
```

Add `FindingTriage` to the module's `alias Portal.Catalog.{...}`.

- [ ] **Step 4:** run → PASS 4/4; also `mix test apps/portal/test/portal/catalog/ingestion_test.exs` stays green.
- [ ] **Step 5:** commit `feat(portal): record argus findings for triage on ingest`.

---

### Task 3: Catalog queries

**Files:**
- Modify: `apps/portal/lib/portal/catalog.ex`
- Test: `apps/portal/test/portal/catalog/triage_queries_test.exs`

**Interfaces:**
- Produces:
  - `Portal.Catalog.triage_list(filters :: map()) :: [%{triage: FindingTriage.t(), stale?: boolean()}]` — filter keys `:status` (atoms), `:severity` (strings), `:analysis` (string | nil), `:package` (string | nil), `:include_stale` (boolean); missing keys use defaults `status: [:new, :confirmed]`, `severity: ["error", "warning", "info"]`, `analysis: nil`, `package: nil`, `include_stale: false`.
  - `Portal.Catalog.triage_counts() :: %{new: n, confirmed: n, false_positive: n, reported: n}` over non-stale rows.
  - `Portal.Catalog.triage!(id :: String.t(), attrs :: %{status: atom | String.t(), note: String.t() | nil}, admin :: User.t()) :: FindingTriage.t()`

- [ ] **Step 1: Failing tests** — reuse Task 2's `ingest/3`, `finding/1`, `ok/1` helpers (copy them into this file):

```elixir
  test "defaults list new and confirmed, errors first" do
    ingest("1.0.0", ok([finding(), finding(%{"severity" => "error", "detail" => "e"})]), 1)
    assert [%{triage: %{severity: "error"}}, %{triage: %{severity: "warning"}}] = Catalog.triage_list(%{})
  end

  test "status, severity, analysis and package filters" do
    ingest("1.0.0", ok([finding(), finding(%{"severity" => "info", "analysis" => "mailbox", "detail" => "i"})]), 1)
    [%{triage: info}] = Catalog.triage_list(%{severity: ["info"]})
    Catalog.triage!(info.id, %{status: "false_positive", note: nil}, %{username: "tom"})

    assert [] = Catalog.triage_list(%{severity: ["info"]})
    assert [_] = Catalog.triage_list(%{status: [:false_positive]})
    assert [_] = Catalog.triage_list(%{analysis: "failure"})
    assert [_, _] = Catalog.triage_list(%{status: [:new, :false_positive], package: "ripk"})
    assert [] = Catalog.triage_list(%{package: "nope"})
  end

  test "a finding absent from the latest run is stale and hidden by default" do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "gone later"})]), 1)
    ingest("1.1.0", ok([finding()]), 2)

    assert [%{stale?: false}] = Catalog.triage_list(%{})
    assert [_, _] = all = Catalog.triage_list(%{include_stale: true})
    assert Enum.count(all, & &1.stale?) == 1
  end

  test "counts ignore stale rows" do
    ingest("1.0.0", ok([finding(), finding(%{"detail" => "gone later"})]), 1)
    ingest("1.1.0", ok([finding()]), 2)
    assert Catalog.triage_counts() == %{new: 1, confirmed: 0, false_positive: 0, reported: 0}
  end

  test "triage! records status, note and the admin" do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Catalog.triage_list(%{})
    updated = Catalog.triage!(row.id, %{status: "reported", note: "issue #12"}, %{username: "tom"})
    assert {updated.status, updated.note, updated.updated_by} == {:reported, "issue #12", "tom"}
  end
```

- [ ] **Step 2:** run → FAIL, undefined functions.

- [ ] **Step 3: Implement** in `catalog.ex` (alias `FindingTriage`):

```elixir
  @triage_defaults %{
    status: [:new, :confirmed],
    severity: ["error", "warning", "info"],
    analysis: nil,
    package: nil,
    include_stale: false
  }
  @triage_status_order %{new: 0, confirmed: 1, reported: 2, false_positive: 3}
  @triage_severity_order %{"error" => 0, "warning" => 1, "info" => 2}

  @doc """
  argus findings for the admin triage list, each with `stale?`: true when the
  package's latest run no longer reports it. See `@triage_defaults` for filters.
  """
  def triage_list(filters \\ %{}) do
    f = Map.merge(@triage_defaults, filters)

    rows =
      FindingTriage
      |> Ash.Query.filter(status in ^f.status and severity in ^f.severity)
      |> then(fn q -> if f.analysis, do: Ash.Query.filter(q, analysis == ^f.analysis), else: q end)
      |> then(fn q ->
        if f.package in [nil, ""], do: q, else: Ash.Query.filter(q, contains(package_name, ^f.package))
      end)
      |> Ash.read!(domain: __MODULE__)

    latest = latest_run_ids(rows |> Enum.map(& &1.package_name) |> Enum.uniq())

    rows
    |> Enum.map(&%{triage: &1, stale?: Map.get(latest, &1.package_name) != &1.last_seen_run_id})
    |> Enum.filter(&(f.include_stale or not &1.stale?))
    |> Enum.sort_by(fn %{triage: t} ->
      {@triage_status_order[t.status], @triage_severity_order[t.severity], t.package_name, t.title}
    end)
  end

  @doc "Non-stale triage rows per status."
  def triage_counts do
    counts =
      triage_list(%{status: Map.keys(@triage_status_order), severity: Map.keys(@triage_severity_order)})
      |> Enum.frequencies_by(& &1.triage.status)

    Map.new(Map.keys(@triage_status_order), &{&1, Map.get(counts, &1, 0)})
  end

  @doc "Sets an admin's verdict on one finding."
  def triage!(id, attrs, admin) do
    FindingTriage
    |> Ash.get!(id, domain: __MODULE__)
    |> Ash.Changeset.for_update(:triage, %{
      status: attrs[:status],
      note: attrs[:note],
      updated_by: admin.username
    })
    |> Ash.update!(domain: __MODULE__)
  end

  defp latest_run_ids([]), do: %{}

  defp latest_run_ids(names) do
    packages = Package |> Ash.Query.filter(name in ^names) |> Ash.read!(domain: __MODULE__)
    runs = latest_runs(packages)
    Map.new(packages, &{&1.name, runs |> Map.get(&1.id, %{}) |> Map.get(:id)})
  end
```

- [ ] **Step 4:** run → PASS 5/5.
- [ ] **Step 5:** commit `feat(portal): triage list, counts and verdicts in the catalog`.

---

### Task 4: `/admin/argus/findings` LiveView

**Files:**
- Create: `apps/portal/lib/portal_web/live/admin/argus_findings_live.ex`
- Modify: `apps/portal/lib/portal_web/router.ex` (`/admin` scope)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/admin.html.heex` (link in argus card)
- Test: `apps/portal/test/portal_web/live/argus_findings_live_test.exs`

**Interfaces:**
- Consumes: `Catalog.triage_list/1`, `triage_counts/0`, `triage!/3`.

- [ ] **Step 1: Failing tests** — copy Task 2's `ingest/3` (with package "tripkg"), `finding/1`, `ok/1`; plus:

```elixir
  setup %{conn: conn} do
    {:ok, admin} = Portal.Accounts.seed_admin_user("triage_admin", "correct horse battery staple")
    Portal.Test.AccountsFixtures.add_test_passkey(admin)
    %{conn: init_test_session(conn, user_id: admin.id, login_method: :passkey), admin: admin}
  end

  test "anonymous visitors are sent to login" do
    assert redirected_to(get(build_conn(), ~p"/admin/argus/findings")) == ~p"/login"
  end

  test "an admin signed in with a password is refused", %{admin: admin} do
    conn = build_conn() |> init_test_session(user_id: admin.id, login_method: :password)
    assert redirected_to(get(conn, ~p"/admin/argus/findings")) == ~p"/settings/security"
  end

  test "lists findings with counts", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")
    assert has_element?(view, "#findings", "Catch-all rescue swallows exceptions")
    assert has_element?(view, "#triage-counts", "1 new")
  end

  test "changing a status saves it and updates the counts", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    [%{triage: row}] = Portal.Catalog.triage_list(%{})
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

    view
    |> form("#triage-form-#{row.id}", triage: %{status: "confirmed", note: "real bug"})
    |> render_change()

    [%{triage: saved}] = Portal.Catalog.triage_list(%{})
    assert {saved.status, saved.note, saved.updated_by} == {:confirmed, "real bug", "triage_admin"}
    assert has_element?(view, "#triage-counts", "1 confirmed")
  end

  test "filters patch the URL", %{conn: conn} do
    ingest("1.0.0", ok([finding()]), 1)
    {:ok, view, _} = live(conn, ~p"/admin/argus/findings")

    view |> form("#triage-filters", f: %{package: "nope"}) |> render_change()
    assert_patch(view, ~p"/admin/argus/findings?#{%{package: "nope"}}")
    refute has_element?(view, "#findings", "Catch-all")
  end

  test "the admin page links to the list", %{conn: conn} do
    assert html_response(get(conn, ~p"/admin"), 200) =~ ~s(href="/admin/argus/findings")
  end
```

- [ ] **Step 2:** run → FAIL (no route).

- [ ] **Step 3: Implement.** Router — replace the `/admin` scope:

```elixir
  scope "/admin" do
    pipe_through [:admin]

    # (existing comment about on_mount) ...
    oban_dashboard("/oban", on_mount: [{PortalWeb.Plugs.RequireAdmin, :require_admin_passkey}])

    # Same reasoning as the Oban dashboard: the pipeline guards the first HTTP
    # request, the on_mount guards every LiveView reconnect after it.
    live_session :admin,
      on_mount: [
        {PortalWeb.UserAuth, :assign_current_user},
        {PortalWeb.Plugs.RequireAdmin, :require_admin_passkey}
      ] do
      live "/argus/findings", PortalWeb.Admin.ArgusFindingsLive, :index
    end
  end
```

LiveView `apps/portal/lib/portal_web/live/admin/argus_findings_live.ex`:

```elixir
defmodule PortalWeb.Admin.ArgusFindingsLive do
  @moduledoc """
  Internal triage of argus findings across packages. Admin (passkey) only;
  see `Portal.Catalog.FindingTriage`.
  """
  use PortalWeb, :live_view

  alias Portal.Catalog

  @statuses [new: "new", confirmed: "confirmed", false_positive: "false positive", reported: "reported"]
  @severities ~w(error warning info)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, page_title: "argus findings", page_description: "Internal triage.")}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters = filters(params)

    {:noreply,
     socket
     |> assign(:params, Map.take(params, ~w(status severity analysis package stale)))
     |> assign(:filter_form, to_form(filter_params(filters), as: :f))
     |> assign(:counts, Catalog.triage_counts())
     |> stream(:findings, Catalog.triage_list(filters), reset: true, dom_id: &"finding-#{&1.triage.id}")}
  end

  @impl true
  def handle_event("filter", %{"f" => f}, socket) do
    query =
      %{
        "status" => List.wrap(f["status"]) |> Enum.reject(&(&1 == "")),
        "severity" => List.wrap(f["severity"]) |> Enum.reject(&(&1 == "")),
        "analysis" => f["analysis"],
        "package" => f["package"],
        "stale" => if(f["stale"] == "true", do: "true")
      }
      |> Enum.reject(fn {_k, v} -> v in [nil, "", []] end)
      |> Map.new()

    {:noreply, push_patch(socket, to: ~p"/admin/argus/findings?#{query}")}
  end

  def handle_event("triage", %{"id" => id, "triage" => t}, socket) do
    row = Catalog.triage!(id, %{status: t["status"], note: blank_to_nil(t["note"])}, socket.assigns.current_user)
    stale? = Enum.any?(Catalog.triage_list(%{include_stale: true, status: [row.status]}), &(&1.triage.id == row.id and &1.stale?))

    {:noreply,
     socket
     |> assign(:counts, Catalog.triage_counts())
     |> stream_insert(:findings, %{triage: row, stale?: stale?})
     |> put_flash(:info, "Saved.")}
  end

  defp filters(params) do
    %{}
    |> put_list(:status, params["status"], &status_atom/1)
    |> put_list(:severity, params["severity"], &(&1 in @severities && &1))
    |> Map.put(:analysis, blank_to_nil(params["analysis"]))
    |> Map.put(:package, blank_to_nil(params["package"]))
    |> Map.put(:include_stale, params["stale"] == "true")
  end

  defp put_list(map, key, values, cast) do
    case values |> List.wrap() |> Enum.map(cast) |> Enum.filter(& &1) do
      [] -> map
      list -> Map.put(map, key, list)
    end
  end

  defp status_atom(value) do
    Enum.find_value(@statuses, fn {atom, _} -> Atom.to_string(atom) == value && atom end)
  end

  defp filter_params(filters) do
    %{
      "status" => Enum.map(Map.get(filters, :status, [:new, :confirmed]), &Atom.to_string/1),
      "severity" => Map.get(filters, :severity, @severities),
      "analysis" => filters.analysis,
      "package" => filters.package,
      "stale" => to_string(filters.include_stale)
    }
  end

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp text(value) when is_binary(value), do: value
  defp text(_), do: nil

  defp severity_class("error"), do: "badge-error"
  defp severity_class("warning"), do: "badge-warning"
  defp severity_class(_), do: "badge-ghost"

  @impl true
  def render(assigns) do
    assigns = assign(assigns, statuses: @statuses, severities: @severities)

    ~H"""
    <Layouts.app flash={@flash} current_user={@current_user}>
      <section class="space-y-6">
        <PortalWeb.UI.page_header kicker="Admin" title="argus findings">
          <:subtitle>Internal triage. Nothing here is public or sent to anyone.</:subtitle>
        </PortalWeb.UI.page_header>

        <div id="triage-counts" class="flex flex-wrap gap-2">
          <span :for={{status, label} <- @statuses} class="badge badge-lg badge-outline">
            {Map.get(@counts, status, 0)} {label}
          </span>
        </div>

        <.form for={@filter_form} id="triage-filters" phx-change="filter" class="grid gap-3 sm:grid-cols-5">
          <.input field={@filter_form[:status]} type="select" multiple label="Status"
            options={Enum.map(@statuses, fn {a, l} -> {l, a} end)} />
          <.input field={@filter_form[:severity]} type="select" multiple label="Severity" options={@severities} />
          <.input field={@filter_form[:analysis]} type="text" label="Analysis" phx-debounce="300" />
          <.input field={@filter_form[:package]} type="text" label="Package" phx-debounce="300" />
          <.input field={@filter_form[:stale]} type="checkbox" label="Include no longer seen" />
        </.form>

        <div class="overflow-x-auto rounded-2xl border border-base-300 bg-base-100">
          <table class="w-full text-sm">
            <thead class="bg-base-200/60 text-left text-xs uppercase text-base-content/60">
              <tr>
                <th class="px-4 py-3">Finding</th>
                <th class="px-4 py-3">Versions</th>
                <th class="px-4 py-3">Triage</th>
              </tr>
            </thead>
            <tbody id="findings" phx-update="stream" class="divide-y divide-base-200">
              <tr :for={{dom_id, %{triage: t, stale?: stale?}} <- @streams.findings} id={dom_id}>
                <td class="px-4 py-3 align-top">
                  <div class="flex flex-wrap items-center gap-2">
                    <span class={["badge badge-sm", severity_class(t.severity)]}>{t.severity}</span>
                    <.link navigate={~p"/packages/#{t.package_name}"} class="font-mono link">{t.package_name}</.link>
                    <span class="badge badge-sm badge-outline font-mono">{t.analysis}</span>
                    <span :if={stale?} class="badge badge-sm badge-ghost">no longer seen</span>
                  </div>
                  <div class="mt-1 font-medium">{t.title}</div>
                  <div :if={t.file} class="font-mono text-xs text-base-content/60">
                    {t.file}{if t.line, do: ":#{t.line}"}
                  </div>
                  <details class="mt-1 text-base-content/70">
                    <summary class="cursor-pointer text-xs">Details</summary>
                    <p :if={text(t.finding["detail"])}>{text(t.finding["detail"])}</p>
                    <ul class="list-disc pl-5">
                      <li :for={hint <- List.wrap(t.finding["help"]) |> Enum.filter(&is_binary/1)}>{hint}</li>
                    </ul>
                  </details>
                </td>
                <td class="px-4 py-3 align-top font-mono text-xs text-base-content/60">
                  {t.first_seen_version} → {t.last_seen_version}
                </td>
                <td class="px-4 py-3 align-top">
                  <.form
                    for={to_form(%{"status" => Atom.to_string(t.status), "note" => t.note}, as: :triage)}
                    id={"triage-form-#{t.id}"}
                    phx-change="triage"
                    phx-value-id={t.id}
                  >
                    <.input name="triage[status]" type="select" value={Atom.to_string(t.status)}
                      id={"triage-status-#{t.id}"} options={Enum.map(@statuses, fn {a, l} -> {l, a} end)} />
                    <.input name="triage[note]" type="text" value={t.note} placeholder="Note"
                      id={"triage-note-#{t.id}"} phx-debounce="500" />
                  </.form>
                  <div :if={t.updated_by} class="text-xs text-base-content/50">by {t.updated_by}</div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </section>
    </Layouts.app>
    """
  end
end
```

Note: `phx-value-id` on a form is merged into `phx-change` params only for the triggering element in some LiveView versions; if the `"id"` key is missing in `handle_event("triage", ...)`, add `<input type="hidden" name="id" value={t.id} />` inside the form instead and keep the clause matching `%{"id" => id}`.

Admin card link — in `admin.html.heex`, inside `#argus-settings`, before the `<form`:

```heex
          <.link navigate={~p"/admin/argus/findings"} class="link mt-2 inline-block text-sm">
            Triage findings →
          </.link>
```

- [ ] **Step 4:** run → PASS; then the full suite from the root, `mix format`, `mix compile --warnings-as-errors`.
- [ ] **Step 5:** commit `feat(admin): argus findings triage list`.

---

### Finish

- Final whole-branch review of the triage commits by a fresh reviewer; fix Critical/Important with RED→GREEN tests.
- Merge `worktree-feat-argus` into local `main` (user pre-approved), run the suite on the merged result. Do **not** push: pushing main deploys; hand the user the push command.
