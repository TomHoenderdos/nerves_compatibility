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
