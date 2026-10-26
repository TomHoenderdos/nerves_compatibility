# Build Cache L2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A shared S3 bucket (Garage) behind the local dependency build cache, read before every build and written after every promotion, so a dependency compiled on one home host is restored on the others.

**Architecture:** New `Portal.BuildCache.L2*` modules in the portal: config from env, a Req-based S3 client signing with Req's own SigV4, a tarball module that packs and unpacks one cache entry under strict structural rules, a per-node stats table, `upload/4` hooked into `Portal.BuildCache.Promotion` after its rename, and `prefetch/3` hooked into `Portal.Builder.build/2` before `docker run`, which syncs the image slug's object listing into the local cache under a byte and time budget. The structural walker Promotion already has moves to `Portal.BuildCache.Tree` so both ends run the same checks; staging names gain the hostname and `Portal.Workers.Sweep` learns the rule. Tests run against an in-process S3 stub (`Portal.Test.FakeS3`, Plug on Bandit) with its own SigV4 verifier.

**Tech Stack:** Elixir 1.20 / OTP 28, Phoenix 1.8, Req 0.7 (`aws_sigv4`), OTP `:erl_tar`, Plug + Bandit (test stub), ExUnit.

**Spec:** `docs/superpowers/specs/2026-10-26-build-cache-l2-design.md` (read it first; every section number below refers to it).

## Global Constraints

- No new Hex dependency. `req`, `plug`, `bandit`, `jason` are already portal deps.
- `apps/ncc_worker` and `apps/ncc_agent` do not change.
- Never run `mix deps.*` inside `apps/*`; every mix command runs from the umbrella root (`/home/agent/repo`), with `source /home/agent/toolchain/env.sh` first (it puts Elixir, Postgres and shellcheck on PATH and sets the test DB env).
- Object name: `<slug>/<key>.tar.gz`; metadata header `x-amz-meta-sha256`.
- Per-build prefetch budget: 2 GiB and 5 minutes. Per-object cap 512 MiB. Connect timeout 10 s.
- Env: `NCC_BUILD_CACHE_S3_ENDPOINT`, `_BUCKET`, `_REGION` (default `garage`), `_ACCESS_KEY`, `_SECRET_KEY`, `_READ_ONLY=1`. Unset endpoint = off, behaviour identical to today.
- Staging names: `<key>.tmp.<host>.<hex16>` and `<key>.tmp.<host>.<hex16>.tar.gz`.
- Every commit message ends with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- Code style: moduledocs explain why, like `Promotion`; `# sobelow_skip [...]` comments where `File` is called on host-built paths (the four sobelow runs use `--strict --exit low`, so an unannotated `File.*` on a non-literal path fails the gate: copy the existing pattern, a one-line justification above `# sobelow_skip ["Traversal.FileModule"]`). Credo is strict on the default config.
- Run after each task: `mix format`, `mix compile --warnings-as-errors`, `mix test apps/portal/test/<changed files>`, then the whole portal suite before the commit.

## Review Focus

Inputs the spec implies but which no single feature test would catch; each has its test in the task that owns it.

1. A listing key that is a valid hex name but whose object is not a tarball at all (an operator uploaded junk): prefetch refuses, marks it bad, continues. (Task 7)
2. A tarball with a top-level `priv` symlink of Mix's shape but pointing at `../../../../deps/other/priv` while the archive is for another package: the download side cannot know, and accepts it; the upload side with the package bound refuses it. Both pinned. (Tasks 3 and 6)
3. A ListObjectsV2 page whose `IsTruncated` is true but which carries no continuation token: the client stops after that page rather than looping. (Task 5)
4. A hostname with characters outside `[A-Za-z0-9-]` (`box.home.arpa`): staging names stay parseable and Sweep still recognises its own. (Task 1)
5. Two builds on one node racing for the same key: the second skips a claimed key, and a claim held by a dead process does not block forever. (Task 2)

---

### Task 1: Staging names, the shared Tree walker, Promotion delegation, Sweep rule

**Files:**
- Create: `apps/portal/lib/portal/build_cache/staging.ex`
- Create: `apps/portal/lib/portal/build_cache/tree.ex`
- Modify: `apps/portal/lib/portal/build_cache/promotion.ex` (walker, strip_modes, name_string, staging name)
- Modify: `apps/portal/lib/portal/workers/sweep.ex` (`sweep_staging/3`, moduledoc)
- Test: `apps/portal/test/portal/build_cache/staging_test.exs` (new), `apps/portal/test/portal/build_cache/tree_test.exs` (new), `apps/portal/test/portal/workers/sweep_test.exs` (modify), `apps/portal/test/portal/build_cache/promotion_test.exs` (must stay green unchanged)

**Interfaces:**
- Produces: `Portal.BuildCache.Staging.name(dest :: Path.t()) :: Path.t()`, `host() :: String.t()`, `parse(name) :: {:ok, %{host: String.t() | nil, download?: boolean()}} | :error`, `ours?(name, host) :: boolean()`.
- Produces: `Portal.BuildCache.Tree.check(dir, package: String.t() | :any) :: :ok | {:error, String.t()}`, `strip_modes(path) :: :ok | {:error, term}`, `name_string(raw) :: {:ok, String.t()} | :error`, `show(term) :: String.t()`.
- Consumes: nothing new.

- [ ] **Step 1: Write the failing Staging tests**

`apps/portal/test/portal/build_cache/staging_test.exs`:

```elixir
defmodule Portal.BuildCache.StagingTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.Staging

  test "name/1 is dest.tmp.<host>.<16 hex>" do
    name = Staging.name("/cache/sha256_x/" <> String.duplicate("a", 64))
    host = Staging.host()
    assert {:ok, %{host: ^host, download?: false}} = Staging.parse(Path.basename(name))
    assert Regex.match?(~r/\.tmp\.#{Regex.escape(host)}\.[0-9a-f]{16}\z/, name)
  end

  test "host/0 only ever contains [A-Za-z0-9-] and is never empty" do
    assert Regex.match?(~r/\A[A-Za-z0-9-]{1,63}\z/, Staging.host())
    assert Staging.sanitize_host("box.home.arpa") == "box-home-arpa"
    assert Staging.sanitize_host("") == "host"
    assert Staging.sanitize_host(String.duplicate("x", 80)) == String.duplicate("x", 63)
  end

  test "parse/1 reads the legacy form, the host form and the download form" do
    assert {:ok, %{host: nil, download?: false}} = Staging.parse("k.tmp.a1b2c3d4e5f60718")
    assert {:ok, %{host: "box-b", download?: false}} = Staging.parse("k.tmp.box-b.a1b2c3d4e5f60718")
    assert {:ok, %{host: "box-b", download?: true}} = Staging.parse("k.tmp.box-b.a1b2c3d4e5f60718.tar.gz")
    assert :error = Staging.parse("k")
    assert :error = Staging.parse(String.duplicate("a", 64))
  end

  test "ours?/2 is true for the legacy form and our own host only" do
    assert Staging.ours?("k.tmp.a1b2c3d4e5f60718", "box-a")
    assert Staging.ours?("k.tmp.box-a.a1b2c3d4e5f60718", "box-a")
    refute Staging.ours?("k.tmp.box-b.a1b2c3d4e5f60718", "box-a")
    refute Staging.ours?("k", "box-a")
  end
end
```

- [ ] **Step 2: Run it to see it fail**

Run: `source /home/agent/toolchain/env.sh && cd /home/agent/repo && mix test apps/portal/test/portal/build_cache/staging_test.exs`
Expected: compile error, `Portal.BuildCache.Staging` undefined.

- [ ] **Step 3: Implement Staging**

`apps/portal/lib/portal/build_cache/staging.ex`:

```elixir
defmodule Portal.BuildCache.Staging do
  @moduledoc """
  Names for in-flight build cache entries, shared by `Portal.BuildCache.Promotion`
  (its host-side copy), `Portal.BuildCache.L2` (a download being extracted)
  and `Portal.Workers.Sweep` (which prunes what a crash left behind).

  A staging name is `<dest>.tmp.<host>.<hex>`, and the tarball a download
  is extracted from sits beside it as `<dest>.tmp.<host>.<hex>.tar.gz`. The
  host is in the name so a Sweep on one host never removes another host's
  in-flight staging when the cache root is shared, and so the `.tmp.<hex>`
  names written before the L2 work are still recognised (as having no host).
  """

  @pattern ~r/\.tmp\.(?:([A-Za-z0-9-]+)\.)?([0-9a-f]+)(\.tar\.gz)?\z/

  @doc "A fresh staging name beside `dest`."
  @spec name(Path.t()) :: Path.t()
  def name(dest),
    do: dest <> ".tmp." <> host() <> "." <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)

  @doc "This node's hostname, restricted to `[A-Za-z0-9-]`, at most 63 characters, never empty."
  @spec host() :: String.t()
  def host do
    case :inet.gethostname() do
      {:ok, name} -> name |> to_string() |> sanitize_host()
      _ -> "host"
    end
  end

  @doc false
  @spec sanitize_host(String.t()) :: String.t()
  def sanitize_host(name) do
    case name |> String.replace(~r/[^A-Za-z0-9-]/, "-") |> String.slice(0, 63) do
      "" -> "host"
      safe -> safe
    end
  end

  @doc "The host and kind of a staging name, or `:error` for any other name."
  @spec parse(String.t()) :: {:ok, %{host: String.t() | nil, download?: boolean()}} | :error
  def parse(name) do
    case Regex.run(@pattern, name) do
      [_, "", _hex] -> {:ok, %{host: nil, download?: false}}
      [_, "", _hex, _tar] -> {:ok, %{host: nil, download?: true}}
      [_, host, _hex] -> {:ok, %{host: host, download?: false}}
      [_, host, _hex, _tar] -> {:ok, %{host: host, download?: true}}
      nil -> :error
    end
  end

  @doc "Whether a staging name was written by `host` (or before hosts were recorded)."
  @spec ours?(String.t(), String.t()) :: boolean()
  def ours?(name, host) do
    case parse(name) do
      {:ok, %{host: nil}} -> true
      {:ok, %{host: ^host}} -> true
      _ -> false
    end
  end
end
```

Note `Regex.run` returns the unmatched optional group as `""`, not as a missing element, when a later group matched; check both arities as above and adjust after running the tests (the test is the oracle).

- [ ] **Step 4: Run the Staging tests**

Expected: PASS.

- [ ] **Step 5: Write the failing Tree tests**

`apps/portal/test/portal/build_cache/tree_test.exs`:

```elixir
defmodule Portal.BuildCache.TreeTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.Tree

  setup do
    dir = Path.join(System.tmp_dir!(), "tree-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "ebin"))
    File.write!(Path.join(dir, "ebin/Elixir.Jason.beam"), "beam")
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  test "a plain entry passes", %{dir: dir} do
    assert :ok = Tree.check(dir, package: "jason")
    assert :ok = Tree.check(dir, package: :any)
  end

  test "Mix's own priv link passes with the package bound or free", %{dir: dir} do
    File.ln_s!("../../../../deps/jason/priv", Path.join(dir, "priv"))
    assert :ok = Tree.check(dir, package: "jason")
    assert :ok = Tree.check(dir, package: :any)
  end

  test "a priv link to another package fails bound and passes free", %{dir: dir} do
    File.ln_s!("../../../../deps/other/priv", Path.join(dir, "priv"))
    assert {:error, reason} = Tree.check(dir, package: "jason")
    assert reason =~ "priv link"
    assert :ok = Tree.check(dir, package: :any)
  end

  test "any other symlink fails either way", %{dir: dir} do
    File.ln_s!("/etc/passwd", Path.join(dir, "ebin/x"))
    assert {:error, reason} = Tree.check(dir, package: :any)
    assert reason =~ "symlink"
  end

  test "a hardlinked pair fails", %{dir: dir} do
    File.ln!(Path.join(dir, "ebin/Elixir.Jason.beam"), Path.join(dir, "ebin/copy.beam"))
    assert {:error, reason} = Tree.check(dir, package: :any)
    assert reason =~ "hardlinked"
  end

  test "strip_modes/1 drops setuid and group/other write", %{dir: dir} do
    file = Path.join(dir, "ebin/Elixir.Jason.beam")
    File.chmod!(file, 0o4777)
    assert :ok = Tree.strip_modes(dir)
    assert Bitwise.band(File.stat!(file).mode, 0o7777) == 0o755
  end
end
```

- [ ] **Step 6: Run to see it fail, then move the walker out of Promotion**

Create `apps/portal/lib/portal/build_cache/tree.ex` by moving, verbatim, these private functions out of `promotion.ex`: `walk/3`, `check_name/4`, `name_string/1` (public, with its `@doc false`), `show/1`, `continue_if_ok/1`, `check_entry/4`, `check_link/4`, `strip_modes/1`, `strip_children/1`, `strip_child/2`, `chmod/2`, `lstat/1`, and the `@keep_mode` attribute, keeping every `# sobelow_skip` comment with them. Public surface:

```elixir
defmodule Portal.BuildCache.Tree do
  @moduledoc """
  The structural check every build cache entry passes before it becomes
  visible, and the mode stripping that follows it. Moved out of
  `Portal.BuildCache.Promotion` (its moduledoc, steps 7 and 8, explains each
  rule) so the L2 download path (`Portal.BuildCache.L2`) runs exactly the
  same code over what it extracted. `package: :any` is for that path, which
  does not know which package an entry belongs to and so accepts Mix's
  `priv`/`include` link for any package name.
  """

  @doc "Checks the tree under `dir`: directories, regular files with one link, Mix's own links."
  @spec check(Path.t(), package: String.t() | :any) :: :ok | {:error, String.t()}
  def check(dir, opts), do: walk(dir, true, Keyword.fetch!(opts, :package))

  @spec strip_modes(Path.t()) :: :ok | {:error, term()}
  def strip_modes(path) ...   # as moved

  @doc false
  def name_string(name) ...   # as moved
  @doc false
  def show(term) ...          # as moved, made public for Promotion's log lines
end
```

`check_link/4` with the package free:

```elixir
  defp check_link(path, name, true, package) when name in ["priv", "include"] do
    pkg = if package == :any, do: "[a-z][a-z0-9_]*", else: Regex.escape(package)
    allowed = ~r/\A\.\.\/\.\.\/\.\.\/\.\.\/deps(_[a-z0-9_]+)?\/#{pkg}\/(priv|include)\z/
    ...unchanged...
  end
```

In `promotion.ex`: `alias Portal.BuildCache.{Staging, Tree}`; `copy_and_check/3` calls `Tree.check(staging, package: ctx.package)`; `finish/5` calls `Tree.strip_modes(staging)`; add `defdelegate name_string(name), to: Tree` (keep its `@doc false`), and `defp show(term), do: Tree.show(term)`. Replace the default staging suffix: in `promote/6`, `staging_suffix` stays as the test seam, and `copy_check_move/3` becomes

```elixir
        staging =
          case ctx.staging_suffix do
            nil -> Staging.name(dest)
            suffix -> dest <> ".tmp." <> suffix.()
          end
```

with `ctx.staging_suffix` set to `nil` when `opts[:staging_suffix]` is nil and to `fn -> suffix end` otherwise. Update the moduledoc's step 8 sentence "`Portal.Workers.Sweep` prunes staging names a crash left behind" to "… staging names (`Portal.BuildCache.Staging`) a crash left behind, once old enough".

- [ ] **Step 7: Run Tree, Staging and Promotion tests**

Run: `mix test apps/portal/test/portal/build_cache/`
Expected: all PASS, Promotion's suite unchanged.

- [ ] **Step 8: Write the failing Sweep tests**

In `sweep_test.exs`, replace the test "removes abandoned .tmp staging trees inside a live slug" with four tests. The existing `slug/3` and `opts/2` helpers stay. Use `File.touch!(path, time)` with an old `:calendar` time to age a dir; look at how `slug/3` ages a directory with `age_hours:` and reuse that helper's approach.

```elixir
    test "removes an old abandoned staging tree of our own host and a legacy one", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 2)
      legacy = Path.join(live, "jason-1.4.1.tmp.a1b2c3d4e5f60718")
      ours = Path.join(live, "jason-1.4.1.tmp.box-a.a1b2c3d4e5f60718")
      tarball = Path.join(live, "jason-1.4.1.tmp.box-a.a1b2c3d4e5f60718.tar.gz")
      real = Path.join(live, "jason-1.4.1")
      File.mkdir_p!(legacy)
      File.mkdir_p!(ours)
      File.write!(tarball, "gz")
      File.mkdir_p!(real)
      old = System.os_time(:second) - 4 * 3600
      for p <- [legacy, ours, tarball], do: File.touch!(p, old)

      assert :ok =
               Sweep.run(
                 opts(root,
                   build_cache: cache,
                   current_digest: "sha256:0b9beb41",
                   nerves_cache: nil,
                   hex_cache: nil,
                   host: "box-a"
                 )
               )

      refute File.exists?(legacy)
      refute File.exists?(ours)
      refute File.exists?(tarball)
      assert File.exists?(real)
    end

    test "keeps a staging tree younger than the scratch max age", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 2)
      fresh = Path.join(live, "jason-1.4.1.tmp.box-a.a1b2c3d4e5f60718")
      File.mkdir_p!(fresh)

      assert :ok = Sweep.run(opts(root, build_cache: cache, current_digest: "sha256:0b9beb41", nerves_cache: nil, hex_cache: nil, host: "box-a"))

      assert File.exists?(fresh)
    end

    test "never prunes another host's staging, however old", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 2)
      theirs = Path.join(live, "jason-1.4.1.tmp.box-b.a1b2c3d4e5f60718")
      File.mkdir_p!(theirs)
      File.touch!(theirs, System.os_time(:second) - 40 * 3600)

      assert :ok = Sweep.run(opts(root, build_cache: cache, current_digest: "sha256:0b9beb41", nerves_cache: nil, hex_cache: nil, host: "box-a"))

      assert File.exists?(theirs)
    end

    test "a host name with dots is sanitised the same way on both sides", %{root: root, cache: cache} do
      live = slug(cache, "sha256_0b9beb41", age_hours: 2)
      ours = Path.join(live, "jason-1.4.1.tmp.box-home-arpa.a1b2c3d4e5f60718")
      File.mkdir_p!(ours)
      File.touch!(ours, System.os_time(:second) - 4 * 3600)

      assert :ok = Sweep.run(opts(root, build_cache: cache, current_digest: "sha256:0b9beb41", nerves_cache: nil, hex_cache: nil, host: Portal.BuildCache.Staging.sanitize_host("box.home.arpa")))

      refute File.exists?(ours)
    end
```

Check `opts/2` in the test file: if it does not pass unknown keys through, add `host` to what it forwards. Note `File.touch!/2` takes an erlang datetime or posix integer; `Sweep` must read mtime with `File.lstat(path, time: :posix)`.

- [ ] **Step 9: Implement the Sweep rule**

In `sweep.ex`, `sweep_staging/3`:

```elixir
  # Staging names (`Portal.BuildCache.Staging`): `<key>.tmp.<host>.<hex>` for
  # a promotion copy or an L2 download being extracted, plus that download's
  # `.tar.gz`, and the pre-L2 `<key>.tmp.<hex>` form. The rename that
  # publishes an entry is atomic, so a reader never sees one of these; but
  # an in-flight download can hold a staging name for several minutes, so
  # only names older than the scratch max age go, and only our own host's
  # (or the host-less legacy form): with a shared cache root, another host's
  # in-flight staging is theirs to finish.
  defp sweep_staging(root, slugs, opts) do
    now = Keyword.get_lazy(opts, :now_ms, &now_ms/0)
    max_age = Keyword.get(opts, :max_age_ms, configured_max_age_ms())
    host = Keyword.get_lazy(opts, :host, &Staging.host/0)

    slugs
    |> Enum.flat_map(fn slug ->
      dir = Path.join(root, slug)

      case list_dir(dir) do
        {:ok, entries} ->
          entries
          |> Enum.filter(&Staging.ours?(&1, host))
          |> Enum.map(&Path.join(dir, &1))
          |> Enum.filter(&staging_stale?(&1, now, max_age))

        _ ->
          []
      end
    end)
    |> delete_all(opts, "build-cache staging")
  end

  # lstat, never stat: a symlink planted under a staging name must not be
  # followed to decide anything.
  # `path` is a name under the operator's cache root.
  # sobelow_skip ["Traversal.FileModule"]
  defp staging_stale?(path, now, max_age) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> now - mtime * 1000 > max_age
      {:error, _reason} -> false
    end
  end
```

Add `alias Portal.BuildCache.Staging`, drop `@staging_pattern`, add `:host` to the `run/1` doc's option list, and add a moduledoc paragraph (the comment above, in prose) under the `.tmp.<hex>` bullet. Check `delete_all/3` removes files as well as directories (it must handle the `.tar.gz`; if it uses `File.rm_rf/1` it does).

- [ ] **Step 10: Run the Sweep, Promotion, Tree and Staging tests, then the portal suite**

Run: `mix test apps/portal/test/portal/workers/sweep_test.exs apps/portal/test/portal/build_cache/` then `mix test apps/portal/test/`
Expected: PASS.

- [ ] **Step 11: Format, compile with warnings as errors, commit**

```bash
mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal/build_cache/staging.ex apps/portal/lib/portal/build_cache/tree.ex apps/portal/lib/portal/build_cache/promotion.ex apps/portal/lib/portal/workers/sweep.ex apps/portal/test/portal/build_cache/staging_test.exs apps/portal/test/portal/build_cache/tree_test.exs apps/portal/test/portal/workers/sweep_test.exs
git commit -m "Build cache: shared Tree walker, host-qualified staging names, Sweep age bound

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 2: L2 config, stats table, runtime env, boot line

**Files:**
- Create: `apps/portal/lib/portal/build_cache/l2/config.ex`
- Create: `apps/portal/lib/portal/build_cache/l2/stats.ex`
- Create: `apps/portal/lib/portal/build_cache/l2.ex` (skeleton: `enabled?/0`, `object_key/2`, `status/0`, `log_state/0`; `upload/4` and `prefetch/3` come in Tasks 6 and 7)
- Modify: `config/runtime.exs` (after the `builder_env` block's `config :portal, Portal.Builder, ...`)
- Modify: `apps/portal/lib/portal/application.ex` (child, boot line)
- Test: `apps/portal/test/portal/build_cache/l2/config_test.exs`, `apps/portal/test/portal/build_cache/l2/stats_test.exs`, `apps/portal/test/portal/build_cache/l2_test.exs` (status/enabled?)

**Interfaces:**
- Produces: `%Portal.BuildCache.L2.Config{endpoint, bucket, region, access_key, secret_key, read_only?}`; `Config.config(env :: keyword()) :: {:ok, %Config{}} | :off | {:error, String.t()}`; `Config.config() :: same` from `Application.get_env(:portal, Portal.BuildCache.L2, [])`.
- Produces: `Stats.record(event, bytes \\ 0)` with `event in [:upload_ok, :upload_failed, :download_ok, :download_failed, :refused, :discarded, :list_failed]`; `Stats.snapshot() :: %{uploads, upload_failures, downloads, download_failures, refused, discarded, list_failures, bytes_up, bytes_down, last_upload: DateTime | nil, last_download: DateTime | nil}`; `Stats.claim(key) :: boolean`; `Stats.release(key) :: :ok`; `Stats.mark_bad(key) :: :ok`; `Stats.bad?(key) :: boolean`; `Stats.reset() :: :ok`.
- Produces: `L2.enabled?() :: boolean`; `L2.object_key(slug, key) :: String.t()`; `L2.status() :: map` (spec 4.7); `L2.log_state() :: :ok`.

- [ ] **Step 1: Failing Config tests**

```elixir
defmodule Portal.BuildCache.L2.ConfigTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Config

  @full [endpoint: "http://100.64.0.2:3900", bucket: "ncc-build-cache", region: "garage", access_key: "GK1", secret_key: "s"]

  test "a full config is on" do
    assert {:ok, %Config{endpoint: "http://100.64.0.2:3900", bucket: "ncc-build-cache", region: "garage", read_only?: false}} = Config.config(@full)
  end

  test "no endpoint is off" do
    assert :off = Config.config([])
    assert :off = Config.config(endpoint: "", bucket: "b")
    assert :off = Config.config(endpoint: nil, bucket: "b", access_key: "a", secret_key: "s")
  end

  test "an endpoint with anything missing is an error, not off" do
    assert {:error, msg} = Config.config(Keyword.delete(@full, :bucket))
    assert msg =~ "NCC_BUILD_CACHE_S3_BUCKET"
    assert {:error, _} = Config.config(Keyword.put(@full, :secret_key, ""))
  end

  test "the endpoint must be an http(s) URL with a host and no path" do
    assert {:error, msg} = Config.config(Keyword.put(@full, :endpoint, "100.64.0.2:3900"))
    assert msg =~ "endpoint"
    assert {:error, _} = Config.config(Keyword.put(@full, :endpoint, "http://100.64.0.2:3900/bucket"))
    assert {:ok, %Config{endpoint: "https://garage.example"}} = Config.config(Keyword.put(@full, :endpoint, "https://garage.example/"))
  end

  test "region defaults to garage and read_only reads the flag" do
    assert {:ok, %Config{region: "garage"}} = Config.config(Keyword.delete(@full, :region))
    assert {:ok, %Config{read_only?: true}} = Config.config(Keyword.put(@full, :read_only, true))
  end
end
```

- [ ] **Step 2: Implement Config**

```elixir
defmodule Portal.BuildCache.L2.Config do
  @moduledoc """
  The L2 build cache's connection settings, from `config :portal,
  Portal.BuildCache.L2` (which `config/runtime.exs` fills from the
  `NCC_BUILD_CACHE_S3_*` env). No endpoint means off. An endpoint with any
  other required value missing is an error the caller logs once at boot and
  then treats as off: a half-configured cache must not look like a working
  one.
  """

  @enforce_keys [:endpoint, :bucket, :region, :access_key, :secret_key]
  defstruct [:endpoint, :bucket, :region, :access_key, :secret_key, read_only?: false]

  @type t :: %__MODULE__{endpoint: String.t(), bucket: String.t(), region: String.t(), access_key: String.t(), secret_key: String.t(), read_only?: boolean()}

  @spec config(keyword()) :: {:ok, t()} | :off | {:error, String.t()}
  def config(env \\ Application.get_env(:portal, Portal.BuildCache.L2, [])) do
    case present(env[:endpoint]) do
      nil -> :off
      endpoint -> build(endpoint, env)
    end
  end

  defp build(endpoint, env) do
    with {:ok, endpoint} <- parse_endpoint(endpoint),
         {:ok, bucket} <- required(env, :bucket, "NCC_BUILD_CACHE_S3_BUCKET"),
         {:ok, access_key} <- required(env, :access_key, "NCC_BUILD_CACHE_S3_ACCESS_KEY"),
         {:ok, secret_key} <- required(env, :secret_key, "NCC_BUILD_CACHE_S3_SECRET_KEY") do
      {:ok, %__MODULE__{endpoint: endpoint, bucket: bucket, region: present(env[:region]) || "garage", access_key: access_key, secret_key: secret_key, read_only?: env[:read_only] == true}}
    end
  end

  defp required(env, key, var) do
    case present(env[key]) do
      nil -> {:error, "build cache L2: #{var} is required when the endpoint is set"}
      value -> {:ok, value}
    end
  end

  defp parse_endpoint(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: scheme, host: host, path: path, query: nil}} when scheme in ["http", "https"] and is_binary(host) and host != "" and path in [nil, "", "/"] ->
        {:ok, String.trim_trailing(url, "/")}
      _ -> {:error, "build cache L2: endpoint must be http(s)://host[:port] with no path, got #{inspect(url)}"}
    end
  end

  defp present(nil), do: nil
  defp present(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: String.trim(value))
  defp present(_), do: nil
end
```

- [ ] **Step 3: Failing Stats tests**

```elixir
defmodule Portal.BuildCache.L2.StatsTest do
  use ExUnit.Case, async: false

  alias Portal.BuildCache.L2.Stats

  setup do
    Stats.reset()
    :ok
  end

  test "counts events and bytes and remembers the last success" do
    assert Stats.snapshot().uploads == 0
    Stats.record(:upload_ok, 10)
    Stats.record(:upload_failed)
    Stats.record(:download_ok, 7)
    Stats.record(:refused)
    s = Stats.snapshot()
    assert %{uploads: 1, upload_failures: 1, downloads: 1, refused: 1, bytes_up: 10, bytes_down: 7} = s
    assert %DateTime{} = s.last_upload
    assert %DateTime{} = s.last_download
  end

  test "a claim is exclusive until released, and a dead claimant does not hold it" do
    assert Stats.claim("k")
    refute Stats.claim("k")
    Stats.release("k")
    assert Stats.claim("k")
    Stats.release("k")

    {:ok, pid} = Task.start(fn -> Stats.claim("dead") end)
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, _, _, _}
    assert Stats.claim("dead")
  end

  test "a bad key stays bad for a day" do
    refute Stats.bad?("k")
    Stats.mark_bad("k")
    assert Stats.bad?("k")
    refute Stats.bad?("k", System.system_time(:millisecond) + :timer.hours(25))
  end

  test "every call survives the table being absent" do
    :ets.delete(:ncc_build_cache_l2)
    assert :ok = Stats.record(:upload_ok, 1)
    refute Stats.claim("k")
    refute Stats.bad?("k")
    assert Stats.snapshot().uploads == 0
    # Restart the owner so later tests have the table.
    Supervisor.terminate_child(Portal.Supervisor, Stats)
    Supervisor.restart_child(Portal.Supervisor, Stats)
  end
end
```

- [ ] **Step 4: Implement Stats**

A GenServer owning a public named ETS set `:ncc_build_cache_l2`. Rows: `{:counter, name}` → integer, `{:last, :upload | :download}` → unix ms, `{:claim, key}` → pid, `{:bad, key}` → until ms. Every public function wraps its ETS call in `try ... rescue ArgumentError -> default`. `claim/1` uses `:ets.insert_new`; on failure it reads the holder and, if `Process.alive?` is false, deletes and retries once. `bad?/2` takes `now_ms` as the second argument defaulting to `System.system_time(:millisecond)`. `mark_bad/1` stores `now + :timer.hours(24)`. `snapshot/0` builds the map from counters with zero defaults and converts the `:last` rows with `DateTime.from_unix!(ms, :millisecond)`. `reset/0` is `:ets.delete_all_objects`. `start_link/1` registers under the module name; `child_spec` default.

- [ ] **Step 5: Wire runtime config, the child and the boot line**

`config/runtime.exs`, right after the `config :portal, Portal.Builder, builder_env` line (find it; it follows the `builder_env = [...]` block):

```elixir
  # The shared S3 layer behind the build cache (`Portal.BuildCache.L2`).
  # Unset endpoint: off. Every other value is required once it is set.
  config :portal, Portal.BuildCache.L2,
    endpoint: System.get_env("NCC_BUILD_CACHE_S3_ENDPOINT"),
    bucket: System.get_env("NCC_BUILD_CACHE_S3_BUCKET"),
    region: System.get_env("NCC_BUILD_CACHE_S3_REGION"),
    access_key: System.get_env("NCC_BUILD_CACHE_S3_ACCESS_KEY"),
    secret_key: System.get_env("NCC_BUILD_CACHE_S3_SECRET_KEY"),
    read_only: System.get_env("NCC_BUILD_CACHE_S3_READ_ONLY") == "1"
```

`application.ex`: add `Portal.BuildCache.L2.Stats,` to `children` right before the `{Oban, ...}` entry with a comment ("Owns the ETS table of L2 build cache counters and in-flight claims; before Oban, whose build jobs write it."). In `start/2`, after `:ok = start_boot_egress_check()`, add `:ok = Portal.BuildCache.L2.log_state()`.

`l2.ex` skeleton:

```elixir
defmodule Portal.BuildCache.L2 do
  @moduledoc """
  The second, shared layer of the dependency build cache: an S3 bucket
  every home build host reads before a build and writes after a promotion.
  (Full moduledoc in Task 7: what is fetched and why it is trusted; see the
  spec, sections 3.1 and 5.)
  """
  require Logger
  alias Portal.BuildCache.L2.{Config, Stats}

  @spec object_key(String.t(), String.t()) :: String.t()
  def object_key(slug, key), do: slug <> "/" <> key <> ".tar.gz"

  @doc "On only with a complete config and a local cache to restore into."
  @spec enabled?() :: boolean()
  def enabled?, do: match?({:ok, _}, Config.config()) and Portal.Builder.build_cache() != nil

  @spec status() :: map()
  def status do
    base = %{node: Portal.BuildCache.Staging.host(), endpoint: nil, bucket: nil, read_only?: false}
    {state, base} =
      case Config.config() do
        {:ok, cfg} -> {:on, %{base | endpoint: cfg.endpoint, bucket: cfg.bucket, read_only?: cfg.read_only?}}
        :off -> {:off, base}
        {:error, _} -> {:incomplete, base}
      end
    snap = Stats.snapshot()
    base |> Map.put(:state, state) |> Map.put(:last_upload, snap.last_upload) |> Map.put(:last_download, snap.last_download) |> Map.put(:counters, Map.drop(snap, [:last_upload, :last_download]))
  end

  @spec log_state() :: :ok
  def log_state do
    case Config.config() do
      {:ok, cfg} -> Logger.info("Build cache L2 on: #{cfg.endpoint}/#{cfg.bucket}#{if cfg.read_only?, do: " (read-only)", else: ""}")
      :off -> Logger.info("Build cache L2 off")
      {:error, msg} -> Logger.warning("Build cache L2 off: #{msg}")
    end
    :ok
  end
end
```

Tests in `l2_test.exs`: `status/0` reports `:off` with the default test config, `:on` with endpoint/bucket after `Application.put_env(:portal, Portal.BuildCache.L2, [...])` (restore in `on_exit`), `:incomplete` with an endpoint alone; `enabled?/0` is false when `Portal.Builder` has no `build_cache` even with a full config; `log_state/0` logs the three lines (`capture_log`).

- [ ] **Step 6: Run, format, compile, commit**

Run: `mix test apps/portal/test/portal/build_cache/` then `mix test apps/portal/test/`.

```bash
git add config/runtime.exs apps/portal/lib/portal/application.ex apps/portal/lib/portal/build_cache/l2.ex apps/portal/lib/portal/build_cache/l2/ apps/portal/test/portal/build_cache/
git commit -m "Build cache L2: config from env, per-node stats table, boot line

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 3: Tarball pack and unpack with the structural rules

**Files:**
- Create: `apps/portal/lib/portal/build_cache/l2/tarball.ex`
- Test: `apps/portal/test/portal/build_cache/l2/tarball_test.exs`

**Interfaces:**
- Consumes: `Portal.BuildCache.Tree.check/2`, `Tree.strip_modes/1`, `Tree.name_string/1`.
- Produces: `Tarball.pack(entry_dir, tar_path, package :: String.t() | :any) :: {:ok, %{sha256: String.t(), bytes: non_neg_integer()}} | {:error, term()}`; `Tarball.unpack(tar_path, staging_dir) :: :ok | {:error, term()}`; `Tarball.sha256_file(path) :: String.t()` (lowercase hex); `Tarball.max_object_bytes() :: 536_870_912`.

- [ ] **Step 1: Failing tests**

```elixir
defmodule Portal.BuildCache.L2.TarballTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Tarball

  setup do
    tmp = Path.join(System.tmp_dir!(), "tarball-#{System.unique_integer([:positive])}")
    entry = Path.join(tmp, "entry")
    File.mkdir_p!(Path.join(entry, "ebin"))
    File.mkdir_p!(Path.join(entry, ".mix"))
    File.write!(Path.join(entry, "ebin/Elixir.Jason.beam"), "beam")
    File.write!(Path.join(entry, ".mix/compile.elixir_scm"), "scm")
    File.ln_s!("../../../../deps/jason/priv", Path.join(entry, "priv"))
    on_exit(fn -> File.rm_rf(tmp) end)
    %{tmp: tmp, entry: entry, tar: Path.join(tmp, "e.tar.gz"), out: Path.join(tmp, "out")}
  end

  defp listing(dir) do
    dir |> Path.join("**") |> Path.wildcard(match_dot: true) |> Enum.map(&Path.relative_to(&1, dir)) |> Enum.sort()
  end

  test "round trip keeps files, dot dirs and Mix's link", %{entry: entry, tar: tar, out: out} do
    assert {:ok, %{sha256: sha, bytes: bytes}} = Tarball.pack(entry, tar, "jason")
    assert bytes == File.stat!(tar).size
    assert sha == Tarball.sha256_file(tar)
    File.mkdir_p!(out)
    assert :ok = Tarball.unpack(tar, out)
    assert listing(out) == listing(entry)
    assert File.read_link!(Path.join(out, "priv")) == "../../../../deps/jason/priv"
    assert File.read!(Path.join(out, "ebin/Elixir.Jason.beam")) == "beam"
  end

  test "pack refuses a priv link to another package when the package is bound, not when free", %{entry: entry, tar: tar} do
    File.rm!(Path.join(entry, "priv"))
    File.ln_s!("../../../../deps/other/priv", Path.join(entry, "priv"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
    assert {:ok, _} = Tarball.pack(entry, tar, :any)
  end

  test "pack refuses a hardlink and a foreign symlink", %{entry: entry, tar: tar} do
    File.ln!(Path.join(entry, "ebin/Elixir.Jason.beam"), Path.join(entry, "ebin/dup.beam"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
    File.rm!(Path.join(entry, "ebin/dup.beam"))
    File.ln_s!("/etc/hostname", Path.join(entry, "ebin/evil"))
    assert {:error, _} = Tarball.pack(entry, tar, "jason")
  end

  # Archives built by hand with erl_tar, the way a hostile uploader would.
  defp hostile(tmp, members) do
    path = Path.join(tmp, "hostile-#{System.unique_integer([:positive])}.tar.gz")
    {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
    for {name, content} <- members, do: :ok = :erl_tar.add(tar, content, String.to_charlist(name), [])
    :ok = :erl_tar.close(tar)
    path
  end

  test "unpack refuses a ../ member", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    assert {:error, reason} = Tarball.unpack(hostile(tmp, [{"../escape", "x"}]), out)
    assert inspect(reason) =~ "escape"
    refute File.exists?(Path.join(tmp, "escape"))
  end

  test "unpack refuses an absolute member", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    assert {:error, _} = Tarball.unpack(hostile(tmp, [{"/tmp/abs", "x"}]), out)
  end

  test "unpack refuses a symlink that leaves the entry", %{tmp: tmp, out: out, entry: entry, tar: tar} do
    File.rm!(Path.join(entry, "priv"))
    File.ln_s!("../../other", Path.join(entry, "priv"))
    # Build the archive without the check so the refusal happens on unpack.
    :ok = :erl_tar.create(String.to_charlist(tar), [{~c"priv", String.to_charlist(Path.join(entry, "priv"))}, {~c"ebin", String.to_charlist(Path.join(entry, "ebin"))}], [:compressed])
    File.mkdir_p!(out)
    assert {:error, _} = Tarball.unpack(tar, out)
  end

  test "unpack refuses a hard link, a device and a fifo entry", %{tmp: tmp, out: out} do
    # erl_tar cannot write those types; craft the header bytes directly.
    for typeflag <- [?1, ?3, ?6] do
      path = Path.join(tmp, "typed-#{typeflag}.tar.gz")
      File.write!(path, :zlib.gzip(ustar_entry("ebin/x", typeflag)))
      File.mkdir_p!(out)
      assert {:error, _} = Tarball.unpack(path, out)
      File.rm_rf!(out)
    end
  end

  test "unpack refuses an empty archive and an archive that is not gzip", %{tmp: tmp, out: out} do
    File.mkdir_p!(out)
    empty = Path.join(tmp, "empty.tar.gz")
    File.write!(empty, :zlib.gzip(:binary.copy(<<0>>, 1024)))
    assert {:error, _} = Tarball.unpack(empty, out)
    junk = Path.join(tmp, "junk.tar.gz")
    File.write!(junk, "not a tarball")
    assert {:error, _} = Tarball.unpack(junk, out)
  end

  test "unpack refuses a truncated archive", %{entry: entry, tar: tar, tmp: tmp, out: out} do
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    bytes = File.read!(tar)
    cut = Path.join(tmp, "cut.tar.gz")
    File.write!(cut, binary_part(bytes, 0, div(byte_size(bytes), 2)))
    File.mkdir_p!(out)
    assert {:error, _} = Tarball.unpack(cut, out)
  end

  test "unpack strips modes", %{entry: entry, tar: tar, out: out} do
    File.chmod!(Path.join(entry, "ebin/Elixir.Jason.beam"), 0o4777)
    {:ok, _} = Tarball.pack(entry, tar, "jason")
    File.mkdir_p!(out)
    assert :ok = Tarball.unpack(tar, out)
    assert Bitwise.band(File.stat!(Path.join(out, "ebin/Elixir.Jason.beam")).mode, 0o7777) == 0o755
  end

  # A single 512-byte ustar header with no data, for a type erl_tar will not write.
  defp ustar_entry(name, typeflag) do
    name = String.pad_trailing(name, 100, <<0>>)
    mode = "0000644\0"
    uid = "0000000\0"
    gid = "0000000\0"
    size = "00000000000\0"
    mtime = "00000000000\0"
    rest = <<typeflag>> <> String.pad_trailing("", 100, <<0>>) <> "ustar\0" <> "00" <> String.pad_trailing("", 32 + 32 + 8 + 8 + 155, <<0>>)
    unsigned = name <> mode <> uid <> gid <> size <> mtime <> "        " <> rest
    chksum = unsigned |> :binary.bin_to_list() |> Enum.sum()
    header = name <> mode <> uid <> gid <> size <> mtime <> (chksum |> Integer.to_string(8) |> String.pad_leading(6, "0")) <> <<0, ?\s>> <> rest
    header = String.pad_trailing(header, 512, <<0>>)
    header <> :binary.copy(<<0>>, 1024)
  end
end
```

If `ustar_entry/2` needs adjusting to produce a header `:erl_tar.table/2` reads (run `:erl_tar.table/2` on it in iex to check it reports `link`/`char`/`fifo`), adjust the helper, not the assertion.

- [ ] **Step 2: Implement Tarball**

```elixir
defmodule Portal.BuildCache.L2.Tarball do
  @moduledoc """
  One build cache entry as a gzip tarball, and back.

  `pack/3` is what a home host uploads after a promotion; `unpack/2` is what
  it extracts before a build. Both ends apply the same structural rules as
  `Portal.BuildCache.Promotion` (through `Portal.BuildCache.Tree`): only
  directories, regular files with one link, and Mix's own top-level
  `priv`/`include` links. On the way in the tar table is screened before a
  single byte is extracted: `:erl_tar` refuses escaping paths and symlinks
  itself (`safe_relative_path`) and ignores hard-link entries, but writes
  device and fifo entries as empty regular files, which the walk afterwards
  could not tell from real ones. gzip rather than zstd so the portal needs
  no NIF for a few megabytes per entry (spec, section 3.2).
  """

  alias Portal.BuildCache.Tree

  @max_object_bytes 512 * 1024 * 1024
  @max_depth 64
  @allowed_types [:regular, :directory, :symlink]

  @spec max_object_bytes() :: pos_integer()
  def max_object_bytes, do: @max_object_bytes

  # `entry_dir` is a promoted entry under the operator's cache root;
  # `tar_path` its sibling staging name.
  # sobelow_skip ["Traversal.FileModule"]
  @spec pack(Path.t(), Path.t(), String.t() | :any) :: {:ok, %{sha256: String.t(), bytes: non_neg_integer()}} | {:error, term()}
  def pack(entry_dir, tar_path, package) do
    with :ok <- Tree.check(entry_dir, package: package),
         {:ok, names} <- top_level(entry_dir),
         :ok <- create(tar_path, Enum.map(names, &{String.to_charlist(&1), String.to_charlist(Path.join(entry_dir, &1))})),
         {:ok, %File.Stat{size: bytes}} <- File.stat(tar_path),
         :ok <- bounded(bytes) do
      {:ok, %{sha256: sha256_file(tar_path), bytes: bytes}}
    else
      {:error, _} = error ->
        _ = File.rm(tar_path)
        error
    end
  end

  defp top_level(dir) do
    case :file.list_dir_all(dir) do
      {:ok, []} -> {:error, :empty_entry}
      {:ok, raw} -> Enum.reduce_while(raw, {:ok, []}, fn name, {:ok, acc} ->
          case Tree.name_string(name) do
            {:ok, s} -> {:cont, {:ok, [s | acc]}}
            :error -> {:halt, {:error, {:bad_name, name}}}
          end
        end)
      {:error, reason} -> {:error, {:list, reason}}
    end
  end

  defp create(tar_path, members) do
    case :erl_tar.create(String.to_charlist(tar_path), members, [:compressed]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp bounded(bytes) when bytes > @max_object_bytes, do: {:error, :too_large}
  defp bounded(_), do: :ok

  # `tar_path` and `staging_dir` are host-built staging names under the slug.
  # sobelow_skip ["Traversal.FileModule"]
  @spec unpack(Path.t(), Path.t()) :: :ok | {:error, term()}
  def unpack(tar_path, staging_dir) do
    with {:ok, table} <- table(tar_path),
         :ok <- screen(table),
         :ok <- extract(tar_path, staging_dir),
         :ok <- Tree.check(staging_dir, package: :any) |> refusal(),
         :ok <- Tree.strip_modes(staging_dir) do
      :ok
    end
  end

  defp table(tar_path) do
    case :erl_tar.table(String.to_charlist(tar_path), [:compressed, :verbose]) do
      {:ok, []} -> {:error, :empty_archive}
      {:ok, entries} -> {:ok, entries}
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp screen(entries) do
    Enum.reduce_while(entries, :ok, fn {name, type, _size, _mtime, _mode, _uid, _gid}, :ok ->
      cond do
        type not in @allowed_types -> {:halt, {:error, {:member_type, type, safe_show(name)}}}
        not safe_member_name?(name, type) -> {:halt, {:error, {:member_name, safe_show(name)}}}
        true -> {:cont, :ok}
      end
    end)
  end

  # The name as erl_tar reports it, a charlist; refused unless it is UTF-8,
  # relative, free of empty, `.` and `..` components and NULs, and shallow.
  defp safe_member_name?(raw, type) do
    with {:ok, name} <- to_utf8(raw) do
      name = if type == :directory, do: String.trim_trailing(name, "/"), else: name
      parts = String.split(name, "/")
      name != "" and not String.starts_with?(name, "/") and not String.contains?(name, <<0>>) and length(parts) <= @max_depth and Enum.all?(parts, &(&1 not in ["", ".", ".."]))
    else
      _ -> false
    end
  end

  defp to_utf8(raw) when is_list(raw) do
    case :unicode.characters_to_binary(raw) do
      bin when is_binary(bin) -> if String.valid?(bin), do: {:ok, bin}, else: :error
      _ -> :error
    end
  end
  defp to_utf8(raw) when is_binary(raw), do: if(String.valid?(raw), do: {:ok, raw}, else: :error)

  defp safe_show(raw), do: inspect(raw, printable_limit: 200)

  defp extract(tar_path, staging_dir) do
    case :erl_tar.extract(String.to_charlist(tar_path), [:compressed, {:cwd, String.to_charlist(staging_dir)}]) do
      :ok -> :ok
      {:error, reason} -> {:error, {:tar, reason}}
    end
  end

  defp refusal(:ok), do: :ok
  defp refusal({:error, reason}), do: {:error, {:structure, reason}}

  @spec sha256_file(Path.t()) :: String.t()
  # sobelow_skip ["Traversal.FileModule"]
  def sha256_file(path) do
    path
    |> File.stream!([], 1024 * 1024)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
```

`:erl_tar.table/2` with `:verbose` returns 7-tuples; confirm the exact shape in iex on a packed archive before trusting the pattern, and confirm it reports `symlink` for the `priv` link and `directory` for `ebin`. If the type atoms differ from `@allowed_types`, fix the atoms (and leave the tests alone).

- [ ] **Step 3: Run tests, format, compile, commit**

```bash
mix test apps/portal/test/portal/build_cache/l2/tarball_test.exs && mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal/build_cache/l2/tarball.ex apps/portal/test/portal/build_cache/l2/tarball_test.exs
git commit -m "Build cache L2: tarball pack and unpack with the entry's structural rules

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 4: The in-process S3 stub with an independent SigV4 verifier

**Files:**
- Create: `apps/portal/test/support/fake_s3.ex` (modules `Portal.Test.FakeS3`, `Portal.Test.FakeS3.Plug`, `Portal.Test.FakeS3.SigV4`)
- Test: `apps/portal/test/portal/build_cache/l2/fake_s3_test.exs`

Check `apps/portal/mix.exs` `elixirc_paths(:test)` includes `test/support` (it does for the other support modules).

**Interfaces:**
- Produces: `FakeS3.start(opts \\ []) :: {:ok, s}` where `s` is `%{pid, port, endpoint: "http://127.0.0.1:<port>", bucket: "ncc-test", region: "garage", access_key: "GKTEST", secret_key: "secret-test", config: %Portal.BuildCache.L2.Config{}}` (config built from those values, `read_only?: false`); starts Bandit on port 0 and an Agent for state, both linked to the caller (ExUnit cleans up).
- `FakeS3.put_object(s, key, body, meta \\ %{})`, `FakeS3.get_object(s, key) :: {:ok, %{body, meta: %{String.t() => String.t()}}} | :error`, `FakeS3.objects(s) :: [key]`, `FakeS3.delete_object(s, key)`.
- `FakeS3.set_fault(s, fault)` with `fault` one of `nil`, `{:get, :truncate}` (serve the first half of the body as a chunked response), `{:get, :status, 500}`, `{:put, :status, 503}`, `{:list, :status, 500}`, `{:list, :no_token}` (page 1 truncated, no continuation token).
- `FakeS3.on_get(s, fun)` — `fun.(key)` is called before a GET is answered (nil clears).
- `FakeS3.requests(s) :: [{method, path, query}]` for assertions on what the client did.
- `FakeS3.SigV4.verify(conn, access_key, secret_key, region) :: :ok | {:error, String.t()}`; `FakeS3.SigV4.signature(%{method, path, query: [{k, v}], headers: [{k, v}], payload_hash, amz_date, region, service, secret_key}) :: String.t()` (lowercase hex).

- [ ] **Step 1: Failing SigV4 vector tests**

```elixir
defmodule Portal.Test.FakeS3Test do
  use ExUnit.Case, async: true

  alias Portal.Test.FakeS3
  alias Portal.Test.FakeS3.SigV4

  @empty "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  # AWS SigV4 test suite, get-vanilla.
  test "signs the get-vanilla vector" do
    sig =
      SigV4.signature(%{
        method: "GET",
        path: "/",
        query: [],
        headers: [{"host", "example.amazonaws.com"}, {"x-amz-date", "20150830T123600Z"}],
        payload_hash: @empty,
        amz_date: "20150830T123600Z",
        region: "us-east-1",
        service: "service",
        secret_key: "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
      })

    assert sig == "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31"
  end

  # Amazon S3 API reference, "Signature Calculations ... Examples", GET object.
  test "signs the S3 GET object example" do
    sig =
      SigV4.signature(%{
        method: "GET",
        path: "/test.txt",
        query: [],
        headers: [
          {"host", "examplebucket.s3.amazonaws.com"},
          {"range", "bytes=0-9"},
          {"x-amz-content-sha256", @empty},
          {"x-amz-date", "20130524T000000Z"}
        ],
        payload_hash: @empty,
        amz_date: "20130524T000000Z",
        region: "us-east-1",
        service: "s3",
        secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
      })

    assert sig == "f0e8bdb87c964420e857bd35b5d6ed310bd44f0170aba48dd91039c6036bdb41"
  end

  test "the stub refuses an unsigned request and serves a signed round trip" do
    {:ok, s} = FakeS3.start()
    assert {:ok, %{status: 403}} = Req.get("#{s.endpoint}/#{s.bucket}/x", retry: false)
    sigv4 = [access_key_id: s.access_key, secret_access_key: s.secret_key, service: :s3, region: s.region]
    assert {:ok, %{status: 200}} = Req.put("#{s.endpoint}/#{s.bucket}/a/b.tar.gz", body: "hello", headers: [{"x-amz-meta-sha256", "abc"}], aws_sigv4: sigv4, retry: false)
    assert {:ok, %{status: 200, body: "hello"} = resp} = Req.get("#{s.endpoint}/#{s.bucket}/a/b.tar.gz", aws_sigv4: sigv4, retry: false)
    assert Req.Response.get_header(resp, "x-amz-meta-sha256") == ["abc"]
    assert {:ok, %{status: 200}} = Req.head("#{s.endpoint}/#{s.bucket}/a/b.tar.gz", aws_sigv4: sigv4, retry: false)
    assert {:ok, %{status: 404}} = Req.get("#{s.endpoint}/#{s.bucket}/missing", aws_sigv4: sigv4, retry: false)
    assert {:ok, %{status: 200, body: body}} = Req.get("#{s.endpoint}/#{s.bucket}", params: [{"list-type", "2"}, {"prefix", "a/"}], aws_sigv4: sigv4, retry: false)
    assert body =~ "<Key>a/b.tar.gz</Key>"
    assert body =~ "<Size>5</Size>"
    wrong = Keyword.put(sigv4, :secret_access_key, "nope")
    assert {:ok, %{status: 403}} = Req.get("#{s.endpoint}/#{s.bucket}/a/b.tar.gz", aws_sigv4: wrong, retry: false)
  end
end
```

If a vector does not match, do not edit the expected signature: re-derive the canonical request against the AWS documentation for that example and fix the verifier. The two secrets differ (`+` vs `/`) on purpose; copy them exactly.

- [ ] **Step 2: Implement SigV4**

```elixir
defmodule Portal.Test.FakeS3.SigV4 do
  @moduledoc "An independent AWS Signature Version 4 verifier for the stub; see the spec, section 3.3."

  def signature(%{method: method, path: path, query: query, headers: headers, payload_hash: payload_hash, amz_date: amz_date, region: region, service: service, secret_key: secret}) do
    headers = headers |> Enum.map(fn {k, v} -> {String.downcase(k), String.trim(v)} end) |> Enum.sort()
    signed = Enum.map_join(headers, ";", &elem(&1, 0))
    canonical_headers = Enum.map_join(headers, "", fn {k, v} -> k <> ":" <> v <> "\n" end)
    canonical_query = query |> Enum.map(fn {k, v} -> {encode(k), encode(v)} end) |> Enum.sort() |> Enum.map_join("&", fn {k, v} -> k <> "=" <> v end)
    canonical = Enum.join([method, path, canonical_query, canonical_headers, signed, payload_hash], "\n")
    date = binary_part(amz_date, 0, 8)
    scope = Enum.join([date, region, service, "aws4_request"], "/")
    string_to_sign = Enum.join(["AWS4-HMAC-SHA256", amz_date, scope, hex(:crypto.hash(:sha256, canonical))], "\n")
    key = "AWS4" <> secret
    key = hmac(key, date)
    key = hmac(key, region)
    key = hmac(key, service)
    key = hmac(key, "aws4_request")
    hex(hmac(key, string_to_sign))
  end

  @doc "Checks the Authorization header of `conn` against the request it carries."
  def verify(conn, access_key, secret_key, region) do
    with [auth] <- Plug.Conn.get_req_header(conn, "authorization"),
         {:ok, parts} <- parse_auth(auth),
         ^access_key <- parts.access_key,
         [amz_date] <- Plug.Conn.get_req_header(conn, "x-amz-date"),
         [payload_hash] <- Plug.Conn.get_req_header(conn, "x-amz-content-sha256"),
         :ok <- check_payload(conn, payload_hash) do
      headers = for name <- parts.signed_headers, do: {name, conn |> Plug.Conn.get_req_header(name) |> Enum.join(",")}
      query = conn.query_string |> URI.query_decoder() |> Enum.to_list()
      expected = signature(%{method: conn.method, path: conn.request_path, query: query, headers: headers, payload_hash: payload_hash, amz_date: amz_date, region: region, service: "s3", secret_key: secret_key})
      if Plug.Crypto.secure_compare(expected, parts.signature), do: :ok, else: {:error, "signature mismatch"}
    else
      [] -> {:error, "no authorization"}
      other -> {:error, "bad authorization: #{inspect(other)}"}
    end
  end

  # The body was read into conn.assigns[:body] by the stub's plug before verifying.
  defp check_payload(_conn, "UNSIGNED-PAYLOAD"), do: :ok
  defp check_payload(conn, hash) do
    body = conn.assigns[:body] || ""
    if hex(:crypto.hash(:sha256, body)) == hash, do: :ok, else: {:error, "payload hash mismatch"}
  end

  defp parse_auth("AWS4-HMAC-SHA256 " <> rest) do
    fields = rest |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.map(&String.split(&1, "=", parts: 2)) |> Map.new(fn [k, v] -> {k, v} end)
    with "Credential=" <> _ <- "Credential=" <> (fields["Credential"] || ""),
         [access_key | _] <- String.split(fields["Credential"] || "", "/"),
         signed when is_binary(signed) <- fields["SignedHeaders"],
         sig when is_binary(sig) <- fields["Signature"] do
      {:ok, %{access_key: access_key, signed_headers: String.split(signed, ";"), signature: sig}}
    else
      _ -> {:error, "unparseable"}
    end
  end
  defp parse_auth(_), do: {:error, "not sigv4"}

  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp hex(bin), do: Base.encode16(bin, case: :lower)
  defp encode(s), do: URI.encode(s, &URI.char_unreserved?/1)
end
```

The `host` header: Bandit presents it as `host`; Req sends `host` as part of the signed headers. If verification of Req's requests fails only on the `host` header, compare what Req signs (`deps/req/lib/req/utils.ex`, `aws_sigv4_headers`) with what Bandit reports.

- [ ] **Step 3: Implement the stub**

`Portal.Test.FakeS3` holds state in an Agent: `%{objects: %{key => %{body, meta}}, fault: nil, on_get: nil, requests: []}`. `start/1` does `{:ok, agent} = Agent.start_link(...)`, `{:ok, pid} = Bandit.start_link(plug: {Portal.Test.FakeS3.Plug, %{agent: agent, bucket: ..., access_key: ..., secret_key: ..., region: ...}}, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false)`, then `{:ok, {_ip, port}} = ThousandIsland.listener_info(pid)`.

`Portal.Test.FakeS3.Plug` (a plain `Plug` with `init/1` returning the map and `call/2`):

1. Read the whole body with `Plug.Conn.read_body(conn, length: 1_000_000_000)` (loop on `{:more, ...}`), assign it to `:body`, record `{method, request_path, query_string}` in the agent.
2. `SigV4.verify/4`; on error respond 403 with `<Error><Code>SignatureDoesNotMatch</Code></Error>` and halt.
3. Route on `conn.path_info`:
   - `[bucket]` with `list-type=2` in the query: list. Keys under `prefix`, sorted; honour `max-keys` (default 1000) and `continuation-token` (the last key of the previous page; return keys after it). XML as in spec 4.2 with `IsTruncated` and `NextContinuationToken`. Fault `{:list, :status, n}` → that status; `{:list, :no_token}` → first page `IsTruncated` true with `max-keys` forced to 1 and no token element.
   - `[bucket | key_parts]`, key = `Enum.join(key_parts, "/")`:
     - `PUT`: store body and every `x-amz-meta-*` request header (name without the prefix... store the full header name, `x-amz-meta-sha256` → value); respond 200 with an `etag`. Fault `{:put, :status, n}` → that status.
     - `HEAD`: 200 with `content-length` and every meta header, or 404.
     - `GET`: call `on_get`; fault `{:get, :status, n}` → that status; `{:get, :truncate}` → `send_chunked(200)` then `chunk` the first half of the body and stop (no final chunk is needed: returning the conn after one chunk ends the response short); else 200 with `content-type`, meta headers, and `send_resp(200, body)`; 404 when missing.
   - anything else: 400.
4. Every response carries the body for 4xx as `<Error><Code>NoSuchKey</Code></Error>` where appropriate.

Note on `{:get, :truncate}`: Bandit ends a chunked response cleanly when the plug returns, so the client sees a *complete* short body. That is what the sha-mismatch test needs (a short body whose header sha does not match). Say so in the stub's doc.

- [ ] **Step 4: Run, format, commit**

```bash
mix test apps/portal/test/portal/build_cache/l2/fake_s3_test.exs && mix format && mix compile --warnings-as-errors
git add apps/portal/test/support/fake_s3.ex apps/portal/test/portal/build_cache/l2/fake_s3_test.exs
git commit -m "Build cache L2: in-process S3 stub with an independent SigV4 verifier

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 5: The S3 client

**Files:**
- Create: `apps/portal/lib/portal/build_cache/l2/client.ex`
- Test: `apps/portal/test/portal/build_cache/l2/client_test.exs`

**Interfaces:**
- Consumes: `%Portal.BuildCache.L2.Config{}`, `Portal.Test.FakeS3`.
- Produces: `Client.head(cfg, object) :: {:ok, %{size: non_neg_integer() | nil, sha256: String.t() | nil}} | {:error, :not_found} | {:error, term()}`; `Client.get(cfg, object, path, opts) :: {:ok, %{bytes, sha256_computed, sha256_header}} | {:error, :not_found | :too_large | :timeout | {:status, n} | term()}` with opts `max_bytes`, `timeout_ms` (default 120_000); `Client.put(cfg, object, path, sha256) :: :ok | {:error, term()}`; `Client.list(cfg, prefix) :: {:ok, [%{key: String.t(), size: non_neg_integer(), last_modified: DateTime.t()}]} | {:error, term()}`.

- [ ] **Step 1: Failing tests**

```elixir
defmodule Portal.BuildCache.L2.ClientTest do
  use ExUnit.Case, async: true

  alias Portal.BuildCache.L2.Client
  alias Portal.Test.FakeS3

  setup do
    {:ok, s} = FakeS3.start()
    tmp = Path.join(System.tmp_dir!(), "client-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    on_exit(fn -> File.rm_rf(tmp) end)
    %{s: s, cfg: s.config, tmp: tmp}
  end

  test "put, head, get round trip with the sha metadata", %{cfg: cfg, tmp: tmp} do
    src = Path.join(tmp, "src")
    File.write!(src, "hello")
    sha = :crypto.hash(:sha256, "hello") |> Base.encode16(case: :lower)
    assert :ok = Client.put(cfg, "slug/k.tar.gz", src, sha)
    assert {:ok, %{size: 5, sha256: ^sha}} = Client.head(cfg, "slug/k.tar.gz")
    dst = Path.join(tmp, "dst")
    assert {:ok, %{bytes: 5, sha256_computed: ^sha, sha256_header: ^sha}} = Client.get(cfg, "slug/k.tar.gz", dst, [])
    assert File.read!(dst) == "hello"
  end

  test "a missing object is not_found on head and get, and get leaves no file", %{cfg: cfg, tmp: tmp} do
    assert {:error, :not_found} = Client.head(cfg, "slug/none")
    dst = Path.join(tmp, "dst")
    assert {:error, :not_found} = Client.get(cfg, "slug/none", dst, [])
    refute File.exists?(dst)
  end

  test "get stops past max_bytes and removes the partial file", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/big", String.duplicate("x", 10_000), %{"x-amz-meta-sha256" => "irrelevant"})
    dst = Path.join(tmp, "dst")
    assert {:error, :too_large} = Client.get(cfg, "slug/big", dst, max_bytes: 100)
    refute File.exists?(dst)
  end

  test "get is bounded in time", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/slow", "body", %{})
    FakeS3.on_get(s, fn _ -> Process.sleep(500) end)
    assert {:error, :timeout} = Client.get(cfg, "slug/slow", Path.join(tmp, "dst"), timeout_ms: 50)
  end

  test "a non-2xx is reported by status", %{s: s, cfg: cfg, tmp: tmp} do
    FakeS3.put_object(s, "slug/k", "body", %{})
    FakeS3.set_fault(s, {:get, :status, 500})
    assert {:error, {:status, 500}} = Client.get(cfg, "slug/k", Path.join(tmp, "dst"), [])
    FakeS3.set_fault(s, {:put, :status, 503})
    File.write!(Path.join(tmp, "src"), "x")
    assert {:error, {:status, 503}} = Client.put(cfg, "slug/k", Path.join(tmp, "src"), "sha")
  end

  test "list pages through the prefix and parses size and time", %{s: s, cfg: cfg} do
    for i <- 1..5, do: FakeS3.put_object(s, "slug/#{i}.tar.gz", String.duplicate("x", i), %{})
    FakeS3.put_object(s, "other/1.tar.gz", "y", %{})
    assert {:ok, objects} = Client.list(cfg, "slug/", max_keys: 2)
    assert Enum.map(objects, & &1.key) == for(i <- 1..5, do: "slug/#{i}.tar.gz")
    assert Enum.map(objects, & &1.size) == [1, 2, 3, 4, 5]
    assert Enum.all?(objects, &match?(%DateTime{}, &1.last_modified))
    assert length(FakeS3.requests(s)) >= 3
  end

  test "a truncated page without a token ends the listing", %{s: s, cfg: cfg} do
    for i <- 1..3, do: FakeS3.put_object(s, "slug/#{i}.tar.gz", "x", %{})
    FakeS3.set_fault(s, {:list, :no_token})
    assert {:ok, [_one]} = Client.list(cfg, "slug/")
  end

  test "an endpoint that is down is an error, quickly", %{cfg: cfg} do
    down = %{cfg | endpoint: "http://127.0.0.1:1"}
    assert {:error, _} = Client.head(down, "slug/k")
    assert {:error, _} = Client.list(down, "slug/")
  end

  test "every request was signed with the configured key", %{s: s, cfg: cfg} do
    assert {:ok, []} = Client.list(cfg, "slug/")
    assert [{"GET", _, query}] = FakeS3.requests(s)
    assert query =~ "list-type=2"
  end
end
```

`list/3` takes an optional third `opts` with `max_keys` (default 1000) so pagination is testable.

- [ ] **Step 2: Implement Client**

```elixir
defmodule Portal.BuildCache.L2.Client do
  @moduledoc """
  The few S3 calls the L2 build cache needs, over `Req` with its own SigV4
  step, against a path-style endpoint (`<endpoint>/<bucket>/<object>`,
  which Garage serves). No retries and no redirects: every caller bounds
  its own time and would rather fail fast. Errors come back as terms for
  the caller to log; nothing here logs.
  """

  alias Portal.BuildCache.L2.Config

  @connect_timeout 10_000
  @max_pages 50

  @spec head(Config.t(), String.t()) :: {:ok, %{size: non_neg_integer() | nil, sha256: String.t() | nil}} | {:error, term()}
  def head(cfg, object) do
    case Req.head(req(cfg, receive_timeout: 30_000), url: object_url(cfg, object)) do
      {:ok, %Req.Response{status: 200} = resp} -> {:ok, %{size: int_header(resp, "content-length"), sha256: header(resp, "x-amz-meta-sha256")}}
      {:ok, %Req.Response{status: 404}} -> {:error, :not_found}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Streams the object into `path`, hashing it; the file is gone on every error."
  # `path` is a host-built staging name under the slug.
  # sobelow_skip ["Traversal.FileModule"]
  @spec get(Config.t(), String.t(), Path.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(cfg, object, path, opts) do
    timeout = Keyword.get(opts, :timeout_ms, 120_000)
    task = Task.async(fn -> do_get(cfg, object, path, Keyword.get(opts, :max_bytes)) end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> _ = File.rm(path); {:error, {:exit, reason}}
      nil -> _ = File.rm(path); {:error, :timeout}
    end
  end

  defp do_get(cfg, object, path, max_bytes) do
    with {:ok, io} <- File.open(path, [:write, :binary, :raw]) do
      collector = fn {:data, chunk}, {req, resp} ->
        acc = Req.Response.get_private(resp, :l2, %{bytes: 0, hash: :crypto.hash_init(:sha256), too_large: false})
        bytes = acc.bytes + byte_size(chunk)

        cond do
          resp.status != 200 -> {:cont, {req, resp}}
          max_bytes && bytes > max_bytes -> {:halt, {req, Req.Response.put_private(resp, :l2, %{acc | bytes: bytes, too_large: true})}}
          true ->
            :ok = IO.binwrite(io, chunk)
            {:cont, {req, Req.Response.put_private(resp, :l2, %{acc | bytes: bytes, hash: :crypto.hash_update(acc.hash, chunk)})}}
        end
      end

      result = Req.get(req(cfg, receive_timeout: 60_000, into: collector), url: object_url(cfg, object))
      File.close(io)
      finish_get(result, path)
    end
  end

  defp finish_get({:ok, %Req.Response{status: 200} = resp}, path) do
    case Req.Response.get_private(resp, :l2) do
      %{too_large: true} -> _ = File.rm(path); {:error, :too_large}
      %{bytes: bytes, hash: hash} -> {:ok, %{bytes: bytes, sha256_computed: Base.encode16(:crypto.hash_final(hash), case: :lower), sha256_header: header(resp, "x-amz-meta-sha256")}}
      nil -> _ = File.rm(path); {:error, :empty}
    end
  end
  defp finish_get({:ok, %Req.Response{status: 404}}, path), do: (_ = File.rm(path); {:error, :not_found})
  defp finish_get({:ok, %Req.Response{status: status}}, path), do: (_ = File.rm(path); {:error, {:status, status}})
  defp finish_get({:error, reason}, path), do: (_ = File.rm(path); {:error, reason})

  # `path` is the tarball `Portal.BuildCache.L2.Tarball.pack/3` just wrote.
  # sobelow_skip ["Traversal.FileModule"]
  @spec put(Config.t(), String.t(), Path.t(), String.t()) :: :ok | {:error, term()}
  def put(cfg, object, path, sha256) do
    with {:ok, body} <- File.read(path) do
      case Req.put(req(cfg, receive_timeout: 120_000), url: object_url(cfg, object), body: body, headers: [{"content-type", "application/gzip"}, {"x-amz-meta-sha256", sha256}]) do
        {:ok, %Req.Response{status: status}} when status in 200..299 -> :ok
        {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @spec list(Config.t(), String.t(), keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(cfg, prefix, opts \\ []), do: list_pages(cfg, prefix, Keyword.get(opts, :max_keys, 1000), nil, [], 0)

  defp list_pages(_cfg, _prefix, _max, _token, acc, @max_pages), do: {:ok, Enum.reverse(acc)}

  defp list_pages(cfg, prefix, max, token, acc, page) do
    params = [{"list-type", "2"}, {"prefix", prefix}, {"max-keys", Integer.to_string(max)}] ++ if(token, do: [{"continuation-token", token}], else: [])

    case Req.get(req(cfg, receive_timeout: 30_000), url: "/" <> cfg.bucket, params: params) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        {objects, next} = parse_listing(body)
        acc = Enum.reverse(objects) ++ acc
        if next, do: list_pages(cfg, prefix, max, next, acc, page + 1), else: {:ok, Enum.reverse(acc)}
      {:ok, %Req.Response{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  # A fixed extraction rather than an XML parser: ListObjectsV2 is flat, the
  # keys are our own hex names, and anything unparseable is dropped.
  defp parse_listing(body) when is_binary(body) do
    objects =
      ~r{<Contents>(.*?)</Contents>}s
      |> Regex.scan(body)
      |> Enum.flat_map(fn [_, block] ->
        with key when is_binary(key) <- text(block, "Key"),
             {size, ""} <- Integer.parse(text(block, "Size") || ""),
             {:ok, dt, _} <- DateTime.from_iso8601(text(block, "LastModified") || "") do
          [%{key: key, size: size, last_modified: dt}]
        else
          _ -> []
        end
      end)

    next = if text(body, "IsTruncated") == "true", do: text(body, "NextContinuationToken"), else: nil
    {objects, next}
  end
  defp parse_listing(_), do: {[], nil}

  defp text(xml, tag) do
    case Regex.run(~r{<#{tag}>(.*?)</#{tag}>}s, xml) do
      [_, value] -> value
      nil -> nil
    end
  end

  defp req(cfg, opts) do
    Req.new([base_url: cfg.endpoint, retry: false, redirect: false, connect_options: [timeout: @connect_timeout], aws_sigv4: [access_key_id: cfg.access_key, secret_access_key: cfg.secret_key, service: :s3, region: cfg.region]] ++ opts)
  end

  defp object_url(cfg, object), do: "/" <> cfg.bucket <> "/" <> object

  defp header(resp, name), do: resp |> Req.Response.get_header(name) |> List.first()
  defp int_header(resp, name) do
    case header(resp, name) do
      nil -> nil
      v -> case Integer.parse(v) do {n, _} -> n; :error -> nil end
    end
  end
end
```

Req's response body with `into:` a function is `""`; the listing GET uses no `into` so `body` is the XML string (Req decodes JSON only; XML comes back raw as a binary, check `decode_body` does not try `xml`). If the `Req.get` on the listing arrives with `body` already as something else, pass `decode_body: false`.

- [ ] **Step 3: Run, format, commit**

```bash
mix test apps/portal/test/portal/build_cache/l2/client_test.exs && mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal/build_cache/l2/client.ex apps/portal/test/portal/build_cache/l2/client_test.exs
git commit -m "Build cache L2: S3 client over Req with SigV4, streamed and bounded GET

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 6: Upload: `L2.upload/4` and the Promotion hook

**Files:**
- Modify: `apps/portal/lib/portal/build_cache/l2.ex` (add `upload/5`)
- Modify: `apps/portal/lib/portal/build_cache/promotion.ex` (`finish/5`, `ctx.l2`, `promote/6` doc)
- Test: `apps/portal/test/portal/build_cache/l2_test.exs` (upload cases), `apps/portal/test/portal/build_cache/promotion_test.exs` (hook cases)

**Interfaces:**
- Consumes: `Config`, `Client.put/4`, `Client.head/2`, `Tarball.pack/3`, `Stats.record/2`, `Staging.name/1`.
- Produces: `L2.upload(entry_dir, slug, key, package, opts \\ []) :: {:ok, bytes :: non_neg_integer()} | :skipped | {:error, term()}` with opts `config: %Config{}` (default `Config.config/0`). `bytes` is the tarball size uploaded.
- Produces in Promotion: `opts[:l2]` seam, a 4-arity function `(entry_dir, slug, key, package)` or `false`; default `&Portal.BuildCache.L2.upload/4`.

- [ ] **Step 1: Failing L2 upload tests** (append to `l2_test.exs`; needs `Stats.reset()` in setup and `async: false`)

```elixir
  describe "upload/4" do
    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2up-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, "sha256_abc")
      key = String.duplicate("a", 64)
      entry = Path.join(slug_dir, key)
      File.mkdir_p!(Path.join(entry, "ebin"))
      File.write!(Path.join(entry, "ebin/Elixir.Jason.beam"), "beam")
      on_exit(fn -> File.rm_rf(tmp) end)
      Stats.reset()
      %{s: s, cfg: s.config, slug_dir: slug_dir, entry: entry, key: key}
    end

    test "stores the entry as <slug>/<key>.tar.gz with its sha", %{s: s, cfg: cfg, entry: entry, key: key, slug_dir: slug_dir} do
      assert {:ok, bytes} = L2.upload(entry, "sha256_abc", key, "jason", config: cfg)
      assert {:ok, %{body: body, meta: %{"x-amz-meta-sha256" => sha}}} = FakeS3.get_object(s, "sha256_abc/#{key}.tar.gz")
      assert sha == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
      assert File.ls!(slug_dir) == [key], "no tarball left beside the entry"
      assert %{uploads: 1, upload_failures: 0} = Stats.snapshot()
      assert Stats.snapshot().bytes_up == byte_size(body)
      assert bytes == byte_size(body)
    end

    test "read-only mode uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      assert :skipped = L2.upload(entry, "sha256_abc", key, "jason", config: %{cfg | read_only?: true})
      assert FakeS3.objects(s) == []
    end

    test "an endpoint that is down is logged and counted, never raised", %{cfg: cfg, entry: entry, key: key} do
      log = capture_log(fn -> assert {:error, _} = L2.upload(entry, "sha256_abc", key, "jason", config: %{cfg | endpoint: "http://127.0.0.1:1"}) end)
      assert log =~ "Build cache L2 upload of sha256_abc/#{key}.tar.gz failed"
      assert %{upload_failures: 1} = Stats.snapshot()
    end

    test "a structural refusal uploads nothing", %{s: s, cfg: cfg, entry: entry, key: key} do
      File.ln_s!("/etc/hostname", Path.join(entry, "ebin/evil"))
      assert {:error, _} = L2.upload(entry, "sha256_abc", key, "jason", config: cfg)
      assert FakeS3.objects(s) == []
    end

    test "with L2 off it is skipped", %{entry: entry, key: key} do
      assert :skipped = L2.upload(entry, "sha256_abc", key, "jason", config: nil)
    end
  end
```

- [ ] **Step 2: Implement `upload/5`** in `l2.ex`:

```elixir
  @doc """
  Uploads one promoted entry, best effort: `{:ok, bytes}` with the tarball
  size, `:skipped` when L2 is off or read-only, `{:error, reason}` on any
  failure, never an exception. Logs its own outcome and records it in `Stats`.
  """
  # `entry_dir` is a promoted entry under the operator's cache root.
  # sobelow_skip ["Traversal.FileModule"]
  @spec upload(Path.t(), String.t(), String.t(), String.t() | :any, keyword()) :: {:ok, non_neg_integer()} | :skipped | {:error, term()}
  def upload(entry_dir, slug, key, package, opts \\ []) do
    case Keyword.get_lazy(opts, :config, &active_config/0) do
      %Config{read_only?: false} = cfg -> do_upload(cfg, entry_dir, slug, key, package)
      _ -> :skipped
    end
  rescue
    e -> {:error, {:exception, Exception.message(e)}}
  end

  defp active_config do
    case Config.config() do
      {:ok, cfg} -> cfg
      _ -> nil
    end
  end

  defp do_upload(cfg, entry_dir, slug, key, package) do
    object = object_key(slug, key)
    tar = Staging.name(entry_dir) <> ".tar.gz"

    result =
      with {:ok, %{sha256: sha, bytes: bytes}} <- Tarball.pack(entry_dir, tar, package),
           :ok <- Client.put(cfg, object, tar, sha) do
        {:ok, bytes}
      end

    _ = File.rm(tar)

    case result do
      {:ok, bytes} ->
        Stats.record(:upload_ok, bytes)
        Logger.info("Build cache L2 upload of #{object}: #{bytes} bytes")
        {:ok, bytes}
      {:error, reason} ->
        Stats.record(:upload_failed)
        Logger.warning("Build cache L2 upload of #{object} failed: #{inspect(reason, printable_limit: 200)}")
        {:error, reason}
    end
  end
```

Aliases: `alias Portal.BuildCache.{Staging}` and `alias Portal.BuildCache.L2.{Client, Config, Stats, Tarball}`.

- [ ] **Step 3: Failing Promotion hook tests** (append to `promotion_test.exs`)

```elixir
  describe "L2 upload hook" do
    test "is called with the entry, slug, key and package after a successful promotion", ctx do
      test_pid = self()
      c = candidate(ctx.out)
      hex = fn _p, v -> {:ok, @outer} end
      promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5", release_checksum: hex, l2: fn dir, slug, key, package -> send(test_pid, {:l2, dir, slug, key, package}); :ok end)
      assert_receive {:l2, dir, "sha256_x", key, "jason"}
      assert key == c["key"]
      assert dir == Path.join(ctx.cache, key)
      assert File.dir?(dir)
    end

    test "is not called when nothing was promoted", ctx do
      test_pid = self()
      c = candidate(ctx.out, %{"key" => String.duplicate("0", 64)})
      promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5", release_checksum: fn _, _ -> {:ok, @outer} end, l2: fn _, _, _, _ -> send(test_pid, :l2); :ok end)
      refute_receive :l2
    end

    test "an upload that raises does not fail the promotion", ctx do
      c = candidate(ctx.out)
      counts = promote(result([c]), ctx.out, ctx.cache, "jason", "1.4.5", release_checksum: fn _, _ -> {:ok, @outer} end, l2: fn _, _, _, _ -> raise "boom" end)
      assert counts.promoted == 1
      assert File.dir?(Path.join(ctx.cache, c["key"]))
    end
  end
```

Check how the existing tests stub Hex (`release_checksum:` opt and the `@outer` checksum) and copy that exactly; also set `l2: false` in the test file's `promote/6` helper default so the other tests never touch the real L2 (`Keyword.put_new(opts, :l2, false)`).

- [ ] **Step 4: Implement the hook** in `promotion.ex`

In `promote/6`'s `ctx`: `l2: Keyword.get(opts, :l2, &Portal.BuildCache.L2.upload/4)`. In `finish/5`, after the `Logger.info("Promoted ...")`:

```elixir
        upload_to_l2(dest, key, ctx)
        :promoted
```

```elixir
  # Best effort and after the fact: the entry is already promoted locally,
  # and a failed or crashing upload must not change that.
  defp upload_to_l2(_dest, _key, %{l2: false}), do: :ok

  defp upload_to_l2(dest, key, %{l2: fun} = ctx) when is_function(fun, 4) do
    _ = fun.(dest, Path.basename(ctx.cache), key, ctx.package)
    :ok
  rescue
    e -> Logger.warning("Build cache L2 upload of #{key} raised: #{Exception.message(e)}"); :ok
  end
```

Add to the `promote/6` doc: "`opts[:l2]` is the L2 upload called after a successful promotion (`Portal.BuildCache.L2.upload/4`), or `false`." Add one moduledoc sentence after step 8: "Once renamed, the entry is also offered to the shared L2 cache (`Portal.BuildCache.L2`), best effort."

- [ ] **Step 5: Run, format, commit**

```bash
mix test apps/portal/test/portal/build_cache/ && mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal/build_cache/l2.ex apps/portal/lib/portal/build_cache/promotion.ex apps/portal/test/portal/build_cache/l2_test.exs apps/portal/test/portal/build_cache/promotion_test.exs
git commit -m "Build cache L2: upload a promoted entry after the local rename

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 7: Prefetch: `L2.prefetch/3` and the Builder hook

**Files:**
- Modify: `apps/portal/lib/portal/build_cache/l2.ex` (add `prefetch/3`, full moduledoc)
- Modify: `apps/portal/lib/portal/builder.ex` (`build/2` chain, `prefetch_build_cache/1`)
- Test: `apps/portal/test/portal/build_cache/l2_test.exs` (prefetch cases), `apps/portal/test/portal/builder_test.exs` (hook with a fake docker)

**Interfaces:**
- Consumes: `Client.list/3`, `Client.get/4`, `Tarball.unpack/2`, `Stats.*`, `Staging.name/1`.
- Produces: `L2.prefetch(slug_dir, slug, opts \\ []) :: %{listed, candidates, downloaded, discarded, failed, skipped, bytes, list_failed: boolean}` with opts `config`, `budget_bytes` (2 GiB), `budget_ms` (300_000), `max_object_bytes` (`Tarball.max_object_bytes/0`).

- [ ] **Step 1: Failing prefetch tests** (append to `l2_test.exs`; helper `seed/4` builds an entry dir, packs it with `Tarball.pack`, and `FakeS3.put_object`s it under `"#{slug}/#{key}.tar.gz"` with the `x-amz-meta-sha256` meta, returning the tarball bytes)

```elixir
  describe "prefetch/3" do
    setup do
      {:ok, s} = FakeS3.start()
      tmp = Path.join(System.tmp_dir!(), "l2pf-#{System.unique_integer([:positive])}")
      slug_dir = Path.join(tmp, "sha256_abc")
      File.mkdir_p!(slug_dir)
      on_exit(fn -> File.rm_rf(tmp) end)
      Stats.reset()
      %{s: s, cfg: s.config, tmp: tmp, slug_dir: slug_dir}
    end

    # An entry packed the way the uploader packs it, placed in the stub.
    defp seed(s, tmp, key, opts \\ []) do
      src = Path.join(tmp, "src-#{key}")
      File.mkdir_p!(Path.join(src, "ebin"))
      File.write!(Path.join(src, "ebin/Elixir.X.beam"), Keyword.get(opts, :content, "beam-" <> key))
      if Keyword.get(opts, :priv_link), do: File.ln_s!("../../../../deps/x/priv", Path.join(src, "priv"))
      tar = Path.join(tmp, "#{key}.tar.gz")
      {:ok, %{sha256: sha}} = Tarball.pack(src, tar, :any)
      bytes = File.read!(tar)
      meta = %{"x-amz-meta-sha256" => Keyword.get(opts, :sha, sha)}
      FakeS3.put_object(s, "sha256_abc/#{key}.tar.gz", Keyword.get(opts, :body, bytes), meta)
      bytes
    end

    defp key(n), do: String.pad_leading(Integer.to_string(n), 64, "0")

    test "restores a missing key and leaves no staging behind", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1), priv_link: true)
      assert %{downloaded: 1, failed: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.read!(Path.join([slug_dir, key(1), "ebin/Elixir.X.beam"])) == "beam-" <> key(1)
      assert File.read_link!(Path.join([slug_dir, key(1), "priv"])) == "../../../../deps/x/priv"
      assert File.ls!(slug_dir) == [key(1)]
      assert %{downloads: 1} = Stats.snapshot()
    end

    test "skips keys present locally and names that are not keys", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      File.mkdir_p!(Path.join(slug_dir, key(1)))
      FakeS3.put_object(s, "sha256_abc/README", "x", %{})
      assert %{downloaded: 0, candidates: 0, listed: 2} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
    end

    test "a sha mismatch is refused, removed and marked bad", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1), sha: String.duplicate("f", 64))
      log = capture_log(fn -> assert %{failed: 1, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg) end)
      assert log =~ "sha256"
      assert File.ls!(slug_dir) == []
      assert Stats.bad?(key(1))
      assert %{candidates: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
    end

    test "a truncated tarball is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      cut = binary_part(bytes, 0, div(byte_size(bytes), 2))
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", cut, %{"x-amz-meta-sha256" => :crypto.hash(:sha256, cut) |> Base.encode16(case: :lower)})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
    end

    test "a short body from the transport is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      FakeS3.set_fault(s, {:get, :truncate})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
    end

    test "a ../ member, an absolute member and a symlink out of the entry are each refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      hostile = fn name, members ->
        path = Path.join(tmp, name)
        {:ok, tar} = :erl_tar.open(String.to_charlist(path), [:write, :compressed])
        for {n, c} <- members, do: :ok = :erl_tar.add(tar, c, String.to_charlist(n), [])
        :ok = :erl_tar.close(tar)
        File.read!(path)
      end
      link_src = Path.join(tmp, "linksrc")
      File.mkdir_p!(Path.join(link_src, "ebin"))
      File.ln_s!("../../outside", Path.join(link_src, "priv"))
      link_tar = Path.join(tmp, "link.tar.gz")
      :ok = :erl_tar.create(String.to_charlist(link_tar), [{~c"ebin", String.to_charlist(Path.join(link_src, "ebin"))}, {~c"priv", String.to_charlist(Path.join(link_src, "priv"))}], [:compressed])

      bodies = [
        {key(1), hostile.("dotdot.tar.gz", [{"../escape", "x"}])},
        {key(2), hostile.("abs.tar.gz", [{"/tmp/abs", "x"}])},
        {key(3), File.read!(link_tar)}
      ]
      for {k, body} <- bodies, do: FakeS3.put_object(s, "sha256_abc/#{k}.tar.gz", body, %{"x-amz-meta-sha256" => :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)})

      assert %{failed: 3, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == []
      refute File.exists?(Path.join(tmp, "escape"))
      refute File.exists?("/tmp/abs")
    end

    test "an object that is not a tarball at all is refused and marked bad", %{s: s, cfg: cfg, slug_dir: slug_dir} do
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", "junk", %{"x-amz-meta-sha256" => :crypto.hash(:sha256, "junk") |> Base.encode16(case: :lower)})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert Stats.bad?(key(1))
    end

    test "a missing sha header is refused", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      bytes = seed(s, tmp, key(1))
      FakeS3.put_object(s, "sha256_abc/#{key(1)}.tar.gz", bytes, %{})
      assert %{failed: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
    end

    test "an entry appearing locally during the download is discarded", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      dest = Path.join(slug_dir, key(1))
      FakeS3.on_get(s, fn _ -> File.mkdir_p!(Path.join(dest, "ebin")); File.write!(Path.join(dest, "ebin/local"), "mine") end)
      assert %{discarded: 1, downloaded: 0, failed: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      assert File.ls!(slug_dir) == [key(1)]
      assert File.ls!(Path.join(dest, "ebin")) == ["local"]
    end

    test "the byte budget stops the loop but lets a small entry behind a large one through", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      big = seed(s, tmp, key(1), content: String.duplicate("b", 50_000))
      _ = seed(s, tmp, key(2), content: "small")
      _ = seed(s, tmp, key(3), content: String.duplicate("c", 50_000))
      budget = byte_size(big) + 100
      assert %{downloaded: 2, skipped: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_bytes: budget)
    end

    test "the time budget stops the loop", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      for i <- 1..3, do: seed(s, tmp, key(i))
      FakeS3.on_get(s, fn _ -> Process.sleep(60) end)
      result = L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_ms: 50)
      assert result.downloaded < 3
      assert result.skipped + result.downloaded == 3
    end

    test "an object over the per-object cap is skipped", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1), content: String.duplicate("x", 5000))
      assert %{candidates: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg, max_object_bytes: 10)
    end

    test "an endpoint that is down lists nothing and says so", %{cfg: cfg, slug_dir: slug_dir} do
      log = capture_log(fn -> assert %{list_failed: true, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: %{cfg | endpoint: "http://127.0.0.1:1"}) end)
      assert log =~ "Build cache L2 listing of sha256_abc/ failed"
      assert %{list_failures: 1} = Stats.snapshot()
    end

    test "read-only mode still downloads", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      assert %{downloaded: 1} = L2.prefetch(slug_dir, "sha256_abc", config: %{cfg | read_only?: true})
    end

    test "a key claimed by another build on this node is skipped", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      assert Stats.claim(key(1))
      assert %{skipped: 1, downloaded: 0} = L2.prefetch(slug_dir, "sha256_abc", config: cfg)
      Stats.release(key(1))
    end

    test "newest objects come first", %{s: s, cfg: cfg, tmp: tmp, slug_dir: slug_dir} do
      seed(s, tmp, key(1))
      Process.sleep(1100)
      seed(s, tmp, key(2))
      small = byte_size(File.read!(Path.join(tmp, "#{key(2)}.tar.gz")))
      assert %{downloaded: 1} = L2.prefetch(slug_dir, "sha256_abc", config: cfg, budget_bytes: small + 10)
      assert File.ls!(slug_dir) == [key(2)]
    end
  end
```

The stub's `LastModified` must be the put time with second precision for the last test; the stub records `DateTime.utc_now()` on put.

- [ ] **Step 2: Implement `prefetch/3`**

```elixir
  @budget_bytes 2 * 1024 * 1024 * 1024
  @budget_ms :timer.minutes(5)
  @object_timeout_ms 120_000
  @key_pattern ~r/\A[0-9a-f]{64}\z/

  @doc """
  Syncs the slug's objects into `slug_dir` under a byte and time budget
  (spec, sections 3.1 and 4.6). Never raises; returns counts for the caller
  to log.
  """
  # `slug_dir` is the per-image directory under the operator's cache root.
  # sobelow_skip ["Traversal.FileModule"]
  @spec prefetch(Path.t(), String.t(), keyword()) :: map()
  def prefetch(slug_dir, slug, opts \\ []) do
    cfg = Keyword.get_lazy(opts, :config, &active_config/0)
    empty = %{listed: 0, candidates: 0, downloaded: 0, discarded: 0, failed: 0, skipped: 0, bytes: 0, list_failed: false}

    case cfg do
      %Config{} -> do_prefetch(cfg, slug_dir, slug, opts, empty)
      _ -> empty
    end
  rescue
    e ->
      Logger.warning("Build cache L2 prefetch of #{slug} raised: #{Exception.message(e)}")
      %{listed: 0, candidates: 0, downloaded: 0, discarded: 0, failed: 1, skipped: 0, bytes: 0, list_failed: false}
  end

  defp do_prefetch(cfg, slug_dir, slug, opts, counts) do
    prefix = slug <> "/"

    case Client.list(cfg, prefix) do
      {:ok, objects} ->
        local = local_names(slug_dir)
        max_object = Keyword.get(opts, :max_object_bytes, Tarball.max_object_bytes())

        candidates =
          objects
          |> Enum.flat_map(fn obj ->
            case object_hex(obj.key, prefix) do
              nil -> []
              hex -> if MapSet.member?(local, hex) or Stats.bad?(hex) or obj.size > max_object, do: [], else: [{hex, obj}]
            end
          end)
          |> Enum.sort_by(fn {_hex, obj} -> obj.last_modified end, {:desc, DateTime})

        budget = %{bytes: Keyword.get(opts, :budget_bytes, @budget_bytes), deadline: System.monotonic_time(:millisecond) + Keyword.get(opts, :budget_ms, @budget_ms)}
        counts = %{counts | listed: length(objects), candidates: length(candidates)}
        Enum.reduce(candidates, counts, &fetch_candidate(&1, &2, cfg, slug_dir, budget))

      {:error, reason} ->
        Stats.record(:list_failed)
        Logger.warning("Build cache L2 listing of #{prefix} failed: #{inspect(reason, printable_limit: 200)}")
        %{counts | list_failed: true}
    end
  end

  defp object_hex(key, prefix) do
    with ^prefix <> rest <- key,
         [hex, ""] <- String.split(rest, ".tar.gz", parts: 2),
         true <- Regex.match?(@key_pattern, hex) do
      hex
    else
      _ -> nil
    end
  end

  defp local_names(slug_dir) do
    case File.ls(slug_dir) do
      {:ok, names} -> MapSet.new(names)
      {:error, _} -> MapSet.new()
    end
  end

  defp fetch_candidate({hex, obj}, counts, cfg, slug_dir, budget) do
    remaining_ms = budget.deadline - System.monotonic_time(:millisecond)

    cond do
      counts[:stopped] -> %{counts | skipped: counts.skipped + 1}
      remaining_ms <= 0 -> %{counts | skipped: counts.skipped + 1}
      counts.bytes + obj.size > budget.bytes -> %{counts | skipped: counts.skipped + 1}
      not Stats.claim(hex) -> %{counts | skipped: counts.skipped + 1}
      true ->
        try do
          case download_one(cfg, slug_dir, hex, obj, min(remaining_ms, @object_timeout_ms)) do
            {:ok, bytes} -> Stats.record(:download_ok, bytes); %{counts | downloaded: counts.downloaded + 1, bytes: counts.bytes + bytes}
            {:discarded, bytes} -> Stats.record(:discarded); %{counts | discarded: counts.discarded + 1, bytes: counts.bytes + bytes}
            {:error, :stop} -> Map.put(%{counts | failed: counts.failed + 1}, :stopped, true)
            {:error, _} -> %{counts | failed: counts.failed + 1}
          end
        after
          Stats.release(hex)
        end
    end
  end

  # One object: GET to a staging tarball, verify, extract to a staging dir,
  # publish by rename unless the entry arrived meanwhile.
  defp download_one(cfg, slug_dir, hex, obj, timeout_ms) do
    dest = Path.join(slug_dir, hex)
    staging = Staging.name(dest)
    tar = staging <> ".tar.gz"
    object = obj.key

    result =
      with {:ok, %{bytes: bytes, sha256_computed: computed, sha256_header: header}} <- Client.get(cfg, object, tar, max_bytes: obj.size, timeout_ms: timeout_ms),
           :ok <- verify_sha(computed, header),
           :ok <- File.mkdir(staging),
           :ok <- Tarball.unpack(tar, staging),
           :ok <- publish(staging, dest) do
        {:ok, bytes}
      end

    _ = File.rm(tar)
    _ = File.rm_rf(staging)

    case result do
      {:ok, bytes} -> {:ok, bytes}
      {:discarded, bytes} -> {:discarded, bytes}
      {:error, reason} -> failed(object, hex, reason)
    end
  end

  defp verify_sha(_computed, nil), do: {:error, :no_sha256_header}
  defp verify_sha(computed, header), do: if(computed == String.downcase(header), do: :ok, else: {:error, {:sha256_mismatch, computed, header}})

  defp publish(staging, dest) do
    case File.lstat(dest) do
      {:ok, _} -> {:discarded, 0}
      {:error, :enoent} ->
        case File.rename(staging, dest) do
          :ok -> :ok
          {:error, :eexist} -> {:discarded, 0}
          {:error, :enotempty} -> {:discarded, 0}
          {:error, reason} -> {:error, {:rename, reason}}
        end
      {:error, reason} -> {:error, {:lstat, reason}}
    end
  end
```

`publish/2` returning `{:discarded, 0}` inside the `with` falls through as a non-`:ok` value: the `with` needs an `else` that maps `{:discarded, _}` to `{:discarded, bytes}` where `bytes` is the downloaded size; restructure so the GET result's `bytes` is bound before the `with` on publish (two nested `with`s, or carry `bytes` in the tuple). Keep whatever shape passes the tests.

```elixir
  @stop_reasons [:timeout]

  defp failed(object, hex, reason) do
    verification? = match?({:sha256_mismatch, _, _}, reason) or reason in [:no_sha256_header, :too_large] or match?({:tar, _}, reason) or match?({:structure, _}, reason) or match?({:member_type, _, _}, reason) or match?({:member_name, _}, reason) or reason == :empty_archive
    if verification?, do: (Stats.mark_bad(hex); Stats.record(:refused)), else: Stats.record(:download_failed)
    Logger.warning("Build cache L2 download of #{object} failed: #{inspect(reason, printable_limit: 200)}")
    if reason in @stop_reasons or transport_error?(reason), do: {:error, :stop}, else: {:error, reason}
  end

  defp transport_error?(%Mint.TransportError{}), do: true
  defp transport_error?(%Req.TransportError{}), do: true
  defp transport_error?(_), do: false
```

`Req.TransportError` exists in Req 0.5+; `Mint.TransportError` is what older paths raise; keep both only if both compile (check `deps/req/lib/req/transport_error.ex`). Note `{:sha256_mismatch, ...}` makes the log line contain "sha256", which the test asserts.

Then the full moduledoc for `Portal.BuildCache.L2`, in the style of Promotion's: what L2 is, why the reader syncs the listing instead of fetching a plan (spec 3.1), the trust argument (spec 5.1: the bucket is trusted as far as its write key; what the downloader still checks), the budget, and that nothing here fails a build.

- [ ] **Step 3: The Builder hook and its test**

In `builder.ex`, `build/2`'s `with`, after `ensure_directories(...)`:

```elixir
         :ok <- prefetch_build_cache(job),
```

```elixir
  # Before the container runs, pull what the shared L2 cache has for this
  # image that the local cache lacks (`Portal.BuildCache.L2.prefetch/3`),
  # bounded, so the build never waits on it for long. Always `:ok`: the
  # cache is an optimisation.
  defp prefetch_build_cache(job) do
    with dir when is_binary(dir) <- build_cache_dir(job),
         true <- Portal.BuildCache.L2.enabled?() do
      counts = Portal.BuildCache.L2.prefetch(dir, Path.basename(dir))

      Logger.info(
        "Build cache L2 prefetch for #{job.run_id}: #{counts.downloaded} downloaded, " <>
          "#{counts.discarded} discarded, #{counts.failed} failed, #{counts.skipped} skipped " <>
          "of #{counts.candidates} candidates (#{counts.bytes} bytes)"
      )
    end

    :ok
  end
```

Also append that same line to the run's `runner.log` so the integration test can read it from `Builder.load_run/1`'s `log`: `build/2` already has `log_file`; pass it in (`prefetch_build_cache(job, log_file)`) and `File.write(log_file, line <> "\n", [:append])` after `ensure_directories` created `output_dir`. The log file lives under the run's scratch dir (`# sobelow_skip ["Traversal.FileModule"]` with the usual justification).

Builder test (in `builder_test.exs`, `describe "L2 prefetch"`): configure `build_cache: <tmp root>`, `min_free_disk_gb: 0`, `exec_probe: fn _ -> :ok end`, `egress_check: false`, `scratch_root: <tmp>`; start `FakeS3`, put the L2 config into `Application.put_env(:portal, Portal.BuildCache.L2, endpoint: s.endpoint, bucket: s.bucket, region: s.region, access_key: s.access_key, secret_key: s.secret_key)` (restore in `on_exit`); seed one object under `Builder.cache_slug("sha256:x") <> "/" <> key <> ".tar.gz"` (the `@build_args` digest is `sha256:x`); put a fake `docker` first on `PATH` (like `fake_nsenter`: a shell script that handles `version` by printing `99.0` and exit 0, and `run` by exit 0; restore PATH in `on_exit`) and call `Builder.build(@build_args)`; assert `{:ok, %{exit_code: 0, log: log}}`, that `<build_cache>/<slug>/<key>/ebin/...` exists, and `log =~ "Build cache L2 prefetch for run-1: 1 downloaded"`. Also: with the L2 env absent, `build/2` writes no prefetch line and touches the stub not at all (`FakeS3.requests(s) == []`).

If `docker` is also needed for `image_digest/1` (only when `image_digest` is absent from the args; it is present), nothing else calls it before `run_container`. `check_docker/0` runs `docker version --format {{.Server.Version}}`.

- [ ] **Step 4: Run, format, commit**

```bash
mix test apps/portal/test/portal/build_cache/ apps/portal/test/portal/builder_test.exs && mix format && mix compile --warnings-as-errors && mix test apps/portal/test/
git add apps/portal/lib/portal/build_cache/l2.ex apps/portal/lib/portal/builder.ex apps/portal/test/portal/build_cache/l2_test.exs apps/portal/test/portal/builder_test.exs
git commit -m "Build cache L2: prefetch the image slug's objects before every build, bounded

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 8: Admin Maintenance card

**Files:**
- Modify: `apps/portal/lib/portal_web/controllers/page_controller.ex` (`admin_assigns(:maintenance)`)
- Modify: `apps/portal/lib/portal_web/controllers/page_html/admin_maintenance.html.heex` (new section after "Precompiled signing")
- Test: `apps/portal/test/portal_web/controllers/page_controller_test.exs`

**Interfaces:**
- Consumes: `Portal.BuildCache.L2.status/0` (spec 4.7 shape).

- [ ] **Step 1: Failing tests** (beside "the maintenance section carries the update check"; copy its sign-in helper use)

```elixir
  test "the maintenance page shows the L2 build cache off", %{conn: conn} do
    {conn, _} = signed_in_admin(conn, "admin_l2_off")
    html = html_response(get(conn, ~p"/admin/maintenance"), 200)
    assert html =~ "Build cache L2"
    assert html =~ "Off"
  end

  test "the maintenance page shows the L2 build cache endpoint and counters, never the keys", %{conn: conn} do
    previous = Application.get_env(:portal, Portal.BuildCache.L2, [])
    Application.put_env(:portal, Portal.BuildCache.L2, endpoint: "http://100.64.0.2:3900", bucket: "ncc-build-cache", access_key: "GKVISIBLE", secret_key: "topsecret", read_only: true)
    on_exit(fn -> Application.put_env(:portal, Portal.BuildCache.L2, previous) end)
    Portal.BuildCache.L2.Stats.reset()
    Portal.BuildCache.L2.Stats.record(:download_ok, 1234)

    {conn, _} = signed_in_admin(conn, "admin_l2_on")
    html = html_response(get(conn, ~p"/admin/maintenance"), 200)
    assert html =~ "http://100.64.0.2:3900/ncc-build-cache"
    assert html =~ "read-only"
    assert html =~ "Downloads"
    refute html =~ "GKVISIBLE"
    refute html =~ "topsecret"
  end
```

- [ ] **Step 2: Implement**

Controller: add `build_cache_l2: Portal.BuildCache.L2.status()` to the `:maintenance` assigns. Template, after the precompiled-signing section:

```heex
  <section class="card mt-6 border border-base-300 bg-base-100 shadow-sm">
    <div class="card-body">
      <div class="flex flex-col gap-2 sm:flex-row sm:items-center sm:justify-between">
        <div>
          <h2 class="card-title">Build cache L2</h2>
          <p class="mt-1 text-sm leading-6 text-base-content/70">
            The shared S3 layer behind the local dependency build cache: read before every build, written after every promotion. Counters are this node's ({@build_cache_l2.node}) since it booted.
          </p>
        </div>
        <span class={[
          "badge w-fit",
          case @build_cache_l2.state do
            :on -> "badge-success"
            :incomplete -> "badge-error"
            :off -> "badge-ghost"
          end
        ]}>
          {case @build_cache_l2.state do
            :on -> "On"
            :incomplete -> "Incomplete config"
            :off -> "Off"
          end}
        </span>
      </div>
      <%= if @build_cache_l2.state == :on do %>
        <p class="mt-3 text-sm leading-6 text-base-content/70">
          {@build_cache_l2.endpoint}/{@build_cache_l2.bucket}<%= if @build_cache_l2.read_only? do %>, read-only<% end %>.
          Last upload {if @build_cache_l2.last_upload, do: format_datetime(@build_cache_l2.last_upload), else: "never"},
          last download {if @build_cache_l2.last_download, do: format_datetime(@build_cache_l2.last_download), else: "never"}.
        </p>
        <div class="mt-5 grid gap-3 sm:grid-cols-4">
          <PortalWeb.UI.stat_card label="Uploads" value={"#{@build_cache_l2.counters.uploads} (#{@build_cache_l2.counters.upload_failures} failed)"} />
          <PortalWeb.UI.stat_card label="Downloads" value={"#{@build_cache_l2.counters.downloads} (#{@build_cache_l2.counters.download_failures} failed, #{@build_cache_l2.counters.refused} refused)"} />
          <PortalWeb.UI.stat_card label="Bytes up" value={to_string(@build_cache_l2.counters.bytes_up)} />
          <PortalWeb.UI.stat_card label="Bytes down" value={to_string(@build_cache_l2.counters.bytes_down)} />
        </div>
      <% end %>
    </div>
  </section>
```

Check `format_datetime/1` accepts a `DateTime` (it is used with `completed_at` above; if it wants a `NaiveDateTime`, convert with `DateTime.to_naive/1`). Follow `apps/portal/AGENTS.md` HEEx rules (`{...}` for attribute and body interpolation, `<%= if %>` for blocks).

- [ ] **Step 3: Run, format, commit**

```bash
mix test apps/portal/test/portal_web/controllers/page_controller_test.exs && mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal_web/controllers/page_controller.ex apps/portal/lib/portal_web/controllers/page_html/admin_maintenance.html.heex apps/portal/test/portal_web/controllers/page_controller_test.exs
git commit -m "Admin: build cache L2 state and counters on the Maintenance tab

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 9: The one-time push

**Files:**
- Create: `apps/portal/lib/portal/build_cache/l2/push.ex`
- Create: `apps/portal/lib/mix/tasks/portal.build_cache.push.ex`
- Test: `apps/portal/test/portal/build_cache/l2/push_test.exs`

**Interfaces:**
- Consumes: `L2.upload/5`, `Client.head/2`, `Config`, `Staging.parse/1`.
- Produces: `Push.run(opts) :: {:ok, %{present: n, uploaded: n, failed: n, skipped: n, bytes: n}} | {:error, String.t()}` with opts `root`, `slug`, `limit`, `max_bytes`, `dry_run`, `config`, `io` (an IO device, default `:stdio`).

- [ ] **Step 1: Failing tests**

```elixir
defmodule Portal.BuildCache.L2.PushTest do
  use ExUnit.Case, async: false

  alias Portal.BuildCache.L2.{Push, Stats}
  alias Portal.Test.FakeS3

  setup do
    {:ok, s} = FakeS3.start()
    root = Path.join(System.tmp_dir!(), "push-#{System.unique_integer([:positive])}")
    for slug <- ["sha256_a", "sha256_b"], n <- 1..2 do
      key = String.pad_leading("#{slug}#{n}" |> String.replace(~r/[^a-f0-9]/, ""), 64, "0")
      dir = Path.join([root, slug, key, "ebin"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "x.beam"), String.duplicate("b", n * 100))
    end
    File.mkdir_p!(Path.join(root, "sha256_a/" <> String.duplicate("c", 64) <> ".tmp.box.0123456789abcdef"))
    File.write!(Path.join(root, "sha256_a/stray"), "x")
    on_exit(fn -> File.rm_rf(root) end)
    Stats.reset()
    %{s: s, cfg: s.config, root: root}
  end

  test "uploads every entry once and skips what is present on a second run", %{s: s, cfg: cfg, root: root} do
    {:ok, io} = StringIO.open("")
    assert {:ok, %{uploaded: 4, present: 0, failed: 0}} = Push.run(root: root, config: cfg, io: io)
    assert length(FakeS3.objects(s)) == 4
    assert {:ok, %{uploaded: 0, present: 4}} = Push.run(root: root, config: cfg, io: io)
    {_, out} = StringIO.contents(io)
    assert out =~ "present"
  end

  test "dry run uploads nothing", %{s: s, cfg: cfg, root: root} do
    {:ok, io} = StringIO.open("")
    assert {:ok, %{skipped: 4, uploaded: 0}} = Push.run(root: root, config: cfg, dry_run: true, io: io)
    assert FakeS3.objects(s) == []
  end

  test "limit, max_bytes and slug bound it", %{cfg: cfg, root: root} do
    {:ok, io} = StringIO.open("")
    assert {:ok, %{uploaded: 1}} = Push.run(root: root, config: cfg, limit: 1, io: io)
    assert {:ok, %{uploaded: 1, skipped: 2}} = Push.run(root: root, config: cfg, slug: "sha256_b", max_bytes: 1, io: io)
  end

  test "refuses read-only and off", %{cfg: cfg, root: root} do
    assert {:error, msg} = Push.run(root: root, config: %{cfg | read_only?: true})
    assert msg =~ "read-only"
    assert {:error, _} = Push.run(root: root, config: nil)
  end
end
```

(The second assertion in the bounds test: with `max_bytes: 1` the first upload goes through, since the cap is checked before each upload against bytes already sent, then the rest are skipped; the first run uploaded `sha256_a`'s two and `sha256_b`'s first? No: `limit: 1` uploaded exactly one entry, which one depends on sort order; make the push walk slugs and keys in sorted order and assert accordingly: after `limit: 1`, `sha256_a`'s first key is present, so the `slug: "sha256_b", max_bytes: 1` run uploads `sha256_b`'s first key and skips the second. Fix the expected counts to match the sorted order once implemented; the point is that each bound is honoured.)

- [ ] **Step 2: Implement Push and the Mix task**

```elixir
defmodule Portal.BuildCache.L2.Push do
  @moduledoc """
  One-time, resumable push of an existing local build cache into L2: every
  `<root>/<slug>/<64hex>` entry that a HEAD does not find in the bucket is
  packed and uploaded through `Portal.BuildCache.L2.upload/5`. Resumable
  because the HEAD is the state: run it again and it carries on. Bounded by
  `limit` entries and `max_bytes` uploaded. Runs under `mix
  portal.build_cache.push` or `bin/portal eval`.
  """
  alias Portal.BuildCache.{L2, Staging}
  alias Portal.BuildCache.L2.{Client, Config}

  @key ~r/\A[0-9a-f]{64}\z/

  def run(opts \\ []) do
    {:ok, _} = Application.ensure_all_started(:req)
    io = Keyword.get(opts, :io, :stdio)

    with {:ok, cfg} <- config(Keyword.get_lazy(opts, :config, fn -> unwrap(Config.config()) end)),
         {:ok, root} <- root(Keyword.get_lazy(opts, :root, &Portal.Builder.build_cache/0)) do
      entries = entries(root, Keyword.get(opts, :slug))
      IO.puts(io, "#{length(entries)} entries under #{root}")
      summary = Enum.reduce(entries, %{present: 0, uploaded: 0, failed: 0, skipped: 0, bytes: 0}, &push_one(&1, &2, cfg, opts, io))
      IO.puts(io, "done: #{inspect(summary)}")
      {:ok, summary}
    end
  end
  ...
end
```

`push_one/5`: when `summary.uploaded >= limit` or `summary.bytes >= max_bytes` → skipped; `dry_run` → skipped after printing; else `Client.head(cfg, L2.object_key(slug, key))` → `{:ok, _}` present; `{:error, :not_found}` → `L2.upload(dir, slug, key, :any, config: cfg)` → `{:ok, bytes}` counts as uploaded and adds `bytes`; `{:error, _}` from the upload or any other `head` error → failed. Print one line per entry: `"<slug>/<key> present|uploaded <n> bytes|failed <reason>|skipped (dry run|limit|max bytes)"`.

`entries/2`: `File.ls(root)` → slugs sorted (filtered to `slug` when given), each `File.ls` → names matching `@key` and `File.dir?` (lstat, not a symlink), sorted; staging names and strays are ignored.

`config/1`: `nil` → `{:error, "build cache L2 is off (NCC_BUILD_CACHE_S3_ENDPOINT unset or incomplete)"}`; `read_only?` → `{:error, "build cache L2 is read-only on this host (NCC_BUILD_CACHE_S3_READ_ONLY=1); the push needs the read-write key"}`.

Mix task `Mix.Tasks.Portal.BuildCache.Push` (`@shortdoc "Push the local build cache into L2"`, `use Mix.Task`): parse `--root`, `--slug`, `--limit`, `--max-gb` (× 1024³), `--dry-run` with `OptionParser`, `Mix.Task.run("app.config")`, call `Push.run/1`, `Mix.raise/1` on `{:error, msg}`. Document in its moduledoc that on a deployed host the same runs as `bin/portal eval 'Portal.BuildCache.L2.Push.run(limit: 500) |> IO.inspect()'`.

- [ ] **Step 3: Run, format, commit**

```bash
mix test apps/portal/test/portal/build_cache/ && mix format && mix compile --warnings-as-errors
git add apps/portal/lib/portal/build_cache/l2/push.ex apps/portal/lib/mix/tasks/portal.build_cache.push.ex apps/portal/test/portal/build_cache/l2/push_test.exs apps/portal/lib/portal/build_cache/l2.ex apps/portal/test/portal/build_cache/l2_test.exs
git commit -m "Build cache L2: bounded, resumable push of an existing local cache

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 10: Docs

**Files:**
- Modify: `DEPLOY.md` (env table rows; new subsection "Shared build cache (L2)" after "Picking a concurrency")
- Create: `docs/BUILD_CACHE_L2.md`
- Modify: `CLAUDE.md` ("Container / Caching Details": one paragraph; "Data Contracts": one line on the object format)
- Modify: `ops/README.md` ("Hosts": one pointer line)

- [ ] **Step 1: DEPLOY.md**

Six rows after `NCC_BUILD_CACHE` in the build-host table:

```
| `NCC_BUILD_CACHE_S3_ENDPOINT` | S3 endpoint of the shared build cache (L2), e.g. `http://100.64.0.2:3900` on the tailnet. Unset means L2 off and builds behave exactly as without it. See [Shared build cache (L2)](#shared-build-cache-l2) |
| `NCC_BUILD_CACHE_S3_BUCKET` | Bucket name, e.g. `ncc-build-cache`. Required with the endpoint |
| `NCC_BUILD_CACHE_S3_REGION` | SigV4 region; Garage uses `garage`, the default |
| `NCC_BUILD_CACHE_S3_ACCESS_KEY` | Key id. The read-write key on home hosts only |
| `NCC_BUILD_CACHE_S3_SECRET_KEY` | Its secret |
| `NCC_BUILD_CACHE_S3_READ_ONLY` | `1` reads from L2 and never uploads, for a host holding the read-only key |
```

Subsection text: what L2 does (one paragraph), the slug caveat (hosts share only under the same image digest, so run the registry image by digest), the key split and why it is the whole trust story (two sentences, link to `docs/BUILD_CACHE_L2.md`), the per-build bounds, the Maintenance-tab line, the push (`mix portal.build_cache.push --limit 500` locally, `bin/portal eval 'Portal.BuildCache.L2.Push.run(limit: 500) |> IO.inspect()'` on a deployed host, resumable), and the Sweep staging rule in one sentence.

- [ ] **Step 2: docs/BUILD_CACHE_L2.md**

Sections: Overview (two paragraphs, link to the spec); Garage on box-b (the NixOS module below, verbatim, with a note that `rpc_secret`, the admin token and the tailnet address are the operator's; `garage.toml` is what the module renders); Layout, bucket and keys (`garage` CLI); Home hosts (the env for `/etc/ncc-portal/portal.env`, restart, the boot line to look for, the Maintenance tab); First push; Verification (`garage bucket info`, a `curl`-free check: the portal log line and the tab); Key rotation; Pruning (not automated: when an image is retired, delete its prefix with `garage`'s `bucket` and object tooling or `mc rm --recursive`, one sentence); What L2 does not do (remote builders, Contabo).

NixOS module:

```nix
{ config, pkgs, ... }:
let
  # The tailnet address of box-b; S3 is served only there.
  tailnetAddr = "100.64.0.2";
in
{
  services.garage = {
    enable = true;
    package = pkgs.garage_1;
    settings = {
      metadata_dir = "/srv/garage/meta";
      data_dir = "/srv/garage/data";
      db_engine = "sqlite";
      replication_factor = 1;
      compression_level = 1;
      rpc_bind_addr = "127.0.0.1:3901";
      rpc_public_addr = "127.0.0.1:3901";
      s3_api = {
        s3_region = "garage";
        api_bind_addr = "${tailnetAddr}:3900";
        root_domain = ".s3.garage.localhost";
      };
      admin = {
        api_bind_addr = "127.0.0.1:3903";
      };
    };
    # rpc_secret and admin_token: 32 random bytes as hex each, kept out of
    # the store (`openssl rand -hex 32`), e.g. via sops-nix or an
    # EnvironmentFile holding GARAGE_RPC_SECRET and GARAGE_ADMIN_TOKEN.
    environmentFile = "/etc/garage/secrets.env";
  };

  systemd.tmpfiles.rules = [
    "d /srv/garage 0750 root root -"
    "d /srv/garage/meta 0750 root root -"
    "d /srv/garage/data 0750 root root -"
  ];

  # Only the tailnet reaches S3; nothing is opened on other interfaces.
  networking.firewall.interfaces."tailscale0".allowedTCPPorts = [ 3900 ];
}
```

Then the CLI (run on box-b as root, `garage` reads `/etc/garage.toml`):

```bash
garage status                                   # note the node id
garage layout assign -z home -c 500G <node-id>  # one zone, one node
garage layout apply --version 1
garage bucket create ncc-build-cache
garage key create ncc-build-cache-rw
garage key create ncc-build-cache-ro
garage bucket allow --read --write ncc-build-cache --key ncc-build-cache-rw
garage bucket allow --read         ncc-build-cache --key ncc-build-cache-ro
garage key info ncc-build-cache-rw --show-secret   # access key id + secret for the home hosts
garage key info ncc-build-cache-ro --show-secret   # for a read-only host, later
```

Note that `environmentFile` and option names must match the NixOS `services.garage` module of the operator's channel; say which release this was written against (NixOS 25.05, `pkgs.garage_1`) and that `garage.toml` keys are stable across 1.x.

- [ ] **Step 3: CLAUDE.md and ops/README.md**

CLAUDE.md, "Container / Caching Details", after the build-cache paragraph: "A second, shared layer sits behind that cache: an S3 bucket (`NCC_BUILD_CACHE_S3_*`, Garage on a homelab host), read by `Portal.Builder` before every build (`Portal.BuildCache.L2.prefetch/3`, the image slug's listing synced into the local cache under a 2 GiB / 5 min budget) and written by `Portal.BuildCache.Promotion` after every local promotion (`Portal.BuildCache.L2.upload/5`). Entries travel as `<slug>/<key>.tar.gz` with `x-amz-meta-sha256`; the downloader re-checks the structure with the same `Portal.BuildCache.Tree` walk Promotion uses, and trusts the content because only holders of the read-write key can upload. Unset endpoint means off. See `docs/BUILD_CACHE_L2.md`." Under "Data Contracts", one bullet: "**Build cache L2 object**: `<image-digest-slug>/<key>.tar.gz`, a gzip tar of one entry (`ebin`, `priv`, `.mix`, …), metadata `x-amz-meta-sha256`; `Portal.BuildCache.L2.Tarball`."

ops/README.md, "Hosts": "The home build hosts also share a build cache through Garage on box-b; see `docs/BUILD_CACHE_L2.md`."

- [ ] **Step 4: Commit**

```bash
git add DEPLOY.md docs/BUILD_CACHE_L2.md CLAUDE.md ops/README.md
git commit -m "Docs: shared build cache L2, Garage setup on box-b, env and push

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

### Task 11: Integration test (Docker; cannot run here)

**Files:**
- Modify: `apps/portal/test/portal/workers/build_integration_test.exs`

- [ ] **Step 1: Add the test** after "promotes jason's own build cache candidate before ingest, over a read-only mount", reusing its setup shape:

```elixir
  # L2 spec, section 7: a promotion on one host becomes a local entry on
  # another. The stub stands in for Garage; the two tmp cache roots stand in
  # for two hosts (the slug is the same image digest on both).
  test "a promoted jason entry is restored into an empty cache on the next build through L2" do
    {:ok, s} = Portal.Test.FakeS3.start()
    previous_l2 = Application.get_env(:portal, Portal.BuildCache.L2, [])
    Application.put_env(:portal, Portal.BuildCache.L2, endpoint: s.endpoint, bucket: s.bucket, region: s.region, access_key: s.access_key, secret_key: s.secret_key)
    previous = Application.get_env(:portal, Portal.Builder, [])
    cache_a = Path.join(System.tmp_dir!(), "ncc-l2-a-#{System.unique_integer([:positive])}")
    cache_b = Path.join(System.tmp_dir!(), "ncc-l2-b-#{System.unique_integer([:positive])}")

    on_exit(fn ->
      Application.put_env(:portal, Portal.BuildCache.L2, previous_l2)
      Application.put_env(:portal, Portal.Builder, previous)
      File.rm_rf(cache_a)
      File.rm_rf(cache_b)
    end)

    image_digest = Builder.image_digest(Builder.docker_image())
    slug = Builder.cache_slug(image_digest)

    # Host A: build, promote, upload.
    Application.put_env(:portal, Portal.Builder, Keyword.put(previous, :build_cache, cache_a))
    {_request, _package, _run} = build_and_ingest("jason", "1.4.4")
    keys_a = cache_a |> Path.join(slug) |> File.ls!() |> Enum.filter(&hex64?/1)
    assert keys_a != []
    for key <- keys_a do
      assert {:ok, %{body: body, meta: %{"x-amz-meta-sha256" => sha}}} = Portal.Test.FakeS3.get_object(s, "#{slug}/#{key}.tar.gz")
      assert sha == :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
    end

    # Host B: empty cache, same image, same bucket. The prefetch runs before
    # the container; the entry is present afterwards with A's contents.
    Application.put_env(:portal, Portal.Builder, Keyword.put(previous, :build_cache, cache_b))
    {:ok, request} = ScanRequests.create_once(%{package_name: "jason", version: "1.4.4", source: :hex_owner, status: :accepted})
    job = %Oban.Job{args: %{"package" => "jason", "version" => "1.4.4", "image_digest" => image_digest, "scan_request_id" => request.id, "force" => true}, attempt: 1, max_attempts: 3}
    assert :ok = Build.perform(job)
    ingest_job = all_enqueued(worker: Ingest) |> Enum.find(&(&1.args["scan_request_id"] == request.id))
    assert {:ok, %{log: log}} = Builder.load_run(ingest_job.args["run_id"])
    assert log =~ ~r/Build cache L2 prefetch for .*: #{length(keys_a)} downloaded/

    for key <- keys_a do
      assert cache_snapshot(Path.join([cache_b, slug, key])) == cache_snapshot(Path.join([cache_a, slug, key]))
    end

    assert :ok = Ingest.perform(%Oban.Job{args: ingest_job.args, attempt: 1, max_attempts: 5})
    Repo.delete!(ingest_job)
  end
```

`cache_snapshot/1` and `hex64?/1` exist in the file; check `cache_snapshot/1` compares relative paths and file hashes (adjust the call if its argument is the root rather than an entry). Check `build_and_ingest/3` accepts `force:`; the second build is a plain `Build.perform` because `build_and_ingest` asserts things about the run that a forced rebuild of the same version may not satisfy; if it does, use it instead.

- [ ] **Step 2: Compile and run the non-integration suite; commit, stating in the message that the test could not be run here**

```bash
mix compile --warnings-as-errors && mix test apps/portal/test/
git add apps/portal/test/portal/workers/build_integration_test.exs
git commit -m "Integration test: promote through L2 on one cache root, restore into another

Not run here: no Docker in this environment.

Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>"
```

---

## After the tasks

Gates (from the root, `source /home/agent/toolchain/env.sh` first), adversarial review, fixes, and `docs/superpowers/plans/2026-10-26-build-cache-l2-notes.md` are run by the orchestrating session, not by a task subagent.
