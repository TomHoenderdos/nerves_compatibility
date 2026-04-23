defmodule Site.GeneratorTest do
  use ExUnit.Case, async: true

  alias Site.Generator

  @moduletag :tmp_dir

  describe "generate/1" do
    test "generates site from example data", %{tmp_dir: tmp_dir} do
      # Navigate from site/test/site to project root
      input_dir = Path.expand("../../../example_data", __DIR__)
      output_dir = tmp_dir

      assert :ok = Generator.generate(input_dir: input_dir, output_dir: output_dir)

      # Check that site files were created. The example_data fixture uses
      # the older schema where pkg_keys are bare names (no @version), so
      # accept either layout — bare-name OR versioned filename.
      assert File.exists?(Path.join([output_dir, "site", "index.html"]))

      packages_dir = Path.join([output_dir, "site", "packages"])

      for name <- ~w(phoenix jason) do
        files =
          Path.wildcard(Path.join(packages_dir, "#{name}.html")) ++
            Path.wildcard(Path.join(packages_dir, "#{name}@*.html"))

        assert files != [], "expected a detail page for #{name} in #{packages_dir}"
      end

      # Check that data files were copied
      assert File.exists?(Path.join([output_dir, "data", "latest_by_pkg.json"]))
      assert File.exists?(Path.join([output_dir, "data", "stats.json"]))

      # Verify index.html contains expected content (from <title> tag and
      # the autocomplete JSON)
      index_content = File.read!(Path.join([output_dir, "site", "index.html"]))
      assert index_content =~ "Nerves Compatibility Tracker"
      assert index_content =~ "phoenix"
      assert index_content =~ "jason"
    end

    test "returns error for missing input directory" do
      assert {:error, _} = Generator.generate(input_dir: "/nonexistent", output_dir: "/tmp")
    end
  end
end
