# Queue Native-Code Filter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Classify bulk-intake Hex packages from registry dependency data before they reach Docker, recording pure-Elixir ones as `pass` with basis `registry_deps` instead of building them.

**Architecture:** `Portal.HexDeps` fetches and verifies per-package registry resources from `repo.hex.pm` with an ETS cache. `Portal.NativeClosure` walks the transitive dependency closure and returns `:pure`, `{:native, reason}` or `{:error, :hex_registry_unavailable}`. `Portal.Catalog.RegistryAssessment` writes a synthetic result through the existing `Portal.Catalog.Ingestion`. `Portal.Workers.Backfill` calls these for `catalog_seed`/`backfill` sources (and `update_check` on already registry-assessed packages) behind the `NCC_QUEUE_FILTER` flag, default off.

**Tech Stack:** Elixir, Phoenix 1.8 LiveView, Ash/AshPostgres, Oban, `:hex_core` (`:hex_registry.unpack_package/4`), Req.

**Spec:** `docs/superpowers/specs/2026-09-30-queue-native-filter-design.md`

## Global Constraints

- Work in the worktree `/Users/tomhoenderdos/Projects/nerves_compatibility-queue-filter`, branch `feat/queue-native-filter`. Do not push. Do not deploy.
- Run every `mix` command from the worktree root (umbrella root). Never run `mix deps.*` inside `apps/*`. Never run `mix precommit` from `apps/portal` (it prunes the shared lock); instead run from the root: `mix format`, `mix compile --warnings-as-errors`, `mix test apps/portal/test/`.
- Registry only: fetch `https://repo.hex.pm/packages/<name>`. Never call the hex.pm API from new code.
- Marker list, verbatim: `elixir_make rustler rustler_precompiled zigler cc_precompiler unifex bundlex`.
- Closure cap: 500 packages.
- Cache TTL: 3600 seconds.
- Basis string: `registry_deps`. System key: `registry_deps`. Run `image_digest`: `"registry"`. Run id: `"registry-<name>-<version>"`.
- Flag: `NCC_QUEUE_FILTER`, parsed `1/true/yes` → on, `0/false/no` → off, anything else leaves the compile-time default. Compile-time default: off.
- Human sources (`admin_manual`, `hex_owner`, `github_repo`, `anonymous_*`) never classify.
- A registry outage (`:hex_registry_unavailable`) must return `{:error, _}` from `Backfill` and must never insert a `Build` job.
- Follow `apps/portal/AGENTS.md` for LiveView/HEEx. Match the surrounding comment style: explanatory `#` comments on *why*, `@moduledoc` on every module.
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Dependency without a `repository` field.** The protobuf field is optional; absent means the same repository (`hexpm`). Treating absent as "non-hexpm" would mark every package native. Pinned in Task 1 (normalised to `"hexpm"`) and Task 2 (a pure closure whose deps omit the field is `:pure`).
2. **Prerelease-only matches.** `~> 1.0` must not resolve to `2.0.0-rc.1`, and a requirement that only a prerelease satisfies (`~> 2.0.0-rc.0`) must still resolve. Pinned in Task 2.
3. **Re-running a classification for a version already recorded.** A second `catalog_seed` sweep, or a Backfill retry after the ingest committed, would hit the unique `run_id`. Must be idempotent. Pinned in Task 3.
4. **An open request already exists for the package** (e.g. someone queued it by hand). The filter must not create a second request or attach a registry run to a queued build. Pinned in Task 4.
5. **Package 404 on the registry** (deleted, or a dependency name that never existed). Must fail closed as native, not crash, and not be treated as an outage. Pinned in Task 1 (`:not_found`) and Task 2.

---

### Task 1: `Portal.HexDeps` — fetch, verify, cache per-package registry resources

**Files:**
- Create: `apps/portal/lib/portal/hex_deps.ex`
- Modify: `apps/portal/lib/portal/application.ex` (add child after `Portal.Catalog.Cache`)
- Test: `apps/portal/test/portal/hex_deps_test.exs`

**Interfaces:**
- Produces:
  - `Portal.HexDeps.releases(name :: String.t(), opts :: keyword()) :: {:ok, [release()]} | {:error, :hex_registry_unavailable | :hex_registry_undecodable | :not_found}`
  - `release() :: %{version: String.t(), retired?: boolean(), deps: [dep()]}`
  - `dep() :: %{package: String.t(), requirement: String.t(), optional: boolean(), repository: String.t()}`
  - Options: `:client` (module with `get/2`, default `Req`), `:public_key` (default hex.pm's), `:cache` (boolean, default `true`).
  - `Portal.HexDeps.flush() :: :ok`
  - Supervised: `Portal.HexDeps` (GenServer owning the named ETS table).

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Portal.HexDepsTest do
  @moduledoc """
  Tests for `Portal.HexDeps`.

  Fixtures are real registry package resources built with
  `:hex_registry.build_package/2` and signed with a key generated here, so the
  gzip, signature check and protobuf decode are exercised exactly as against
  `repo.hex.pm`. See `Portal.HexRegistryTest` for the same approach.
  """

  use ExUnit.Case, async: false

  alias Portal.HexDeps

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  setup do
    HexDeps.flush()
    :ok
  end

  defmodule Client do
    def get(url, _opts) do
      send(self(), {:fetched, URI.parse(url).path})

      case Process.get({:body, URI.parse(url).path}) do
        {:error, _reason} = error -> error
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  defp resource(name, releases, private) do
    releases =
      Enum.map(releases, fn {version, deps, extra} ->
        Map.merge(
          %{version: version, inner_checksum: <<0::256>>, dependencies: deps},
          extra
        )
      end)

    :hex_registry.build_package(
      %{name: name, repository: "hexpm", releases: releases},
      private
    )
  end

  defp serve(name, body), do: Process.put({:body, "/packages/#{name}"}, body)

  defp releases(name, context, opts \\ []) do
    HexDeps.releases(name, [client: Client, public_key: context.public] ++ opts)
  end

  test "decodes releases, dependencies and retirement", context do
    serve(
      "tortoise",
      resource(
        "tortoise",
        [
          {"0.9.0", [], %{retired: %{reason: :RETIRED_SECURITY}}},
          {"0.10.0",
           [
             %{package: "gen_state_machine", requirement: "~> 2.0"},
             %{package: "telemetry", requirement: "~> 1.0", optional: true, repository: "hexpm"}
           ], %{}}
        ],
        context.private
      )
    )

    assert {:ok, [old, new]} = releases("tortoise", context)
    assert old == %{version: "0.9.0", retired?: true, deps: []}
    assert new.version == "0.10.0"
    refute new.retired?

    assert new.deps == [
             %{package: "gen_state_machine", requirement: "~> 2.0", optional: false, repository: "hexpm"},
             %{package: "telemetry", requirement: "~> 1.0", optional: true, repository: "hexpm"}
           ]
  end

  test "a signature from another key is undecodable", context do
    other = :public_key.generate_key({:rsa, 2048, 65_537})
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], other))
    assert releases("jason", context) == {:error, :hex_registry_undecodable}
  end

  test "garbage bytes are undecodable, not a crash", context do
    serve("jason", "not gzip")
    assert releases("jason", context) == {:error, :hex_registry_undecodable}
  end

  test "a 404 is not_found", context do
    assert releases("nope", context) == {:error, :not_found}
  end

  test "HTTP 5xx and transport errors are unavailable", context do
    serve("jason", {:status, 503})
    assert releases("jason", context) == {:error, :hex_registry_unavailable}

    serve("jason", {:error, :timeout})
    assert releases("jason", context) == {:error, :hex_registry_unavailable}
  end

  test "a second call is served from the cache", context do
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, _} = releases("jason", context)
    assert_received {:fetched, "/packages/jason"}

    assert {:ok, _} = releases("jason", context)
    refute_received {:fetched, "/packages/jason"}
  end

  test "errors are not cached", context do
    serve("jason", {:status, 503})
    assert {:error, :hex_registry_unavailable} = releases("jason", context)

    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, [_]} = releases("jason", context)
  end

  test "cache: false always fetches", context do
    serve("jason", resource("jason", [{"1.4.4", [], %{}}], context.private))
    assert {:ok, _} = releases("jason", context, cache: false)
    assert {:ok, _} = releases("jason", context, cache: false)
    assert_received {:fetched, "/packages/jason"}
    assert_received {:fetched, "/packages/jason"}
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/portal/test/portal/hex_deps_test.exs`
Expected: FAIL — `Portal.HexDeps.flush/0 is undefined (module Portal.HexDeps is not available)`.

- [ ] **Step 3: Implement `Portal.HexDeps`**

```elixir
defmodule Portal.HexDeps do
  @moduledoc """
  Reads one package's releases and their dependency lists from `repo.hex.pm`.

  This is the per-package resource of [registry v2][spec], the same signed,
  gzipped protobuf protocol `Portal.HexRegistry` reads for `/names` and
  `/versions`, and it is served from the CDN for the same reason: Hex's team
  asked the project to poll the repository, not the API. `:hex_core` verifies
  the signature and decodes; nothing here parses protobuf.

  [spec]: https://github.com/hexpm/specifications/blob/main/registry-v2.md

  ## Why a cache

  `Portal.NativeClosure` walks a dependency closure per package. Across a sweep
  of thousands of packages the same few hundred dependencies (`jason`,
  `telemetry`, `plug`, ...) recur in almost every closure. Decoded answers are
  kept for an hour -- the resource's own `cache-control` -- so a sweep costs one
  request per distinct package, not one per edge. Errors are never cached: a
  CDN hiccup must not be remembered for an hour.

  The table is node-local and owned by this process, like
  `PortalWeb.WebAuthnSession`'s.
  """

  use GenServer

  require Logger

  @repo_url "https://repo.hex.pm"
  @repository "hexpm"
  @table __MODULE__
  @ttl_seconds 3600

  @type dep :: %{
          package: String.t(),
          requirement: String.t(),
          optional: boolean(),
          repository: String.t()
        }
  @type release :: %{version: String.t(), retired?: boolean(), deps: [dep()]}
  @type error :: :hex_registry_unavailable | :hex_registry_undecodable | :not_found

  @doc """
  Every release of `name`, oldest first, with its dependencies.

  Options: `:client` (module exposing `get/2`, default `Req`), `:public_key`
  (default hex.pm's), `:cache` (default `true`). The first two exist for tests,
  as in `Portal.HexRegistry.snapshot/1`.
  """
  @spec releases(String.t(), keyword()) :: {:ok, [release()]} | {:error, error()}
  def releases(name, opts \\ []) when is_binary(name) do
    cache? = Keyword.get(opts, :cache, true)

    case cache? && cached(name) do
      {:ok, releases} ->
        {:ok, releases}

      _ ->
        with {:ok, releases} <- fetch(name, opts) do
          if cache?, do: :ets.insert(@table, {name, releases, now() + @ttl_seconds})
          {:ok, releases}
        end
    end
  end

  @doc "Drop every cached entry. Exposed for tests and `bin/portal rpc`."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(@table)
    :ok
  end

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, nil}
  end

  defp cached(name) do
    now = now()

    case :ets.lookup(@table, name) do
      [{^name, releases, expires_at}] when expires_at > now -> {:ok, releases}
      _ -> :miss
    end
  end

  defp fetch(name, opts) do
    client = Keyword.get(opts, :client, Req)
    key = Keyword.get(opts, :public_key, public_key())

    # `compressed: false` and `decode_body: false` for the reason documented in
    # `Portal.HexRegistry`: `:hex_core` gunzips the body itself.
    case client.get("#{@repo_url}/packages/#{name}",
           compressed: false,
           decode_body: false,
           receive_timeout: 30_000
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        unpack(name, body, key)

      # The CDN answers 403/404 for a package that does not exist. That is a
      # fact about the package, not an outage, so it must not trigger a retry.
      {:ok, %{status: status}} when status in [403, 404] ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        Logger.warning("Hex registry /packages/#{name} failed: HTTP #{status}")
        {:error, :hex_registry_unavailable}

      {:error, reason} ->
        Logger.warning("Hex registry /packages/#{name} failed: #{inspect(reason)}")
        {:error, :hex_registry_unavailable}
    end
  end

  # try/rescue for the same reason as `Portal.HexRegistry.unpack/3`: a bad
  # signature is an error tuple, but a body that is not gzip raises in `:zlib`.
  defp unpack(name, body, key) do
    case :hex_registry.unpack_package(body, @repository, name, key) do
      {:ok, %{releases: releases}} ->
        {:ok, Enum.map(releases, &normalise/1)}

      {:error, reason} ->
        Logger.warning("Hex registry /packages/#{name} did not decode: #{inspect(reason)}")
        {:error, :hex_registry_undecodable}
    end
  rescue
    error ->
      Logger.warning("Hex registry /packages/#{name} did not decode: #{inspect(error)}")
      {:error, :hex_registry_undecodable}
  end

  # Optional protobuf fields are simply absent from the decoded map. An absent
  # `repository` means the dependency lives in the same repository as the
  # package -- hexpm -- and an absent `optional` means required.
  defp normalise(release) do
    %{
      version: release.version,
      retired?: Map.has_key?(release, :retired),
      deps:
        release
        |> Map.get(:dependencies, [])
        |> Enum.map(fn dep ->
          %{
            package: dep.package,
            requirement: dep.requirement,
            optional: Map.get(dep, :optional, false) in [true, 1],
            repository: Map.get(dep, :repository, @repository)
          }
        end)
    }
  end

  defp public_key, do: :hex_core.default_config()[:repo_public_key]

  defp now, do: System.system_time(:second)
end
```

In `apps/portal/lib/portal/application.ex`, add after `Portal.Catalog.Cache,`:

```elixir
      # Owns the ETS table of decoded per-package registry resources that
      # `Portal.NativeClosure` walks; see `Portal.HexDeps`.
      Portal.HexDeps,
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/portal/test/portal/hex_deps_test.exs`
Expected: PASS, 8 tests.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/hex_deps.ex apps/portal/lib/portal/application.ex apps/portal/test/portal/hex_deps_test.exs
git commit -m "feat(portal): read per-package dependency lists from the hex registry

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `Portal.NativeClosure` — classify a package's transitive closure

**Files:**
- Create: `apps/portal/lib/portal/native_closure.ex`
- Test: `apps/portal/test/portal/native_closure_test.exs`

**Interfaces:**
- Consumes: `Portal.HexDeps.releases/2` (Task 1).
- Produces:
  - `Portal.NativeClosure.classify(name :: String.t(), version :: String.t(), opts :: keyword()) :: :pure | {:native, reason()} | {:error, :hex_registry_unavailable}`. `opts` are passed through to `HexDeps.releases/2`.
  - `reason()` is one of `{:nerves, pkg}`, `{:marker, pkg}`, `{:repository, pkg, repo}`, `{:unknown_version, pkg, version}`, `{:unsatisfiable, pkg, requirement}`, `{:bad_requirement, pkg, requirement}`, `{:registry, pkg, :hex_registry_undecodable | :not_found}`, `:closure_too_large`.
  - `Portal.NativeClosure.dry_run(names :: [String.t()], opts :: keyword()) :: %{pure: non_neg_integer(), native: non_neg_integer(), errors: non_neg_integer(), reasons: %{atom() => non_neg_integer()}}`.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Portal.NativeClosureTest do
  @moduledoc """
  Tests for `Portal.NativeClosure` against locally signed registry resources.
  `cache: false` keeps each test's fake registry from leaking into the next.
  """

  use ExUnit.Case, async: true

  alias Portal.NativeClosure

  setup_all do
    private = :public_key.generate_key({:rsa, 2048, 65_537})
    public = {:RSAPublicKey, elem(private, 2), elem(private, 3)}
    %{private: private, public: public}
  end

  defmodule Client do
    def get(url, _opts) do
      case Process.get({:body, URI.parse(url).path}) do
        {:status, status} -> {:ok, %{status: status, body: ""}}
        body when is_binary(body) -> {:ok, %{status: 200, body: body}}
        nil -> {:ok, %{status: 404, body: ""}}
      end
    end
  end

  # `packages` is `%{name => [{version, [dep]} | {version, [dep], extra}]}`;
  # a dep is `{name, requirement}` or a full dependency map.
  defp registry(packages, context) do
    for {name, releases} <- packages do
      releases =
        Enum.map(releases, fn
          {version, deps} -> release(version, deps, %{})
          {version, deps, extra} -> release(version, deps, extra)
        end)

      body =
        :hex_registry.build_package(
          %{name: name, repository: "hexpm", releases: releases},
          context.private
        )

      Process.put({:body, "/packages/#{name}"}, body)
    end
  end

  defp release(version, deps, extra) do
    deps =
      Enum.map(deps, fn
        {name, req} -> %{package: name, requirement: req}
        %{} = dep -> dep
      end)

    Map.merge(%{version: version, inner_checksum: <<0::256>>, dependencies: deps}, extra)
  end

  defp classify(name, version, context) do
    NativeClosure.classify(name, version, client: Client, public_key: context.public, cache: false)
  end

  test "a closure of pure packages is pure", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"jason", "~> 1.4"}, {"telemetry", "~> 1.0"}]}],
        "jason" => [{"1.4.4", []}],
        "telemetry" => [{"1.3.0", []}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "a direct marker dependency is native", context do
    registry(%{"app" => [{"1.0.0", [{"elixir_make", "~> 0.8"}]}]}, context)
    assert classify("app", "1.0.0", context) == {:native, {:marker, "elixir_make"}}
  end

  test "a marker three levels down is native", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"a", "~> 1.0"}]}],
        "a" => [{"1.0.0", [{"b", "~> 1.0"}]}],
        "b" => [{"1.0.0", [{"rustler_precompiled", "~> 0.7"}]}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == {:native, {:marker, "rustler_precompiled"}}
  end

  test "an optional marker dependency is ignored", context do
    registry(
      %{
        "app" => [
          {"1.0.0", [%{package: "rustler", requirement: "~> 0.30", optional: true}]}
        ]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "a nerves package or dependency is native", context do
    registry(%{"app" => [{"1.0.0", [{"nerves_runtime", "~> 0.13"}]}]}, context)
    assert classify("app", "1.0.0", context) == {:native, {:nerves, "nerves_runtime"}}
    assert classify("nerves_key", "1.0.0", context) == {:native, {:nerves, "nerves_key"}}
  end

  test "resolves the newest release that satisfies the requirement", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        # 2.0.0 would be native, but ~> 1.0 cannot pick it.
        "lib" => [{"1.0.0", [{"zigler", "~> 0.1"}]}, {"1.2.0", []}, {"2.0.0", [{"zigler", "~> 0.1"}]}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
  end

  test "skips a retired release when a live one matches, falls back when none does", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        "lib" => [{"1.0.0", []}, {"1.1.0", [{"unifex", "~> 1.0"}], %{retired: %{reason: :RETIRED_INVALID}}}],
        "only_retired" => [{"1.0.0", [{"bundlex", "~> 1.0"}], %{retired: %{reason: :RETIRED_OTHER}}}],
        "app2" => [{"1.0.0", [{"only_retired", "~> 1.0"}]}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
    assert classify("app2", "1.0.0", context) == {:native, {:marker, "bundlex"}}
  end

  test "prereleases do not satisfy a plain requirement", context do
    registry(
      %{
        "app" => [{"1.0.0", [{"lib", "~> 1.0"}]}],
        "lib" => [{"1.0.0", []}, {"1.1.0-rc.0", [{"elixir_make", "~> 0.8"}]}],
        "pre" => [{"1.0.0", [{"lib2", "~> 2.0.0-rc.0"}]}],
        "lib2" => [{"2.0.0-rc.1", []}]
      },
      context
    )

    assert classify("app", "1.0.0", context) == :pure
    assert classify("pre", "1.0.0", context) == :pure
  end

  test "cycles terminate", context do
    registry(
      %{
        "a" => [{"1.0.0", [{"b", "~> 1.0"}]}],
        "b" => [{"1.0.0", [{"a", "~> 1.0"}]}]
      },
      context
    )

    assert classify("a", "1.0.0", context) == :pure
  end

  test "unresolvable or unreadable closures fail closed as native", context do
    registry(
      %{
        "unsat" => [{"1.0.0", [{"lib", "~> 9.0"}]}],
        "badreq" => [{"1.0.0", [{"lib", "not a requirement"}]}],
        "other_repo" => [{"1.0.0", [%{package: "lib", requirement: "~> 1.0", repository: "acme"}]}],
        "missing_dep" => [{"1.0.0", [{"ghost", "~> 1.0"}]}],
        "lib" => [{"1.0.0", []}]
      },
      context
    )

    assert classify("unsat", "1.0.0", context) == {:native, {:unsatisfiable, "lib", "~> 9.0"}}
    assert classify("badreq", "1.0.0", context) == {:native, {:bad_requirement, "lib", "not a requirement"}}
    assert classify("other_repo", "1.0.0", context) == {:native, {:repository, "lib", "acme"}}
    assert classify("missing_dep", "1.0.0", context) == {:native, {:registry, "ghost", :not_found}}
    assert classify("unsat", "5.0.0", context) == {:native, {:unknown_version, "unsat", "5.0.0"}}
  end

  test "a closure over the size cap is native", context do
    chain =
      for i <- 0..501, into: %{} do
        {"p#{i}", [{"1.0.0", if(i < 501, do: [{"p#{i + 1}", "~> 1.0"}], else: [])}]}
      end

    registry(chain, context)
    assert classify("p0", "1.0.0", context) == {:native, :closure_too_large}
  end

  test "an unavailable registry is an error, not a classification", context do
    registry(%{"app" => [{"1.0.0", [{"lib", "~> 1.0"}]}]}, context)
    Process.put({:body, "/packages/lib"}, {:status, 503})

    assert classify("app", "1.0.0", context) == {:error, :hex_registry_unavailable}
  end

  test "dry_run counts pure, native and errors at each package's newest live release", context do
    registry(
      %{
        "pure" => [{"1.0.0", [{"elixir_make", "~> 0.8"}]}, {"1.1.0", []}],
        "nif" => [{"1.0.0", [{"rustler", "~> 0.30"}]}],
        "down" => [{"1.0.0", [{"lib", "~> 1.0"}]}]
      },
      context
    )

    Process.put({:body, "/packages/lib"}, {:status, 503})

    report =
      NativeClosure.dry_run(["pure", "nif", "down", "gone"],
        client: Client,
        public_key: context.public,
        cache: false
      )

    assert report == %{
             pure: 1,
             native: 2,
             errors: 1,
             reasons: %{marker: 1, registry: 1}
           }
  end
end
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/portal/test/portal/native_closure_test.exs`
Expected: FAIL — `Portal.NativeClosure.classify/3 is undefined`.

- [ ] **Step 3: Implement `Portal.NativeClosure`**

```elixir
defmodule Portal.NativeClosure do
  @moduledoc """
  Decides from registry data alone whether a package could need a Nerves build.

  Cross-compilation is the one thing a firmware build does that a plain
  `mix compile` does not, so a package can only fail on Nerves in an interesting
  way if native code appears somewhere in its transitive dependency closure.
  Registry v2 carries every release's dependency list, so the closure is
  computable from `repo.hex.pm` (via `Portal.HexDeps`) without fetching a
  tarball or running `mix deps.get`.

  Native code is recognised by the build tooling it depends on -- the marker
  list below -- and by `nerves*` names. The known blind spot: a package that
  ships its own `c_src/` with a hand-rolled compiler and no marker dependency,
  or pure Elixir that shells out to a program a Nerves image lacks, looks pure
  here. `NccWorker.BuildSelection` catches both, but only inside a real build.

  ## Fails closed

  Anything this cannot answer with confidence is `{:native, reason}`, which
  sends the package down the normal build path: a version or requirement it
  cannot resolve, a dependency from another repository, a registry resource
  that is missing or does not verify, or a closure larger than 500 packages. The cost of a wrong "native" is one build; the cost of a
  wrong "pure" is a green badge nobody checked.

  The single exception is `:hex_registry_unavailable`. An outage is not a fact
  about the package, and treating it as native would turn a CDN hiccup during a
  seed into thousands of Docker builds, so it comes back as an error for the
  caller to retry.
  """

  alias Portal.HexDeps

  @markers ~w(elixir_make rustler rustler_precompiled zigler cc_precompiler unifex bundlex)
  @max_closure 500

  @type reason ::
          {:nerves, String.t()}
          | {:marker, String.t()}
          | {:repository, String.t(), String.t()}
          | {:unknown_version, String.t(), String.t()}
          | {:unsatisfiable, String.t(), String.t()}
          | {:bad_requirement, String.t(), String.t()}
          | {:registry, String.t(), :hex_registry_undecodable | :not_found}
          | :closure_too_large

  @spec classify(String.t(), String.t(), keyword()) ::
          :pure | {:native, reason()} | {:error, :hex_registry_unavailable}
  def classify(name, version, opts \\ []) do
    if nerves?(name) do
      {:native, {:nerves, name}}
    else
      with {:ok, releases} <- releases(name, opts),
           {:ok, release} <- exact(name, version, releases) do
        walk(release.deps, MapSet.new([name]), opts)
      end
    end
  end

  @doc """
  Classifies each name at its newest live release and writes nothing.

  For a remote console on production (`bin/portal remote`; not `eval`, which
  starts no applications -- see the spec's "Operating it"), to size a sweep before switching the
  filter on. `reasons` counts native verdicts by the reason's first element.
  """
  @spec dry_run([String.t()], keyword()) :: %{
          pure: non_neg_integer(),
          native: non_neg_integer(),
          errors: non_neg_integer(),
          reasons: %{atom() => non_neg_integer()}
        }
  def dry_run(names, opts \\ []) do
    Enum.reduce(names, %{pure: 0, native: 0, errors: 0, reasons: %{}}, fn name, acc ->
      case latest(name, opts) do
        {:ok, version} -> tally(acc, classify(name, version, opts))
        other -> tally(acc, other)
      end
    end)
  end

  defp tally(acc, :pure), do: Map.update!(acc, :pure, &(&1 + 1))
  defp tally(acc, {:error, _}), do: Map.update!(acc, :errors, &(&1 + 1))

  defp tally(acc, {:native, reason}) do
    kind = if is_tuple(reason), do: elem(reason, 0), else: reason

    acc
    |> Map.update!(:native, &(&1 + 1))
    |> Map.update!(:reasons, &Map.update(&1, kind, 1, fn n -> n + 1 end))
  end

  defp latest(name, opts) do
    with {:ok, releases} <- releases(name, opts) do
      stable = Enum.filter(releases, &(not &1.retired? and stable?(&1.version)))

      case newest(stable) || newest(releases) do
        nil -> {:native, {:unknown_version, name, "latest"}}
        release -> {:ok, release.version}
      end
    end
  end

  # Breadth-first: `rest ++ deps` keeps a shallow marker from waiting behind a
  # deep pure subtree. Visited by name, so cycles terminate and each package is
  # resolved once, as Mix resolves one version per package.
  defp walk([], _seen, _opts), do: :pure

  defp walk([dep | rest], seen, opts) do
    cond do
      dep.optional -> walk(rest, seen, opts)
      MapSet.member?(seen, dep.package) -> walk(rest, seen, opts)
      dep.repository != "hexpm" -> {:native, {:repository, dep.package, dep.repository}}
      dep.package in @markers -> {:native, {:marker, dep.package}}
      nerves?(dep.package) -> {:native, {:nerves, dep.package}}
      MapSet.size(seen) >= @max_closure -> {:native, :closure_too_large}
      true -> descend(dep, rest, seen, opts)
    end
  end

  defp descend(dep, rest, seen, opts) do
    with {:ok, releases} <- releases(dep.package, opts),
         {:ok, release} <- resolve(dep, releases) do
      walk(rest ++ release.deps, MapSet.put(seen, dep.package), opts)
    end
  end

  defp releases(name, opts) do
    case HexDeps.releases(name, opts) do
      {:ok, releases} -> {:ok, releases}
      {:error, :hex_registry_unavailable} = error -> error
      {:error, reason} -> {:native, {:registry, name, reason}}
    end
  end

  defp exact(name, version, releases) do
    case Enum.find(releases, &(&1.version == version)) do
      nil -> {:native, {:unknown_version, name, version}}
      release -> {:ok, release}
    end
  end

  # Newest release satisfying the requirement, preferring live releases and
  # falling back to retired ones -- which is what `mix deps.get` does.
  # `allow_pre: false` keeps `~> 1.0` off `1.1.0-rc.0` while still letting a
  # requirement that names a prerelease (`~> 2.0.0-rc.0`) match one.
  defp resolve(dep, releases) do
    case Version.parse_requirement(dep.requirement) do
      {:ok, requirement} ->
        matching = Enum.filter(releases, &matches?(&1.version, requirement))
        live = Enum.reject(matching, & &1.retired?)

        case newest(live) || newest(matching) do
          nil -> {:native, {:unsatisfiable, dep.package, dep.requirement}}
          release -> {:ok, release}
        end

      :error ->
        {:native, {:bad_requirement, dep.package, dep.requirement}}
    end
  end

  defp matches?(version, requirement) do
    case Version.parse(version) do
      {:ok, parsed} -> Version.match?(parsed, requirement, allow_pre: false)
      :error -> false
    end
  end

  defp stable?(version) do
    match?({:ok, %Version{pre: []}}, Version.parse(version))
  end

  defp newest([]), do: nil

  defp newest(releases) do
    releases
    |> Enum.filter(&match?({:ok, _}, Version.parse(&1.version)))
    |> case do
      [] -> nil
      parsable -> Enum.max_by(parsable, &Version.parse!(&1.version), Version)
    end
  end

  defp nerves?(name), do: String.starts_with?(name, "nerves")
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/portal/test/portal/native_closure_test.exs`
Expected: PASS, 13 tests.

If "prereleases do not satisfy a plain requirement" fails on the `pre` case, check `Version.match?/3` semantics on the installed Elixir: with `allow_pre: false`, a prerelease matches only when the requirement itself names a prerelease. Adjust `matches?/2` to pass `allow_pre: false` only when the requirement string contains no `-`, and re-run.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/native_closure.ex apps/portal/test/portal/native_closure_test.exs
git commit -m "feat(portal): classify native code in a package's registry dependency closure

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `Portal.Catalog.RegistryAssessment` — record a pure verdict as a catalog run

**Files:**
- Create: `apps/portal/lib/portal/catalog/registry_assessment.ex`
- Test: `apps/portal/test/portal/catalog/registry_assessment_test.exs`

**Interfaces:**
- Consumes: `Portal.Catalog.Ingestion.ingest/2`, `Portal.Catalog.committed_run/1` (existing).
- Produces:
  - `Portal.Catalog.RegistryAssessment.record(name :: String.t(), version :: String.t(), scan_request_id :: String.t() | nil) :: {:ok, Portal.Catalog.Run.t()} | {:error, term()}`
  - `Portal.Catalog.RegistryAssessment.image_digest() :: String.t()` — returns `"registry"`; Task 4 uses it to recognise registry-assessed runs.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Portal.Catalog.RegistryAssessmentTest do
  use Portal.DataCase, async: false

  alias Portal.Catalog.RegistryAssessment

  test "records a registry_deps pass the catalog reads like any run" do
    assert {:ok, run} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert run.overall_status == :pass
    assert run.image_digest == "registry"
    assert run.run_id == "registry-tiny_pure-1.2.0"

    %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
    assert package.native_components["compatibility_basis"] == "registry_deps"
    assert Map.keys(package.systems) == ["registry_deps"]
    assert package.systems["registry_deps"].status == "pass"
    assert Portal.Catalog.precompiled_manifest("tiny_pure") == nil
  end

  test "recording the same version twice returns the existing run" do
    assert {:ok, first} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert {:ok, second} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert first.id == second.id
  end

  test "a new version adds a run and becomes the latest" do
    assert {:ok, _} = RegistryAssessment.record("tiny_pure", "1.2.0", nil)
    assert {:ok, _} = RegistryAssessment.record("tiny_pure", "1.3.0", nil)

    %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
    assert package.latest_version == "1.3.0"
  end
end
```

Before running, check the shape `Portal.Catalog.latest_by_pkg_json/1` actually returns in `apps/portal/test/portal_web/catalog_live_test.exs:72-74` (the `pure_elixir` test) and match its keys — `package.systems` values there expose `system_pkg`; use whatever field carries the status in that map (grep `latest_by_pkg_json` in `apps/portal/lib/portal/catalog.ex`). Adjust the two `systems` assertions to that shape; do not change the intent.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/portal/test/portal/catalog/registry_assessment_test.exs`
Expected: FAIL — `Portal.Catalog.RegistryAssessment.record/3 is undefined`.

- [ ] **Step 3: Implement `Portal.Catalog.RegistryAssessment`**

```elixir
defmodule Portal.Catalog.RegistryAssessment do
  @moduledoc """
  Records a `Portal.NativeClosure` `:pure` verdict as an ordinary catalog run.

  The verdict goes through `Portal.Catalog.Ingestion` as a `result.json`-shaped
  map with a single `registry_deps` system, so package pages, badges, the
  schema-v2 API and `Portal.Workers.UpdateCheck` read it without knowing it
  never touched Docker. `native_components.compatibility_basis` is what tells
  them apart, the same way #36 marks its `pure_elixir` assessments.

  A `pass` here claims less than any other `pass` in the catalogue: nothing was
  compiled. That was a deliberate choice (see the design spec, 2026-09-30); a
  human request for the package replaces it with a real build.

  `image_digest` is the fixed string `"registry"` rather than a worker image
  digest, which is how `Portal.Workers.Backfill` recognises a package whose
  latest run came from here.
  """

  alias Portal.Catalog
  alias Portal.Catalog.Ingestion

  @image_digest "registry"

  @doc "The `image_digest` every registry-assessed run carries."
  @spec image_digest() :: String.t()
  def image_digest, do: @image_digest

  @spec record(String.t(), String.t(), String.t() | nil) ::
          {:ok, Portal.Catalog.Run.t()} | {:error, term()}
  def record(name, version, scan_request_id) do
    run_id = "registry-#{name}-#{version}"

    # Idempotent on the run id, which is unique: a retried Backfill job whose
    # ingest already committed, or a second seed sweep, returns the run on file
    # instead of tripping the constraint.
    case Catalog.committed_run(run_id) do
      {:ok, %{} = run} -> {:ok, run}
      {:ok, nil} -> ingest(name, version, run_id, scan_request_id)
      {:error, reason} -> {:error, reason}
    end
  end

  defp ingest(name, version, run_id, scan_request_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()

    result = %{
      "package" => %{
        "name" => name,
        "version" => version,
        "description" => nil,
        "native_components" => %{"compatibility_basis" => "registry_deps"}
      },
      "started_at" => now,
      "finished_at" => now,
      "systems" => %{
        "registry_deps" => %{
          "status" => "pass",
          "duration_sec" => 0.0,
          "log_tail" =>
            "Assumed compatible: no native code in the dependency closure on hex.pm. " <>
              "Nothing was compiled."
        }
      }
    }

    # No blobs and no logs: `files_dir` is never read because the system
    # carries no scans, and `output_dir` is omitted so no log is staged.
    Ingestion.ingest(result, %{
      run_id: run_id,
      image_digest: @image_digest,
      files_dir: System.tmp_dir!(),
      scan_request_id: scan_request_id
    })
  end
end
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/portal/test/portal/catalog/registry_assessment_test.exs`
Expected: PASS, 3 tests.

If `Ingestion.ingest/2` rejects a nil `description` or a missing `started_at`, compare with `apps/portal/test/support/fixtures/result.json` and supply what the fixture supplies; keep `systems` to the single `registry_deps` entry.

- [ ] **Step 5: Commit**

```bash
git add apps/portal/lib/portal/catalog/registry_assessment.ex apps/portal/test/portal/catalog/registry_assessment_test.exs
git commit -m "feat(portal): record registry-assessed pure packages as catalog runs

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Flag and `Portal.Workers.Backfill` wiring

**Files:**
- Modify: `apps/portal/config/config.exs` (add default near `config :portal, Portal.Workers.UpdateCheck, enabled: true`)
- Modify: `config/runtime.exs` (add `NCC_QUEUE_FILTER` block after the `NCC_UPDATE_CHECK` block)
- Modify: `apps/portal/lib/portal/workers/backfill.ex`
- Test: `apps/portal/test/portal/workers/backfill_test.exs`

**Interfaces:**
- Consumes: `Portal.NativeClosure.classify/3` (Task 2), `Portal.Catalog.RegistryAssessment.record/3` and `image_digest/0` (Task 3), `Portal.ScanRequests.create_once/1`, `open_request_for_package/1`, `set_status/3` (existing).
- Produces:
  - Config key `config :portal, :queue_filter, enabled: boolean()`.
  - App-env injection point `:native_closure` (module exposing `classify/2`), default `Portal.NativeClosure`, for tests.

- [ ] **Step 1: Write the failing tests**

Append to `apps/portal/test/portal/workers/backfill_test.exs`, inside the module, after the existing `describe`:

```elixir
  defmodule StubClosure do
    def classify(package, _version) do
      Process.get({:closure, package}, {:native, {:marker, "elixir_make"}})
    end
  end

  describe "perform/1 with the queue filter" do
    setup do
      Application.put_env(:portal, :native_closure, StubClosure)
      Application.put_env(:portal, :queue_filter, enabled: true)

      on_exit(fn ->
        Application.delete_env(:portal, :native_closure)
        Application.delete_env(:portal, :queue_filter)
      end)

      :ok
    end

    defp closure(package, answer), do: Process.put({:closure, package}, answer)

    defp request(package) do
      Portal.Repo.one!(
        from(r in "portal_scan_requests",
          where: r.package_name == ^package,
          select: %{status: r.status, run_id: r.run_id}
        )
      )
    end

    test "a pure seed package is recorded without a build" do
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})

      refute_enqueued(worker: Build)
      assert %{status: "built", run_id: run_id} = request("tiny_pure")
      assert run_id

      %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
      assert package.native_components["compatibility_basis"] == "registry_deps"
    end

    test "a native seed package takes the build path" do
      closure("nif_pkg", {:native, {:marker, "rustler"}})

      assert :ok = perform_job(Backfill, %{package: "nif_pkg", source: "catalog_seed"})
      assert build_priority("nif_pkg") == 9
    end

    test "the legacy backfill source is filtered too" do
      closure("tiny_pure", :pure)
      assert :ok = perform_job(Backfill, %{package: "tiny_pure"})
      refute_enqueued(worker: Build)
    end

    test "a registry outage retries and never builds" do
      closure("tiny_pure", {:error, :hex_registry_unavailable})

      assert {:error, :hex_registry_unavailable} =
               perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})

      refute_enqueued(worker: Build)
    end

    test "an already open request is left to its build" do
      closure("queued_pkg", :pure)

      {:ok, _} =
        Portal.ScanRequests.create_once(%{package_name: "queued_pkg", source: :admin_manual})

      assert :ok = perform_job(Backfill, %{package: "queued_pkg", source: "catalog_seed"})

      assert %{packages: packages} = Portal.Catalog.latest_by_pkg_json("queued_pkg")
      refute Map.has_key?(packages, "queued_pkg")
    end

    test "update_check re-classifies a registry-assessed package" do
      {:ok, _} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.0.0", nil)
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "update_check"})

      refute_enqueued(worker: Build)

      %{packages: %{"tiny_pure" => package}} = Portal.Catalog.latest_by_pkg_json("tiny_pure")
      assert package.latest_version == "9.9.9"
    end

    test "update_check on a registry-assessed package that turned native builds it" do
      {:ok, _} = Portal.Catalog.RegistryAssessment.record("grew_nif", "1.0.0", nil)
      closure("grew_nif", {:native, {:marker, "rustler_precompiled"}})

      assert :ok = perform_job(Backfill, %{package: "grew_nif", source: "update_check"})
      assert build_priority("grew_nif") == 7
    end

    test "update_check on a docker-built package never classifies" do
      closure("real_pkg", :pure)

      package =
        Ash.create!(Portal.Catalog.Package, %{name: "real_pkg", latest_version: "1.0.0"},
          action: :create,
          domain: Portal.Catalog
        )

      Ash.create!(
        Portal.Catalog.Run,
        %{
          run_id: "real_pkg-docker",
          package_id: package.id,
          version_tested: "1.0.0",
          image_digest: "sha256:abc",
          overall_status: :pass,
          finished_at: DateTime.utc_now()
        },
        action: :create,
        domain: Portal.Catalog
      )

      assert :ok = perform_job(Backfill, %{package: "real_pkg", source: "update_check"})
      assert build_priority("real_pkg") == 7
    end

    test "the flag off keeps today's behaviour" do
      Application.put_env(:portal, :queue_filter, enabled: false)
      closure("tiny_pure", :pure)

      assert :ok = perform_job(Backfill, %{package: "tiny_pure", source: "catalog_seed"})
      assert build_priority("tiny_pure") == 9
    end
  end
```

If the existing `Portal.Catalog.Run` `:create` action does not accept `image_digest` in tests (check `apps/portal/lib/portal/catalog/run.ex:28-40`; it is listed there), keep the attribute; otherwise drop it and assert only on the build.

- [ ] **Step 2: Run tests to verify they fail**

Run: `mix test apps/portal/test/portal/workers/backfill_test.exs`
Expected: FAIL — "a pure seed package is recorded without a build" enqueues a `Build`; other filter tests fail similarly. The three pre-existing tests still pass.

- [ ] **Step 3: Add the flag**

In `apps/portal/config/config.exs`, directly after `config :portal, Portal.Workers.UpdateCheck, enabled: true`:

```elixir

# Registry-based native-code filter for bulk intake (`catalog_seed`,
# `backfill`). Off by default so a deploy changes nothing until
# `NCC_QUEUE_FILTER=1` is set. See `Portal.Workers.Backfill` and
# `Portal.NativeClosure`.
config :portal, :queue_filter, enabled: false
```

In `config/runtime.exs`, directly after the `NCC_UPDATE_CHECK` `case ... end` block:

```elixir

  # Same parsing, and the same reasoning about typos, as `NCC_UPDATE_CHECK`.
  case System.get_env("NCC_QUEUE_FILTER") do
    v when v in ["1", "true", "yes"] ->
      config :portal, :queue_filter, enabled: true

    v when v in ["0", "false", "no"] ->
      config :portal, :queue_filter, enabled: false

    _ ->
      :ok
  end
```

- [ ] **Step 4: Wire the filter into `Backfill`**

Replace `build/2` in `apps/portal/lib/portal/workers/backfill.ex` and add helpers. Add to the moduledoc, before the closing `"""`:

```elixir
  ## The queue filter

  With `NCC_QUEUE_FILTER` on, bulk sources (`catalog_seed`, `backfill`) are
  classified from registry data before any build is queued. A package with no
  native code in its dependency closure (`Portal.NativeClosure`) is recorded as
  a `registry_deps` pass (`Portal.Catalog.RegistryAssessment`) and never reaches
  Docker. Everything else takes the ordinary path.

  `update_check` is classified only for a package whose latest run was itself a
  registry assessment. Without that, every minor release of the ~18k packages a
  filtered seed adds would go straight to Docker through `UpdateCheck`. A
  package with a real build history keeps being rebuilt for real.

  Human sources never come through this worker. A registry outage returns an
  error and Oban retries: falling through to a build would turn a CDN hiccup
  during a seed into thousands of Docker runs.
```

Code:

```elixir
  import Ecto.Query, only: [from: 2]

  alias Portal.Catalog.RegistryAssessment
  alias Portal.ScanRequests

  defp build(package, source) do
    if classify?(package, source) do
      classify(package, source)
    else
      request(package, source)
    end
  end

  defp request(package, source) do
    case ScanRequests.create_once(%{package_name: package, source: source}) do
      {:ok, _request} ->
        :ok

      # hex.pm does not have it (renamed, retired, or upstream-only). Retrying
      # will not change that, so stop rather than burn five attempts.
      {:error, reason} when reason in [:unknown_package, :unknown_package_version] ->
        Logger.info("Backfill skipping #{package}: #{inspect(reason)}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # An open request means someone -- often a human -- already has a build on
  # the way. Classifying on top of it would attach a registry run to a queued
  # build, so it is left alone.
  defp classify?(package, source) do
    filter_enabled?() and eligible?(package, source) and
      is_nil(ScanRequests.open_request_for_package(package))
  end

  defp eligible?(_package, source) when source in [:catalog_seed, :backfill], do: true
  defp eligible?(package, :update_check), do: registry_assessed?(package)
  defp eligible?(_package, _source), do: false

  defp classify(package, source) do
    case version_resolver().latest_version(package) do
      {:ok, version} ->
        case native_closure().classify(package, version) do
          :pure ->
            record(package, version, source)

          {:native, reason} ->
            Logger.info("Queue filter: #{package} #{version} is native: #{inspect(reason)}")
            request(package, source)

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} when reason in [:unknown_package, :unknown_package_version] ->
        Logger.info("Backfill skipping #{package}: #{inspect(reason)}")
        {:cancel, reason}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # The request is created already `built` so `create_once/1` queues nothing,
  # then linked to the run once it exists -- the same end state an ordinary
  # build reaches through `Portal.Workers.Ingest`.
  defp record(package, version, source) do
    with {:ok, request} <-
           ScanRequests.create_once(%{
             package_name: package,
             version: version,
             source: source,
             status: :built
           }),
         {:ok, run} <- RegistryAssessment.record(package, version, request.id),
         {:ok, _request} <- ScanRequests.set_status(request, :built, run_id: run.id) do
      :ok
    end
  end

  # Two columns from the newest run, not the Ash resource: the run row carries
  # the full runner log, and this only needs to know where the run came from.
  defp registry_assessed?(package) do
    digest =
      Portal.Repo.one(
        from(r in "catalog_runs",
          join: p in "catalog_packages",
          on: p.id == r.package_id,
          where: p.name == ^package,
          order_by: [desc: r.finished_at, desc: r.inserted_at],
          limit: 1,
          select: r.image_digest
        )
      )

    digest == RegistryAssessment.image_digest()
  end

  defp filter_enabled? do
    :portal |> Application.get_env(:queue_filter, []) |> Keyword.get(:enabled, false)
  end

  defp native_closure, do: Application.get_env(:portal, :native_closure, Portal.NativeClosure)

  defp version_resolver,
    do: Application.get_env(:portal, :package_version_resolver, Portal.HexPm)
```

The existing `defp build/2` body becomes `request/2` above; delete the old `build/2`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `mix test apps/portal/test/portal/workers/backfill_test.exs apps/portal/test/portal/workers/update_check_test.exs apps/portal/test/portal/catalog_seed_test.exs`
Expected: PASS, all tests.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/config/config.exs config/runtime.exs apps/portal/lib/portal/workers/backfill.ex apps/portal/test/portal/workers/backfill_test.exs
git commit -m "feat(portal): filter bulk intake on registry native-code closure

Behind NCC_QUEUE_FILTER, default off.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Presentation and docs

**Files:**
- Modify: `apps/portal/lib/portal_web/live/package_live.ex` (assumption paragraph ~line 103, system label ~line 130, version div ~line 132, `describe/3` ~line 297)
- Modify: `docs/INDEX_FORMAT.md` (after the "Pure-Elixir compatibility assessment" paragraph, ~line 239)
- Test: `apps/portal/test/portal_web/catalog_live_test.exs`

**Interfaces:**
- Consumes: `Portal.Catalog.RegistryAssessment.record/3` (Task 3).

- [ ] **Step 1: Write the failing test**

Add after the `"pure Elixir assessment is distinguished from tested firmware"` test:

```elixir
  test "registry assessment says nothing was compiled", %{conn: conn} do
    {:ok, _run} = Portal.Catalog.RegistryAssessment.record("tiny_pure", "1.2.0", nil)

    {:ok, view, html} = live(conn, "/packages/tiny_pure")

    assert has_element?(view, "#compatibility-assumption", "Nothing was compiled")
    assert has_element?(view, "#system-registry-deps", "Pure Elixir (dependency check)")
    assert has_element?(view, "#system-registry-deps td:nth-child(2) span", "pass")
    refute has_element?(view, "#system-registry-deps", "host")
    assert html =~ "no native code in its dependency closure on hex.pm"
    assert conn |> get("/badge/tiny_pure.svg") |> response(200) =~ ~s(aria-label="nerves: passing")
  end
```

Check `dom_id/1` in `package_live.ex` produces `registry-deps` for `"registry_deps"` (the existing test relies on `pure_elixir` → `pure-elixir`); adjust the selector if it differs.

- [ ] **Step 2: Run test to verify it fails**

Run: `mix test apps/portal/test/portal_web/catalog_live_test.exs`
Expected: FAIL — no `#compatibility-assumption` element; label renders `registry_deps`.

- [ ] **Step 3: Implement the presentation**

In `package_live.ex`, replace the single assumption paragraph with two:

```heex
        <p
          :if={Enum.any?(@systems, &(&1.system_pkg == "pure_elixir"))}
          id="compatibility-assumption"
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm text-base-content/80"
        >
          Assumed compatible: this package and its resolved dependencies passed host compilation
          and were identified as pure Elixir. No firmware targets were built.
        </p>

        <p
          :if={Enum.any?(@systems, &(&1.system_pkg == "registry_deps"))}
          id="compatibility-assumption"
          class="rounded-xl border border-base-300 bg-base-200/50 p-4 text-sm text-base-content/80"
        >
          Assumed compatible: no package in this release's dependency closure on hex.pm uses
          native code. Nothing was compiled.
        </p>
```

Replace the label and version lines:

```heex
                  <div class="font-mono font-medium text-base-content">
                    {system_label(system.system_pkg)}
                  </div>
                  <div :if={not assessment?(system.system_pkg)} class="text-base-content/50">
                    {system.system_version || "host"}
                  </div>
```

Add private helpers near `describe/3`:

```elixir
  # Checks that are verdicts rather than builds: they have no system version to
  # show and read differently in the summary.
  defp assessment?(system_pkg), do: system_pkg in ["pure_elixir", "registry_deps"]

  defp system_label("pure_elixir"), do: "Pure Elixir"
  defp system_label("registry_deps"), do: "Pure Elixir (dependency check)"
  defp system_label(system_pkg), do: system_pkg
```

In `describe/3`, replace the `case` head and add a first clause:

```elixir
    head =
      case {basis(systems), length(systems), Enum.count(systems, &(&1.status == "pass"))} do
        {"registry_deps", _, _} ->
          "#{name} #{version} is assumed Nerves-compatible: no native code in its dependency closure on hex.pm; not compiled."

        {"pure_elixir", _, _} ->
          "#{name} #{version} is assumed Nerves-compatible after pure-Elixir inspection and host compilation."

        {nil, 0, _} ->
          "#{name} has not been built against any Nerves system yet."

        {nil, total, total} ->
          "#{name} #{version} builds on all #{total} tracked Nerves systems."

        {nil, total, 0} ->
          "#{name} #{version} fails on all #{total} tracked Nerves systems."
```

Keep every remaining clause of the original `case`, replacing its leading `false` with `nil`. Add:

```elixir
  defp basis(systems) do
    Enum.find_value(systems, fn system ->
      if assessment?(system.system_pkg), do: system.system_pkg
    end)
  end
```

In `docs/INDEX_FORMAT.md`, after the paragraph ending "Existing queued requests use the same selection when processed.", add:

```markdown

### Registry dependency assessment

Packages seeded in bulk may instead carry a single `registry_deps` system entry
with `status: "pass"`. This means **assumed compatible from registry data
alone**: no package in the release's transitive dependency closure on hex.pm
depends on native build tooling (`elixir_make`, `rustler`,
`rustler_precompiled`, `zigler`, `cc_precompiler`, `unifex`, `bundlex`) or is a
`nerves*` package. Nothing was compiled, not even on the host. Package metadata
exposes `native_components.compatibility_basis: "registry_deps"`. A requested
scan of the package replaces the assessment with a real build.
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `mix test apps/portal/test/portal_web/catalog_live_test.exs`
Expected: PASS, including the existing `pure_elixir` test.

- [ ] **Step 5: Full verification from the umbrella root**

Run: `mix format && mix compile --warnings-as-errors && mix test`
Expected: all tests pass, no warnings. Then `git diff --stat mix.lock` — must be empty.

- [ ] **Step 6: Commit**

```bash
git add apps/portal/lib/portal_web/live/package_live.ex apps/portal/test/portal_web/catalog_live_test.exs docs/INDEX_FORMAT.md
git commit -m "feat(portal): label registry-assessed packages as not compiled

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
