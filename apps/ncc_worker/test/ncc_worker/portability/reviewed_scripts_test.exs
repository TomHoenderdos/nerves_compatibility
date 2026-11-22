defmodule NccWorker.Portability.ReviewedScriptsTest do
  # `ReviewedScripts`: the rebar.config.script releases whose plain-arguments
  # read was reviewed, by Hex name, version and outer checksum (review R5),
  # and the script members of a tarball (review N5).
  use ExUnit.Case, async: true

  alias NccWorker.Portability.ReviewedScripts
  alias NccWorker.TracerFixtures

  @moduletag :tmp_dir

  # gproc 1.2.0's Hex tarball, vendored unchanged.
  @gproc_tar Path.join(__DIR__, "../../fixtures/rebar/gproc-1.2.0.tar")
  @gproc_sum "70c6f8c91fa5974296cd87974949d8eab953230414f31c4a623ff75131e0827a"

  # Its script files (and `extra`) in a tarball of our own.
  defp gproc_files(extra \\ %{}) do
    {:ok, [{_, gz}]} =
      :erl_tar.extract({:binary, File.read!(@gproc_tar)}, [
        :memory,
        {:files, [~c"contents.tar.gz"]}
      ])

    {:ok, members} = :erl_tar.extract({:binary, gz}, [:memory, :compressed])

    scripts =
      for {name, body} <- members,
          path = List.to_string(name),
          String.ends_with?(path, ".script"),
          into: %{},
          do: {path, body}

    %{"rebar.config" => "{erl_opts, [debug_info]}.\n", "src/gproc.erl" => "-module(gproc).\n"}
    |> Map.merge(scripts)
    |> Map.merge(extra)
  end

  defp tarball(dir, name, version, files) do
    home = Path.join(dir, "hex-#{System.unique_integer([:positive])}")
    meta = [{"version", version}]
    TracerFixtures.hex_release(home, name, Map.keys(files), files, meta)
    File.read!(Path.join(home, "packages/hexpm/#{name}-#{version}.tar"))
  end

  # Review N5: `:erl_tar.extract(_, [:memory])` drops a link member, so the
  # member table is read: a script member that is no regular file makes the
  # release unverifiable (Mix follows the link and evaluates it).
  test "a script member that is a link cannot be verified", %{tmp_dir: dir} do
    files = %{
      "rebar.config" => "{erl_opts, []}.\n",
      "real.script" => "CONFIG.\n",
      "rebar.config.script" => {:symlink, "real.script"}
    }

    assert {:unverified, "rebar.config.script is a symlink in its tarball"} =
             ReviewedScripts.script_members(tarball(dir, "fx_ln", "0.1.0", files))

    nested = %{"rebar.config.script" => "CONFIG.\n", "priv/x.script" => {:symlink, "../real"}}

    assert {:unverified, "priv/x.script is a symlink in its tarball"} =
             ReviewedScripts.script_members(tarball(dir, "fx_ln2", "0.1.0", nested))
  end

  test "script members: none, or all regular files, a ./ prefix included", %{tmp_dir: dir} do
    assert {:ok, :none} =
             ReviewedScripts.script_members(
               tarball(dir, "plain", "0.1.0", %{"rebar.config" => "x"})
             )

    assert {:ok, :scripted} =
             ReviewedScripts.script_members(tarball(dir, "g", "1.2.0", gproc_files()))

    dotted = %{"./rebar.config.script" => {:symlink, "x"}, "x" => "CONFIG.\n"}

    assert {:unverified, "rebar.config.script is a symlink in its tarball"} =
             ReviewedScripts.script_members(tarball(dir, "dot", "0.1.0", dotted))

    # Review R10: the table holds no entry for a directory a path implies.
    assert {:ok, :none} =
             ReviewedScripts.script_members(
               tarball(dir, "prefix", "0.1.0", %{"rebar.config.script/a" => "x"})
             )

    assert {:unverified, "tarball unreadable"} = ReviewedScripts.script_members("not a tarball")
  end

  test "gproc 1.2.0 as Hex ships it is reviewed, by its outer checksum" do
    bytes = File.read!(@gproc_tar)
    assert :sha256 |> :crypto.hash(bytes) |> Base.encode16(case: :lower) == @gproc_sum
    assert {:ok, :scripted} = ReviewedScripts.script_members(bytes)
    assert ReviewedScripts.reviewed?("gproc", "1.2.0", @gproc_sum)
  end

  # Review R5: the outer checksum pins every byte, `rebar.config` (the
  # script's `CONFIG`) included; the same scripts in another tarball, or the
  # same tarball under another name or version, are not reviewed.
  test "another checksum, version or name is not", %{tmp_dir: dir} do
    other = tarball(dir, "gproc", "1.2.0", gproc_files())
    sum = :sha256 |> :crypto.hash(other) |> Base.encode16(case: :lower)
    refute ReviewedScripts.reviewed?("gproc", "1.2.0", sum)
    refute ReviewedScripts.reviewed?("gproc", "1.4.0", @gproc_sum)
    refute ReviewedScripts.reviewed?("gproc_fork", "1.2.0", @gproc_sum)
    refute ReviewedScripts.reviewed?("gproc", "1.2.0", nil)
  end

  # Review R11: `HexCache.package_tarball/4` takes the lock's checksum in
  # either case, so the table does too.
  test "the checksum in upper case is the same checksum" do
    assert ReviewedScripts.reviewed?("gproc", "1.2.0", String.upcase(@gproc_sum))
  end

  test "every entry is an outer checksum of 64 hex digits" do
    for {{name, version}, sum} <- ReviewedScripts.table() do
      assert is_binary(name) and is_binary(version)
      assert sum =~ ~r/\A[0-9a-f]{64}\z/, "#{name} #{version}"
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
