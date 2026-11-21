defmodule NccWorker.Portability.ReviewedScriptsTest do
  # `ReviewedScripts`: the rebar.config.script releases whose plain-arguments
  # read was reviewed, by Hex name, version and the sha256 of every script
  # file, read from a verified tarball.
  use ExUnit.Case, async: true

  alias NccWorker.Portability.ReviewedScripts
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  # gproc 1.2.0's script files, vendored unchanged from its Hex tarball.
  @gproc Path.join(__DIR__, "../../fixtures/rebar/gproc-1.2.0")
  @gproc_scripts ~w(rebar.config.script priv/check_edown.script priv/remove_deps.script
                    src/gproc.app.src.script)

  defp gproc_files(extra \\ %{}) do
    Map.new(@gproc_scripts, &{&1, File.read!(Path.join(@gproc, &1))})
    |> Map.merge(%{
      "rebar.config" => "{erl_opts, [debug_info]}.\n",
      "src/gproc.erl" => "-module(gproc).\n"
    })
    |> Map.merge(extra)
  end

  defp tarball(dir, name, version, files) do
    home = Path.join(dir, "hex-#{System.unique_integer([:positive])}")
    meta = [{"version", version}]
    TracerFixtures.hex_release(home, name, Map.keys(files), files, meta)
    File.read!(Path.join(home, "packages/hexpm/#{name}-#{version}.tar"))
  end

  test "a tarball's script files, by path, with their sha256", %{tmp_dir: dir} do
    assert {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", gproc_files()))
    assert Map.keys(scripts) |> Enum.sort() == Enum.sort(@gproc_scripts)

    assert scripts["rebar.config.script"] ==
             "bf4bc215b10cc661de6c35a5d257b1fd76378b48d40bab2202f8014293fa5621"

    assert ReviewedScripts.scripts("not a tarball") == :error
  end

  test "gproc 1.2.0's scripts as Hex ships them are reviewed", %{tmp_dir: dir} do
    {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", gproc_files()))
    assert ReviewedScripts.reviewed?("gproc", "1.2.0", scripts)
  end

  test "another version, name, script byte or script file is not", %{tmp_dir: dir} do
    {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", gproc_files()))
    refute ReviewedScripts.reviewed?("gproc", "1.4.0", scripts)
    refute ReviewedScripts.reviewed?("gproc_fork", "1.2.0", scripts)

    changed = gproc_files(%{"priv/check_edown.script" => "CONFIG.\n"})
    {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", changed))
    refute ReviewedScripts.reviewed?("gproc", "1.2.0", scripts)

    extra = gproc_files(%{"priv/more.script" => "CONFIG.\n"})
    {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", extra))
    refute ReviewedScripts.reviewed?("gproc", "1.2.0", scripts)

    fewer = Map.delete(gproc_files(), "src/gproc.app.src.script")
    {:ok, scripts} = ReviewedScripts.scripts(tarball(dir, "gproc", "1.2.0", fewer))
    refute ReviewedScripts.reviewed?("gproc", "1.2.0", scripts)
  end

  test "every entry names its script files by 64 hex digits, a rebar.config.script among them" do
    for {{name, version}, scripts} <- ReviewedScripts.table() do
      assert is_binary(name) and is_binary(version)
      assert Map.has_key?(scripts, "rebar.config.script"), "#{name} #{version}"

      for {path, sha} <- scripts,
          do: assert(sha =~ ~r/\A[0-9a-f]{64}\z/, "#{name} #{version} #{path}")
    end
  end

  test "the reviewed releases" do
    assert ReviewedScripts.table() |> Map.keys() |> Enum.sort() == [
             {"exometer_core", "1.7.1"},
             {"exometer_core", "2.0.0"},
             {"gproc", "0.3.1"},
             {"gproc", "0.5.0"},
             {"gproc", "0.6.1"},
             {"gproc", "0.8.0"},
             {"gproc", "0.9.1"},
             {"gproc", "1.0.0"},
             {"gproc", "1.2.0"},
             {"gproc", "1.3.0"},
             {"setup", "2.1.0"},
             {"setup", "2.2.1"},
             {"tls_certificate_check", "1.36.0"},
             {"ts_chatterbox", "0.11.0"},
             {"ts_chatterbox", "0.16.0"}
           ]
  end
end
