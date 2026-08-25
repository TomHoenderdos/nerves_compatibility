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
