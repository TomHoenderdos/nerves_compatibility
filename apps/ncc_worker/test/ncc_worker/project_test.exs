defmodule NccWorker.ProjectTest do
  use ExUnit.Case, async: true

  alias NccWorker.Project

  # Lightweight mix.exs sample matching what `mix nerves.new` produces, trimmed
  # to the bits that matter for dep injection.
  @sample_mix_exs """
  defmodule Foo.MixProject do
    use Mix.Project

    def project do
      [deps: deps()]
    end

    defp deps do
      [
        {:nerves, "~> 1.13", runtime: false},
        {:shoehorn, "~> 0.9.1"}
      ]
    end
  end
  """

  describe "cap_squashfs/2" do
    @sample_config """
    import Config
    config :nerves, :firmware, rootfs_overlay: "rootfs_overlay"
    """

    defp firmware_config(content) do
      dir = Path.join(System.tmp_dir!(), "cfg_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      path = Path.join(dir, "config.exs")
      File.write!(path, content)
      path |> Config.Reader.read!() |> get_in([:nerves, :firmware])
    end

    # sqfstar starts one thread per visible core, and a --cpus quota hides
    # none of them: 14 threads in a 2-CPU container took 7.0 s against 3.9 s
    # with -processors 2, for byte-identical output.
    test "limits sqfstar to the given number of processors" do
      {:squashfs, flags} =
        @sample_config
        |> Project.cap_squashfs(2)
        |> firmware_config()
        |> Keyword.fetch!(:rootfs_type)

      assert Enum.take(flags, -2) == ["-processors", "2"]
    end

    # Setting rootfs_type replaces Nerves' default flags rather than adding to
    # them, and those defaults are what make the image reproducible.
    test "keeps Nerves' default squashfs flags" do
      {:squashfs, flags} =
        @sample_config
        |> Project.cap_squashfs(2)
        |> firmware_config()
        |> Keyword.fetch!(:rootfs_type)

      assert ["-mkfs-time", "0", "-all-time", "0", "-no-xattrs", "-quiet" | _] = flags
    end

    test "keeps the template's other firmware settings" do
      config = @sample_config |> Project.cap_squashfs(2) |> firmware_config()

      assert config[:rootfs_overlay] == "rootfs_overlay"
    end

    test "leaves the config alone without a limit" do
      assert Project.cap_squashfs(@sample_config, nil) == @sample_config
    end
  end

  describe "nerves_new_args/1" do
    test "names every target explicitly" do
      args = Project.nerves_new_args(["rpi4", "trellis"])

      assert args == [
               "nerves.new",
               ".",
               "--app",
               "nerves_compatibility_test",
               "--no-nerves-pack",
               "--prerelease",
               "--target",
               "rpi4",
               "--target",
               "trellis"
             ]
    end

    test "passes a --target flag for each system we build" do
      # Non-vacuous: called with no --target at all, mix nerves.new emits
      # nerves_bootstrap's @default_targets, which does not include trellis.
      # A project generated that way has no nerves_system_trellis dep and
      # fails every trellis build with an unresolvable dependency.
      targets = NccWorker.Systems.targets(NccWorker.Systems.default())
      args = Project.nerves_new_args(targets)

      assert Enum.count(args, &(&1 == "--target")) == length(targets)

      for target <- targets do
        assert target in args
      end

      assert "trellis" in args
    end
  end

  describe "pin_nerves/1" do
    # What `mix nerves.new --prerelease` (nerves_bootstrap 1.17.3) generates.
    @prerelease_mix_exs """
    defp deps do
      [
        # Dependencies for all targets
        {:nerves, "~> 2.0.0-pre.3", runtime: false},

        {:logger_backends, "~> 1.0"},
        {:nerves_runtime, "~> 0.13.0"},
        {:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4}
      ]
    end
    """

    test "pins the template's floating prerelease requirement exactly" do
      assert {:ok, pinned} = Project.pin_nerves(@prerelease_mix_exs)

      assert pinned =~ ~s[{:nerves, "== 2.0.0-pre.3", runtime: false}]
      refute pinned =~ "~> 2.0.0-pre.3"
    end

    test "leaves nerves_* packages alone" do
      assert {:ok, pinned} = Project.pin_nerves(@prerelease_mix_exs)

      assert pinned =~ ~s[{:nerves_runtime, "~> 0.13.0"}]
      assert pinned =~ ~s[{:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4}]
    end

    # A template that dropped --prerelease, or moved the dep, must not quietly
    # put every build back on stable Nerves.
    test "errors when the template has no nerves dep" do
      assert {:error, {:nerves_pin_failed, _}} = Project.pin_nerves("defp deps, do: []")
    end

    test "errors when the template generated a stable Nerves" do
      assert {:error, {:nerves_pin_failed, _}} =
               Project.pin_nerves(~s[{:nerves, "~> 1.15", runtime: false}])
    end
  end

  describe "add_package/2" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "project_test_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), @sample_mix_exs)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project_dir: tmp}
    end

    test "injects dep with exact version pin into mix.exs deps list", %{project_dir: dir} do
      # We're only exercising the mix.exs injection here — deps.get requires
      # a real Elixir/Hex environment and is covered end-to-end by the
      # integration test. Call the private helper via the public path up to
      # the point it invokes mix, then inspect mix.exs.
      #
      # Since add_package/2 itself runs mix deps.get (which will fail without
      # a full project), we test the injection helper by running it and then
      # stopping — see inject_dep_via_exported_api/2 below.
      inject_dep_only(dir, %{name: "phoenix_kit", version: "1.7.98"})

      content = File.read!(Path.join(dir, "mix.exs"))

      assert content =~ ~s[{:phoenix_kit, "== 1.7.98"},]
      # The injected dep goes first in the list
      assert String.contains?(
               content,
               "[\n      {:phoenix_kit, \"== 1.7.98\"},\n      {:nerves,"
             )
    end

    test "uses a requirement string when only a requirement is provided", %{project_dir: dir} do
      inject_dep_only(dir, %{name: "jason", requirement: "~> 1.4"})

      assert File.read!(Path.join(dir, "mix.exs")) =~ ~s[{:jason, "~> 1.4"},]
    end

    test "falls back to >= 0.0.0 when no version or requirement is given", %{project_dir: dir} do
      inject_dep_only(dir, %{name: "jason"})

      assert File.read!(Path.join(dir, "mix.exs")) =~ ~s[{:jason, ">= 0.0.0"},]
    end

    # Testing a package the template already depends on -- nerves itself,
    # shoehorn, nerves_runtime -- must not add a second entry: Mix rejects a
    # dependency declared twice with different requirements ("the dependency
    # :nerves is duplicated at the top level").
    test "re-pins a dep the template already declares instead of adding it again", %{
      project_dir: dir
    } do
      inject_dep_only(dir, %{name: "nerves", version: "2.0.0-pre.3"})
      content = File.read!(Path.join(dir, "mix.exs"))

      assert content =~ ~s[{:nerves, "== 2.0.0-pre.3", runtime: false}]
      assert length(Regex.scan(~r/\{:nerves,/, content)) == 1
    end

    test "re-pins a template dep that has no options", %{project_dir: dir} do
      inject_dep_only(dir, %{name: "shoehorn", version: "0.9.2"})
      content = File.read!(Path.join(dir, "mix.exs"))

      assert content =~ ~s[{:shoehorn, "== 0.9.2"}]
      assert length(Regex.scan(~r/\{:shoehorn,/, content)) == 1
    end

    # A system dep is scoped to its own target. Keeping `targets: :rpi4` on the
    # tested package would leave it out of every other target's build, which
    # would then pass without having compiled it.
    test "re-pinning drops a targets scope so every target builds the package", %{
      project_dir: dir
    } do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule Foo.MixProject do
        defp deps do
          [
            {:nerves, "== 2.0.0-pre.3", runtime: false},
            {:nerves_system_rpi4, "~> 1.24", runtime: false, targets: :rpi4},
            {:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb}
          ]
        end
      end
      """)

      inject_dep_only(dir, %{name: "nerves_system_rpi4", version: "2.1.2"})
      content = File.read!(Path.join(dir, "mix.exs"))

      assert content =~ ~s[{:nerves_system_rpi4, "== 2.1.2", runtime: false},]
      refute content =~ "targets: :rpi4"
      assert content =~ ~s[{:nerves_system_bbb, "~> 2.19", runtime: false, targets: :bbb}]
    end

    test "re-pinning drops a list-form targets scope too", %{project_dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), """
      defmodule Foo.MixProject do
        defp deps do
          [
            {:nerves_pack, "~> 0.7", targets: [:rpi3, :rpi4], override: true}
          ]
        end
      end
      """)

      inject_dep_only(dir, %{name: "nerves_pack", version: "0.7.1"})

      assert File.read!(Path.join(dir, "mix.exs")) =~
               ~s[{:nerves_pack, "== 0.7.1", override: true}\n]
    end

    test "a template dep whose name is a prefix of the package is not touched", %{
      project_dir: dir
    } do
      inject_dep_only(dir, %{name: "nerves_runtime", version: "0.13.13"})
      content = File.read!(Path.join(dir, "mix.exs"))

      assert content =~ ~s[{:nerves_runtime, "== 0.13.13"},]
      assert content =~ ~s[{:nerves, "~> 1.13", runtime: false}]
    end

    test "fails gracefully if mix.exs has no recognizable deps block", %{project_dir: dir} do
      File.write!(Path.join(dir, "mix.exs"), "# a file with no deps list at all\n")

      assert {:error, {:mix_exs_deps_list_not_found, _}} =
               Project.add_package(dir, %{name: "jason", version: "1.4.4"}, [])
    end
  end

  describe "inject_deps/2" do
    # A real application that depends on jason almost always has decimal in its
    # lock too, and jason compiles differently when Decimal is loadable. The
    # generated project has to resolve the optional dependency for the build
    # to match such an application.
    test "prepends each optional dependency with its requirement" do
      deps = [%{app: "decimal", package: "decimal", requirement: "~> 1.0 or ~> 2.0"}]
      assert {:ok, content, ["decimal"]} = Project.inject_deps(@sample_mix_exs, deps)

      assert content =~ ~s[{:decimal, "~> 1.0 or ~> 2.0"},\n      {:nerves,]
    end

    test "names the Hex package when it differs from the application" do
      deps = [%{app: "my_app", package: "my_package", requirement: "~> 2.0"}]
      assert {:ok, content, ["my_app"]} = Project.inject_deps(@sample_mix_exs, deps)

      assert content =~ ~s[{:my_app, "~> 2.0", hex: :my_package},]
    end

    # Mix refuses a dependency declared twice at the top level, and the template's
    # own requirement for it is the one every Nerves project has anyway.
    test "leaves a dependency the template already declares alone" do
      deps = [
        %{app: "shoehorn", package: "shoehorn", requirement: "~> 0.9"},
        %{app: "decimal", package: "decimal", requirement: "~> 2.0"}
      ]

      assert {:ok, content, ["decimal"]} = Project.inject_deps(@sample_mix_exs, deps)
      assert content =~ ~s[{:shoehorn, "~> 0.9.1"}]
      refute content =~ ~s[{:shoehorn, "~> 0.9"}]
    end

    test "fails when mix.exs has no deps list" do
      deps = [%{app: "decimal", package: "decimal", requirement: "~> 2.0"}]
      assert {:error, {:mix_exs_deps_list_not_found, _}} = Project.inject_deps("# none", deps)
    end
  end

  describe "add_optional_deps/5" do
    setup do
      tmp = Path.join(System.tmp_dir!(), "project_opt_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "mix.exs"), @sample_mix_exs)
      File.write!(Path.join(tmp, "mix.lock"), "%{}\n")
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, project_dir: tmp}
    end

    test "with nothing to add, touches nothing and runs no mix", %{project_dir: dir} do
      assert {:ok, []} = Project.add_optional_deps(dir, "pkg", [], [])
      assert File.read!(Path.join(dir, "mix.exs")) == @sample_mix_exs
    end

    # Whatever goes wrong, the caller gets back exactly the project it had,
    # and rebuilds the package without the optional dependencies.
    test "restores mix.exs and mix.lock when deps.get fails", %{project_dir: dir} do
      deps = [%{app: "decimal", package: "decimal", requirement: "~> 2.0"}]

      assert {:error, {:deps_get_failed, _}} = Project.add_optional_deps(dir, "pkg", deps, [])

      assert File.read!(Path.join(dir, "mix.exs")) == @sample_mix_exs
      assert File.read!(Path.join(dir, "mix.lock")) == "%{}\n"
    end

    test "injects nothing and runs no deps.get for deps the template declares",
         %{project_dir: dir} do
      deps = [%{app: "shoehorn", package: "shoehorn", requirement: "~> 0.9"}]

      assert {:ok, []} = Project.add_optional_deps(dir, "pkg", deps, [])
      assert File.read!(Path.join(dir, "mix.exs")) == @sample_mix_exs
    end

    # The first `mix deps.get` may already have compiled the package into the
    # host build path, before the optional dependency existed. Mix would not
    # recompile it: its lock entry and marker are unchanged. Left in place,
    # that build would be published with a deps_lock naming a dependency it
    # never saw, so it is removed before the dependencies are resolved, on the
    # revert path too.
    test "removes the package's stale host build before resolving", %{project_dir: dir} do
      build_path = Path.join([dir, "_build", "host"])
      stale = Path.join([build_path, "lib", "pkg", "ebin", "pkg.beam"])
      other = Path.join([build_path, "lib", "other", "ebin", "other.beam"])

      for path <- [stale, other],
          do:
            (
              File.mkdir_p!(Path.dirname(path))
              File.write!(path, "x")
            )

      deps = [%{app: "decimal", package: "decimal", requirement: "~> 2.0"}]

      assert {:error, _} =
               Project.add_optional_deps(dir, "pkg", deps, [{"MIX_BUILD_PATH", build_path}])

      refute File.exists?(Path.join([build_path, "lib", "pkg"]))
      assert File.exists?(other)
    end
  end

  describe "drop_optional_deps/3" do
    # After the optional pass built, or failed to build, with them: the project
    # goes back to what the status was decided on, and the package's build is
    # removed so the next host compile rebuilds it without them.
    test "restores the snapshot and removes the package's build" do
      dir = Path.join(System.tmp_dir!(), "project_drop_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm_rf!(dir) end)
      build_path = Path.join([dir, "_build", "host"])
      File.mkdir_p!(Path.join([build_path, "lib", "pkg", "ebin"]))
      File.mkdir_p!(Path.join([build_path, "lib", "other"]))
      File.write!(Path.join(dir, "mix.exs"), @sample_mix_exs)
      File.write!(Path.join(dir, "mix.lock"), "%{}\n")

      assert {:ok, snapshot} = Project.snapshot(dir)
      File.write!(Path.join(dir, "mix.exs"), "changed")
      File.write!(Path.join(dir, "mix.lock"), "changed")

      assert :ok = Project.drop_optional_deps(snapshot, "pkg", [{"MIX_BUILD_PATH", build_path}])

      assert File.read!(Path.join(dir, "mix.exs")) == @sample_mix_exs
      assert File.read!(Path.join(dir, "mix.lock")) == "%{}\n"
      refute File.exists?(Path.join([build_path, "lib", "pkg"]))
      assert File.dir?(Path.join([build_path, "lib", "other"]))
    end
  end

  # Call the public API but stub out the deps.get side-effect by pointing at a
  # project_dir whose mix.exs is our sample. We read mix.exs before add_package
  # runs mix, then call add_package which will fail at deps.get (mix not
  # available in the ambient test environment against an empty project) — but
  # the mix.exs was already edited by that point, which is what we're asserting.
  defp inject_dep_only(project_dir, package) do
    _ = Project.add_package(project_dir, package, [])
    :ok
  end
end
