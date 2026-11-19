defmodule NccWorker.PinsTest do
  use ExUnit.Case, async: true

  alias NccWorker.{CLI, Pins, Project}

  @moduletag :tmp_dir

  @a String.duplicate("a", 64)
  @b String.duplicate("b", 64)
  @c String.duplicate("c", 64)

  def dep(name, version, checksum, hex \\ nil),
    do: %{"name" => name, "hex" => hex || name, "version" => version, "checksum" => checksum}

  def pins(deps, package_checksum \\ @a) do
    hash =
      Compatibility.Pins.hash(%{
        package: "sample",
        version: "1.0.0",
        package_checksum: package_checksum,
        deps: deps
      })

    %{"hash" => hash, "package_checksum" => package_checksum, "deps" => deps}
  end

  # The lock `deps.get` would write for `sample` 1.0.0 with `deps`, plus
  # `extra` entries the closure reaches too.
  def lock(deps, opts \\ []) do
    sample_sum = Keyword.get(opts, :package_checksum, @a)
    extra = Keyword.get(opts, :extra, [])

    edges =
      Enum.map_join(
        deps ++ extra,
        ", ",
        &~s|{:#{&1["name"]}, "~> 0.0", [hex: :#{&1["hex"]}, repo: "hexpm", optional: false]}|
      )

    entries =
      for d <- deps ++ extra,
          do:
            ~s|  "#{d["name"]}": {:hex, :#{d["hex"]}, "#{d["version"]}", "inner", [:mix], [], "hexpm", "#{d["checksum"]}"},\n|

    ~s|%{\n  "sample": {:hex, :sample, "1.0.0", "inner", [:mix], [#{edges}], "hexpm", "#{sample_sum}"},\n| <>
      Enum.join(entries) <> Keyword.get(opts, :more, "") <> "}\n"
  end

  defp input(fields) do
    Map.merge(
      %{
        "run_id" => "r1",
        "mode" => "toolchain",
        "optional_deps" => "pinned",
        "package" => %{"name" => "sample", "version" => "1.0.0"},
        "pins" => pins([dep("decimal", "2.3.0", @b)])
      },
      fields
    )
    |> Map.reject(fn {_k, v} -> v == :drop end)
    |> JSON.encode!()
  end

  describe "NCC_INPUT.pins" do
    test "a valid set on a toolchain run is read as given" do
      assert {:ok, %{pins: %{"hash" => _, "deps" => [_]}, optional_deps: "pinned"}} =
               CLI.parse_input(input(%{}))
    end

    test "every combination the spec refuses exits 10 with no result" do
      cases = [
        {%{"optional_deps" => "include"}, {:optional_deps, "include"}},
        {%{"optional_deps" => :drop}, {:optional_deps, nil}},
        {%{"mode" => "argus_only"}, {:mode, "argus_only"}},
        {%{"mode" => "warm_nerves"}, {:mode, "warm_nerves"}},
        {%{"mode" => "system_abi"}, {:mode, "system_abi"}},
        {%{"mode" => :drop}, {:mode, nil}},
        {%{"package" => %{"name" => "sample"}}, {:package, %{name: "sample"}}},
        {%{"pins" => Map.put(pins([]), "hash", @c)}, :hash_mismatch}
      ]

      for {fields, why} <- cases do
        assert {:error, {:invalid_pins, ^why}} = CLI.parse_input(input(fields)),
               inspect(fields)

        assert CLI.exit_code({:error, {:invalid_pins, why}}) == 10
      end
    end

    test "pins never go with a world" do
      assert {:error, {:invalid_world, _}} =
               CLI.parse_input(input(%{"world" => "phx", "world_members" => ["jason"]}))

      assert {:error, {:invalid_pins, {:optional_deps, "world"}}} =
               CLI.parse_input(
                 input(%{
                   "optional_deps" => "world",
                   "world" => "phx",
                   "world_members" => ["jason"]
                 })
               )
    end

    test "optional_deps \"pinned\" without pins is refused" do
      assert {:error, {:invalid_pins, :missing}} = CLI.parse_input(input(%{"pins" => :drop}))
    end

    test "an input without pins is read as before" do
      assert {:ok, input} =
               CLI.parse_input(input(%{"pins" => :drop, "optional_deps" => "exclude"}))

      refute Map.has_key?(input, :pins)
    end
  end

  describe "Project.inject_pins/2" do
    @mix "defp deps do\n    [\n      {:nerves_runtime, \"~> 0.13\", targets: :rpi4}\n    ]\n  end\n"

    test "each pin is an exact requirement, with hex: when the names differ, and no override" do
      deps = [dep("decimal", "2.3.0", @b), dep("tz", "1.0.0", @c, "tzdata")]
      assert {:ok, content} = Project.inject_pins(@mix, deps)
      assert content =~ ~s|{:decimal, "== 2.3.0"}|
      assert content =~ ~s|{:tz, "== 1.0.0", hex: :tzdata}|
      refute content =~ "override"
    end

    test "a pin the template declares is repinned in place, keeping its options" do
      assert {:ok, content} = Project.inject_pins(@mix, [dep("nerves_runtime", "0.13.7", @b)])
      assert content =~ ~s|{:nerves_runtime, "== 0.13.7"}|
      assert length(String.split(content, ":nerves_runtime")) == 2
    end
  end

  describe "Pins.reproduce/5" do
    defp plain(dir) do
      proj = Path.join(dir, "proj")
      File.mkdir_p!(proj)
      File.write!(Path.join(proj, "mix.exs"), "  defp deps do\n    [\n    ]\n  end\n")
      proj
    end

    # A `deps.get` that writes `lock` and reports what mix.exs held.
    defp writes(lock) do
      parent = self()

      fn proj, _env ->
        send(parent, {:mix_exs, File.read!(Path.join(proj, "mix.exs"))})
        File.write!(Path.join(proj, "mix.lock"), lock)
        :ok
      end
    end

    @package %{name: "sample", version: "1.0.0"}
    defp set_deps, do: [dep("decimal", "2.3.0", @b), dep("tz", "1.0.0", @c, "tzdata")]

    test "a lock that is exactly the pins is reproduced", %{tmp_dir: dir} do
      pins = pins(set_deps())

      assert {:ok, %{"status" => "reproduced", "hash" => hash, "reason" => nil} = out} =
               Pins.reproduce(plain(dir), @package, pins, [], writes(lock(set_deps())))

      assert hash == pins["hash"]
      assert %{"extra" => [], "missing" => [], "differing" => []} = out
      assert_received {:mix_exs, mix}
      assert mix =~ ~s|{:sample, "== 1.0.0"}|
      assert mix =~ ~s|{:tz, "== 1.0.0", hex: :tzdata}|
    end

    test "a dependency Mix added beyond the pins refuses the set", %{tmp_dir: dir} do
      extra = [dep("jason", "1.4.0", @c)]

      assert {:ok, %{"status" => "refused", "reason" => "pins_closure_mismatch"} = out} =
               Pins.reproduce(
                 plain(dir),
                 @package,
                 pins(set_deps()),
                 [],
                 writes(lock(set_deps(), extra: extra))
               )

      assert out["extra"] == ["jason"]
    end

    test "another outer checksum refuses the set as a checksum mismatch", %{tmp_dir: dir} do
      locked = [dep("decimal", "2.3.0", @a), dep("tz", "1.0.0", @c, "tzdata")]

      assert {:ok,
              %{
                "status" => "refused",
                "reason" => "pins_checksum_mismatch",
                "differing" => ["decimal"]
              }} =
               Pins.reproduce(plain(dir), @package, pins(set_deps()), [], writes(lock(locked)))
    end

    test "the package's own checksum is checked too", %{tmp_dir: dir} do
      assert {:ok,
              %{
                "status" => "refused",
                "reason" => "pins_checksum_mismatch",
                "differing" => ["sample"]
              }} =
               Pins.reproduce(
                 plain(dir),
                 @package,
                 pins(set_deps()),
                 [],
                 writes(lock(set_deps(), package_checksum: @b))
               )
    end

    test "a pin resolved from another Hex package differs", %{tmp_dir: dir} do
      locked = [dep("decimal", "2.3.0", @b), dep("tz", "1.0.0", @c, "tz")]

      assert {:ok,
              %{"status" => "refused", "reason" => "pins_closure_mismatch", "differing" => ["tz"]}} =
               Pins.reproduce(plain(dir), @package, pins(set_deps()), [], writes(lock(locked)))
    end

    test "a lock entry outside the closure refuses the set", %{tmp_dir: dir} do
      stray = ~s|  "stray": {:hex, :stray, "1.0.0", "i", [:mix], [], "hexpm", "#{@c}"},\n|

      assert {:ok, %{"status" => "refused", "extra" => ["stray"]}} =
               Pins.reproduce(
                 plain(dir),
                 @package,
                 pins(set_deps()),
                 [],
                 writes(lock(set_deps(), more: stray))
               )
    end

    test "a deterministic deps.get failure is a refusal; a transient one a worker failure", %{
      tmp_dir: dir
    } do
      unresolvable = fn _proj, _env ->
        {:error, {:deps_get_failed, "Failed to use \"decimal\" because"}}
      end

      assert {:ok, %{"status" => "refused", "reason" => "pins_unresolvable"}} =
               Pins.reproduce(plain(dir), @package, pins(set_deps()), [], unresolvable)

      flaky = fn _proj, _env -> {:error, {:deps_get_failed, "** (Mix) :econnrefused"}} end

      assert {:error, {:deps_get_failed, _}} =
               Pins.reproduce(plain(Path.join(dir, "2")), @package, pins(set_deps()), [], flaky)
    end

    test "a git dependency in the lock is a policy violation (exit 11)", %{tmp_dir: dir} do
      git = ~s|  "g": {:git, "https://example.invalid/g.git", "abc", []},\n|

      assert {:error, :policy_violation} =
               Pins.reproduce(
                 plain(dir),
                 @package,
                 pins(set_deps()),
                 [],
                 writes(lock(set_deps(), more: git))
               )
    end

    # Random pin sets that do not reproduce never pass the exact check.
    test "a set Mix does not reproduce is never reported reproduced", %{tmp_dir: dir} do
      :rand.seed(:exsss, {1, 2, 3})

      for i <- 1..60 do
        deps = for j <- 1..:rand.uniform(5), do: dep("d#{j}", "1.0.#{:rand.uniform(3)}", @b)
        locked = mutate(deps, :rand.uniform(4))
        proj = plain(Path.join(dir, "p#{i}"))

        assert {:ok, %{"status" => "refused"}} =
                 Pins.reproduce(proj, @package, pins(deps), [], writes(lock(locked)))
      end
    end

    defp mutate([first | rest], 1), do: [%{first | "version" => "9.9.9"} | rest]
    defp mutate([first | rest], 2), do: [%{first | "checksum" => @c} | rest]
    defp mutate([_first | rest], 3), do: rest
    defp mutate(deps, 4), do: deps ++ [dep("zz", "1.0.0", @a)]
  end
end
