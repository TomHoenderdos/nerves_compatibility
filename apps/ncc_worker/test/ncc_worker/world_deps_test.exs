defmodule NccWorker.WorldDepsTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, DepsLock, JsonWriter, Portability, Worker, WorldDeps}

  @moduletag :tmp_dir

  @toolchain %{elixir: "1.20.5", erlang: "28", mix: "1.20.5", nerves_bootstrap: "absent"}

  # The prod package set of a `mix phx.new` 1.8.16 app.
  @phx ~w(bandit db_connection decimal dns_cluster ecto ecto_sql esbuild expo finch gettext hpax
          idna jason mime mint nimble_options nimble_pool phoenix phoenix_ecto phoenix_html
          phoenix_live_dashboard phoenix_live_view phoenix_pubsub phoenix_template plug
          plug_crypto postgrex req swoosh tailwind telemetry telemetry_metrics telemetry_poller
          thousand_island websock websock_adapter)

  # A Hex registry in miniature: each package's dependencies, `{name,
  # optional?}`, as the shape of phoenix 1.8's tree, cowboy side included.
  @registry %{
    "phoenix" => [
      {"plug", false},
      {"plug_crypto", false},
      {"telemetry", false},
      {"phoenix_pubsub", false},
      {"phoenix_template", false},
      {"websock_adapter", false},
      {"bandit", true},
      {"jason", true},
      {"phoenix_view", true},
      {"plug_cowboy", true}
    ],
    "plug" => [{"mime", false}, {"plug_crypto", false}, {"telemetry", false}],
    "plug_crypto" => [],
    "telemetry" => [],
    "mime" => [],
    "phoenix_pubsub" => [],
    "phoenix_template" => [{"phoenix_html", true}],
    "phoenix_html" => [],
    "phoenix_view" => [{"phoenix_html", true}, {"phoenix_template", false}],
    "websock_adapter" => [
      {"plug", false},
      {"websock", false},
      {"bandit", true},
      {"plug_cowboy", true}
    ],
    "websock" => [],
    "bandit" => [
      {"thousand_island", false},
      {"plug", false},
      {"websock", false},
      {"hpax", false},
      {"telemetry", false}
    ],
    "thousand_island" => [{"telemetry", false}],
    "hpax" => [],
    "jason" => [{"decimal", true}],
    "decimal" => [],
    "plug_cowboy" => [{"cowboy", false}, {"plug", false}],
    "cowboy" => [{"cowlib", false}, {"ranch", false}],
    "cowlib" => [],
    "ranch" => [],
    "esbuild" => [{"jason", false}],
    # A chain of optional dependencies deeper than the round cap.
    "c0" => [{"c1", true}],
    "c1" => [{"c2", true}],
    "c2" => [{"c3", true}],
    "c3" => [{"c4", true}],
    "c4" => [{"c5", true}],
    "c5" => [{"c6", true}],
    "c6" => [{"c7", true}],
    "c7" => []
  }

  # `mix deps.get` against `@registry`: the lock is everything reachable
  # from `mix.exs`'s top-level dependencies over non-optional edges, which is
  # Mix's rule (an optional dependency resolves only when something else
  # requires it). Records each call.
  defp registry_deps_get(test_pid, registry \\ @registry) do
    fn project_dir, _env ->
      send(test_pid, :deps_get)
      top = top_level(project_dir)
      write_lock(project_dir, resolve(registry, top, MapSet.new()), registry)
      :ok
    end
  end

  defp top_level(project_dir) do
    ~r/\{:([a-z0-9_]+),/
    |> Regex.scan(File.read!(Path.join(project_dir, "mix.exs")), capture: :all_but_first)
    |> List.flatten()
  end

  defp resolve(_registry, [], seen), do: seen

  defp resolve(registry, [name | rest], seen) do
    if MapSet.member?(seen, name) do
      resolve(registry, rest, seen)
    else
      required = for {dep, false} <- Map.fetch!(registry, name), do: dep
      resolve(registry, required ++ rest, MapSet.put(seen, name))
    end
  end

  defp write_lock(project_dir, names, registry) do
    entries =
      Enum.map_join(names, "\n", fn name ->
        deps =
          Enum.map_join(Map.fetch!(registry, name), ", ", fn {dep, optional} ->
            ~s|{:#{dep}, "~> 1.0", [hex: :#{dep}, repo: "hexpm", optional: #{optional}]}|
          end)

        ~s|  "#{name}": {:hex, :#{name}, "1.0.0", "i-#{name}", [:mix], [#{deps}], "hexpm", "o-#{name}"},|
      end)

    File.write!(Path.join(project_dir, "mix.lock"), "%{\n#{entries}\n}\n")
  end

  # A plain toolchain project with `package` added and `deps.get` run.
  defp project(dir, package) do
    proj = Path.join([dir, "work", "proj"])
    File.mkdir_p!(Path.join([proj, "_build", "host"]))

    File.write!(
      Path.join(proj, "mix.exs"),
      "defp deps do\n  [\n    {:#{package}, \"1.0.0\"}\n  ]\nend\n"
    )

    :ok = registry_deps_get(self()).(proj, [])
    assert_received :deps_get
    proj
  end

  defp lock_names(proj), do: proj |> DepsLock.lock() |> elem(1) |> Map.keys() |> Enum.sort()

  defp paths(dir) do
    out = Path.join(dir, "out")
    File.mkdir_p!(Path.join(out, "logs"))
    %{work_dir: Path.join(dir, "work"), output_dir: out, logs_dir: Path.join(out, "logs")}
  end

  @traced_pass %{
    status: :pass,
    reason: nil,
    observations: %{"trace_stats" => %{"judge_compile" => "finished"}},
    compile_env: [],
    compile_inputs: []
  }

  # Records each traced compile's lock and releases snapshot.
  defp recording_trace(test_pid, status \\ :pass) do
    fn project_dir, _package, _paths, opts ->
      send(test_pid, {:traced, lock_names(project_dir), opts[:releases]})
      error = if status == :pass, do: nil, else: "boom"
      %{host: %{status: status, error: error}, verdict: @traced_pass}
    end
  end

  describe "DepsLock.unresolved_optional_deps_in_closure/2" do
    test "finds optional deps of closure members, not only the package's", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")

      assert DepsLock.unresolved_optional_deps(proj, "esbuild") == []

      assert [%{app: "decimal", package: "decimal", requirement: "~> 1.0"}] =
               DepsLock.unresolved_optional_deps_in_closure(proj, "esbuild")
    end

    test "names each dep once, sorted, however many members declare it", %{tmp_dir: dir} do
      proj = project(dir, "phoenix")

      assert ~w(bandit jason phoenix_html phoenix_view plug_cowboy) ==
               proj
               |> DepsLock.unresolved_optional_deps_in_closure("phoenix")
               |> Enum.map(& &1.app)
    end
  end

  describe "resolve/4" do
    test "decimal is added under jason, in a second round", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")

      assert {:ok, %{added: ["decimal"], rounds: 2}} =
               WorldDeps.resolve(proj, "esbuild", @phx, deps_get: registry_deps_get(self()))

      assert "decimal" in lock_names(proj)
    end

    test "phoenix gets bandit, jason, decimal and phoenix_html, and not cowboy",
         %{tmp_dir: dir} do
      proj = project(dir, "phoenix")

      assert {:ok, %{added: added, rounds: 3}} =
               WorldDeps.resolve(proj, "phoenix", @phx, deps_get: registry_deps_get(self()))

      assert added == ~w(bandit jason phoenix_html decimal)
      names = lock_names(proj)

      for name <- ~w(bandit jason decimal phoenix_html thousand_island hpax),
          do: assert(name in names)

      for name <- ~w(cowboy cowlib ranch plug_cowboy phoenix_view), do: refute(name in names)
      assert WorldDeps.set_aside(proj, "phoenix", @phx) == ~w(phoenix_view plug_cowboy)
    end

    test "nothing to add converges in one round without a deps.get", %{tmp_dir: dir} do
      proj = project(dir, "phoenix")

      assert {:ok, %{added: [], rounds: 1}} =
               WorldDeps.resolve(proj, "phoenix", ~w(plug), deps_get: registry_deps_get(self()))

      refute_received :deps_get
    end

    test "the round cap holds", %{tmp_dir: dir} do
      proj = project(dir, "c0")
      members = ~w(c1 c2 c3 c4 c5 c6 c7)

      assert {:error, "world_not_converged", ["c6"], %{added: added, rounds: 6}} =
               WorldDeps.resolve(proj, "c0", members, deps_get: registry_deps_get(self()))

      assert added == ~w(c1 c2 c3 c4 c5)
      for _ <- 1..5, do: assert_received(:deps_get)
      refute_received :deps_get

      assert {:error, "world_not_converged", ["c2"], %{rounds: 2}} =
               WorldDeps.resolve(project(Path.join(dir, "b"), "c0"), "c0", members,
                 deps_get: registry_deps_get(self()),
                 max_rounds: 2
               )
    end

    test "a failed deps.get stops the fixpoint and puts the project back", %{tmp_dir: dir} do
      proj = project(dir, "phoenix")
      lock = File.read!(Path.join(proj, "mix.lock"))

      assert {:error, "deps_get_failed", {:deps_get_failed, "nope"}, %{added: [], rounds: 1}} =
               WorldDeps.resolve(proj, "phoenix", @phx,
                 deps_get: fn _p, _env -> {:error, {:deps_get_failed, "nope"}} end
               )

      assert File.read!(Path.join(proj, "mix.lock")) == lock
    end

    test "a lock that breaks the policy stops it", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")

      git_lock = fn p, _env ->
        File.write!(
          Path.join(p, "mix.lock"),
          ~s|%{"decimal": {:git, "https://example.invalid/decimal.git", "abc", []}}\n|
        )
      end

      assert {:error, "lock_policy_violation", :policy_violation, _} =
               WorldDeps.resolve(proj, "esbuild", @phx, deps_get: git_lock)
    end

    test "a dependency outside the closure is a stray", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")
      resolve = registry_deps_get(self())

      stray = fn p, env ->
        :ok = resolve.(p, env)
        lock = File.read!(Path.join(p, "mix.lock"))
        cowboy = ~s|  "ranch": {:hex, :ranch, "1.0.0", "i", [:mix], [], "hexpm", "o-ranch"},\n}|
        File.write!(Path.join(p, "mix.lock"), String.replace(lock, ~r/}\s*\z/, cowboy))
      end

      assert {:error, "world_extra_deps", ["ranch"], %{added: ["decimal"]}} =
               WorldDeps.resolve(proj, "esbuild", @phx, deps_get: stray)
    end
  end

  describe "validate/2" do
    test "accepts the phx world" do
      assert {:ok, %{name: "phx", members: @phx}} = WorldDeps.validate("phx", @phx)
    end

    test "refuses a bad name, a bad member, duplicates, an empty or long list, tooling" do
      for {name, members} <- [
            {"Phx", @phx},
            {nil, @phx},
            {"phx\n", @phx},
            {"phx", []},
            {"phx", "jason"},
            {"phx", nil},
            {"phx", ["jason", "Decimal"]},
            {"phx", ["jason", "1x"]},
            {"phx", ["jason", "de-cimal"]},
            {"phx", ["jason\n"]},
            {"phx", ["jason", 1]},
            {"phx", ["jason", "jason"]},
            {"phx", ["jason", "igniter"]},
            {"phx", ["jason", String.duplicate("a", 65)]},
            {"phx", for(i <- 1..201, do: "m#{i}")}
          ] do
        assert {:error, {:invalid_world, _}} = WorldDeps.validate(name, members),
               "accepted #{inspect({name, members})}"
      end
    end
  end

  describe "NCC_INPUT" do
    defp parse(map), do: map |> JSON.encode!() |> CLI.parse_input()

    test "a world build carries its name and members" do
      assert {:ok, %{optional_deps: "world", world: "phx", world_members: @phx}} =
               parse(%{"optional_deps" => "world", "world" => "phx", "world_members" => @phx})
    end

    test "the nested form is normalised to the same keys" do
      assert {:ok, %{world: "phx", world_members: @phx}} =
               parse(%{
                 "optional_deps" => "world",
                 "world" => %{"name" => "phx", "members" => @phx}
               })
    end

    test "invalid members, a missing world or a world without the request exit 10" do
      for input <- [
            %{"optional_deps" => "world"},
            %{"optional_deps" => "world", "world" => "phx"},
            %{"optional_deps" => "world", "world" => "phx", "world_members" => ["Bad"]},
            %{"optional_deps" => "world", "world" => "phx", "world_members" => ["a", "a"]},
            %{
              "optional_deps" => "world",
              "world" => %{"name" => "phx", "members" => @phx},
              "world_members" => @phx
            },
            %{"optional_deps" => "include", "world" => "phx", "world_members" => @phx},
            %{"world_members" => @phx}
          ] do
        assert {:error, {:invalid_world, _}} = outcome = parse(input)
        assert CLI.exit_code(outcome) == 10
      end
    end
  end

  describe "a world toolchain run" do
    defp input(dir, package) do
      out = Path.join(dir, "out")

      %{
        run_id: "r1",
        mode: "toolchain",
        optional_deps: "world",
        world: "phx",
        world_members: @phx,
        started_at: System.monotonic_time(:second),
        image: %{name: "x", digest: "sha256:x"},
        package: %{name: package, version: "1.0.0"},
        paths: %{
          work_dir: Path.join(dir, "work"),
          output_dir: out,
          files_dir: Path.join(out, "files")
        }
      }
    end

    test "the judge compiles once, after the last deps.get, and the result says world:phx",
         %{tmp_dir: dir} do
      proj = project(dir, "phoenix")

      assert {:ok, result} =
               Worker.toolchain_project(proj, input(dir, "phoenix"), paths(dir), @toolchain,
                 host_trace: recording_trace(self()),
                 deps_get: registry_deps_get(self())
               )

      assert_received {:traced, names, releases}
      refute_received {:traced, _, _}
      assert "decimal" in names
      assert releases == Portability.lock_snapshot(proj)

      assert result.requested_optional_deps == "world:phx"

      assert %{
               added: ~w(bandit jason phoenix_html decimal),
               dropped: [],
               skipped: ~w(phoenix_view plug_cowboy),
               reason: nil,
               world: "phx",
               rounds: 3
             } == result.optional_deps

      assert Map.has_key?(result.deps_lock, "decimal")
      refute Map.has_key?(result.deps_lock, "cowboy")
      # Judged as any build (here there is no host build to publish).
      assert result.toolchain_build.status == "skipped"
      assert result.toolchain_build.judge_revision
      refute result.toolchain_build.reason =~ "world closure"
    end

    test "a failed deps.get is a skipped build with no files, never a fallback",
         %{tmp_dir: dir} do
      proj = project(dir, "phoenix")
      paths = paths(dir)
      input = input(dir, "phoenix")

      worker = fn input ->
        Worker.toolchain_project(proj, input, paths, @toolchain,
          host_trace: fn _, _, _, _ -> flunk("compiled without the world") end,
          deps_get: fn _p, _env -> {:error, {:deps_get_failed, "no network"}} end
        )
      end

      assert :ok = outcome = CLI.run_input(input, worker)
      assert CLI.exit_code(outcome) == 0

      json = paths.output_dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()

      assert %{
               "status" => "skipped",
               "reason" => "world closure not built: deps_get_failed",
               "file_manifest" => nil,
               "deps_lock" => nil
             } = json["toolchain_build"]

      assert %{
               "added" => [],
               "dropped" => [],
               "reason" => "deps_get_failed",
               "world" => "phx",
               "rounds" => 1
             } = json["optional_deps"]

      assert json["requested_optional_deps"] == "world:phx"
      refute Map.has_key?(json, "deps_lock")
      assert Path.wildcard(Path.join([paths.output_dir, "files", "**", "*"])) == []
    end

    test "a host compile that fails with the world is skipped, not an error", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")

      assert {:ok, result} =
               Worker.toolchain_project(proj, input(dir, "esbuild"), paths(dir), @toolchain,
                 host_trace: recording_trace(self(), :fail),
                 deps_get: registry_deps_get(self())
               )

      assert %{status: "skipped", reason: "world closure not built: host_compile_failed"} =
               result.toolchain_build

      assert %{added: [], dropped: ["decimal"], reason: "host_compile_failed"} =
               result.optional_deps
    end

    test "a stray dependency is a skip that names it", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")
      resolve = registry_deps_get(self())

      stray = fn p, env ->
        :ok = resolve.(p, env)
        lock = File.read!(Path.join(p, "mix.lock"))
        ranch = ~s|  "ranch": {:hex, :ranch, "1.0.0", "i", [:mix], [], "hexpm", "o-ranch"},\n}|
        File.write!(Path.join(p, "mix.lock"), String.replace(lock, ~r/}\s*\z/, ranch))
      end

      assert {:ok, result} =
               Worker.toolchain_project(proj, input(dir, "esbuild"), paths(dir), @toolchain,
                 host_trace: fn _, _, _, _ -> flunk("compiled with a stray dependency") end,
                 deps_get: stray
               )

      assert result.toolchain_build.reason == "world closure not built: world_extra_deps (ranch)"
      assert result.toolchain_build.file_manifest == nil
      assert %{reason: "world_extra_deps", dropped: ["decimal"]} = result.optional_deps
    end

    test "a host compile error is still a worker failure", %{tmp_dir: dir} do
      proj = project(dir, "esbuild")

      assert {:error, {:host_compile_error, _}} =
               Worker.toolchain_project(proj, input(dir, "esbuild"), paths(dir), @toolchain,
                 host_trace: recording_trace(self(), :error),
                 deps_get: registry_deps_get(self())
               )
    end

    test "result.json echoes the world" do
      assert Worker.put_requested_optional_deps(%{}, "world:phx") == %{
               requested_optional_deps: "world:phx"
             }

      assert Worker.put_requested_optional_deps(%{}, "world") == %{}
    end
  end

  test "JsonWriter keeps the world fields", %{tmp_dir: dir} do
    result = %{
      run_id: "r",
      image: %{},
      toolchain: %{},
      finished_at: "x",
      systems: %{},
      optional_deps: %{added: [], dropped: [], skipped: [], reason: nil, world: "phx", rounds: 2}
    }

    :ok = JsonWriter.write_result(dir, result)
    json = dir |> Path.join("result.json") |> File.read!() |> JSON.decode!()
    assert %{"world" => "phx", "rounds" => 2} = json["optional_deps"]
  end
end
